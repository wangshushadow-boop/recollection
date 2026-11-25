extends SceneTree
## Samples the normal field composition, desktop, Jolt space and authority at 60 fixed steps/s.
const Composition = preload("res://bootstrap/composition_root.gd")
const Config = preload("res://bootstrap/boot_config.gd")
const Desktop = preload("res://bootstrap/field_desktop.gd")
const Visuals = preload("res://presentation/visuals/ports/field_visuals.gd")
const Batches = preload("res://presentation/visuals/field_batches.gd")
const SEED := 241124
const WARM := 120
const MEASURE := 360
const MAX_APPROACH := 1200
const WAYPOINTS := {"infantry":[46000,0,-4000],"archer":[31000,0,4000],
	"cavalry":[52000,0,-14000],"mounted_archer":[37000,0,12000]}
var app: RefCounted
var desktop: Desktop
var visual: Visuals
var camera: Camera3D
var arrows: MultiMeshInstance3D
var rig_meshes := {}
var count := 0
var output := ""
var scope := ""
var digest := ""
var probe := false
var trace := "flanks"
var sequence := 0
var engaged_order := false
var troop_by_handle := {}
var ready_field := false
var ending := false
var tick := 0
var contact_tick := -1
var measure_from := -1
var samples: Array = []
var frames: Array = []
var started := 0
var prev_frame := 0
var events := {}
var total_hits := 0
var first_population := {}
var first_step_us := 0
var retries := 0
var initial_wait := 0
var order_receipt := false
var min_humans := 0
var max_humans := 0
var failure := ""

func _initialize() -> void:
	_start.call_deferred()

func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size()<2 or not args[0].is_valid_int():
		printerr("Use -- <people> <output.json> [probe] [together|flanks]")
		quit(2)
		return
	count = args[0].to_int()
	output = args[1]
	for flag in args.slice(2):
		if flag=="probe": probe=true
		elif flag in ["together","flanks"]: trace=flag
		else: _fail("unknown trace option"); return
	if (not probe and count not in [500,1000]) or count<4 or DisplayServer.get_name()=="headless":
		_fail("expected a rendered mixed field")
		return
	var pid := FileAccess.open(output+".pid",FileAccess.WRITE)
	if not pid: _fail("unwritable output"); return
	pid.store_string(str(OS.get_process_id()))
	pid.close()
	Engine.physics_ticks_per_second = 60
	root.msaa_3d = Viewport.MSAA_2X
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var cfg := Config.resolve([],DisplayServer.get_name(),{})
	if not _ok(cfg,"configuration"): return
	app = Composition.new(root)
	var result: Dictionary = app.boot(cfg.value)
	if not _ok(result,"boot"): return
	digest = result.value.content_hash
	result = app.start_field(count,count*2,SEED)
	if not _ok(result,"start"): return
	scope = result.value
	desktop = Desktop.new()
	root.add_child(desktop)
	if not _ok(desktop.mount(app,scope),"mount desktop"): return
	for node in desktop.get_children():
		if node is Visuals: visual = node
		if node is Camera3D: camera = node
	if visual==null or camera==null: _fail("missing presentation nodes"); return
	for node in visual.find_children("*","Node3D",true,false):
		if node is Batches:
			for draw in node.get_children():
				if draw is MultiMeshInstance3D and draw.multimesh==node.groups.arrow.geometry:
					arrows=draw
	if arrows==null: _fail("missing submitted arrow mesh"); return
	node_added.connect(_on_node_added)
	node_removed.connect(func(node):rig_meshes.erase(node))
	desktop.begin()
	min_humans = count
	RenderingServer.frame_post_draw.connect(_frame)
	ready_field = true

func _ok(r: Dictionary, where: String) -> bool:
	if not r.ok: _fail(where+" "+str(r.error))
	return r.ok

func _send_order(groups: Array, kind: String, at: Variant) -> bool:
	var ids := []
	var revisions := {}
	for group in groups:
		ids.append(group.id)
		revisions[str(group.id)]=group.control_revision
	sequence+=1
	var id := "benchmark-order-%d"%sequence
	var order := {"mission_id":scope,"order_id":id,"issuer_id":"player","formation_ids":ids,
		"order_type":kind,"target_position":at,"target_formation_id":null,
		"parameters":{},"issued_tick":tick+1,"client_sequence":sequence}
	return _ok(app.field_command("field.order",{"order":order,"revisions":revisions},tick,id),"player "+kind)

func _advance() -> bool:
	var hud: Dictionary = app.field_view("hud")
	if not _ok(hud,"command view"): return false
	var groups: Array=hud.value.formations.filter(func(g):return g.controllable and not g.members.is_empty())
	if trace=="together":return _send_order(groups,"move",[52000,0,0])
	for group in groups:
		var role: String = troop_by_handle.get(group.members[0].index,"")
		if not WAYPOINTS.has(role): _fail("formation without a field troop"); return false
		if not _send_order([group],"move",WAYPOINTS[role]): return false
	return true

func _engage_visible() -> bool:
	var hud: Dictionary = app.field_view("hud")
	if not _ok(hud,"contact view"): return false
	if hud.value.targets.is_empty() and tick<900: return true
	var groups: Array=hud.value.formations.filter(func(g):return g.controllable and not g.members.is_empty())
	engaged_order = _send_order(groups,"free_attack",null)
	if engaged_order: print("BENCHMARK free attack at ",tick," known enemy formations ",hud.value.targets.size())
	return engaged_order

func _physics_process(_delta: float) -> bool:
	if not ready_field or ending: return false
	var read_input := desktop.before_step(tick+1)
	if not _ok(read_input,"input"): return false
	var start_us := Time.get_ticks_usec()
	var result: Dictionary = app.field_step()
	var authority_us := Time.get_ticks_usec()-start_us
	if not result.ok and tick==0 and result.error.code in ["Unavailable","StaleVersion"] and result.error.field in ["navigation_sync","nav_revision","deployment.spawn_site"] and retries<50:
		retries += 1
		return false
	if not _ok(result,"fixed step"): return false
	tick += 1
	if result.value.tick!=tick: _fail("nonsequential authority tick");return false
	if not _ok(desktop.after_step(),"desktop step"): return false
	if tick==1:
		first_step_us = authority_us
		for row in result.value.entities:
			var kind: String = row.components.get("troop_def_id","") if row.source_slot!=null else "mount"
			first_population[kind] = first_population.get(kind,0)+1
			if row.source_slot!=null: troop_by_handle[row.handle.index]=kind.get_file()
		order_receipt = _advance()
		if not order_receipt: return false
	if trace=="flanks" and not engaged_order and tick%30==0:
		if not _engage_visible(): return false
	var hit_count := 0
	var launched := 0
	for report in result.value.system_reports:
		if report.id=="field.combat":
			hit_count = report.value.hits.size()
			for e in report.value.events:
				if e.type=="projectile_launched": launched+=1
				if tick>measure_from and measure_from>=0: events[e.type]=events.get(e.type,0)+1
	if contact_tick<0 and (hit_count>0 or launched>0):
		contact_tick = tick
	var approach_limit := MAX_APPROACH if trace=="together" else MAX_APPROACH*2
	if measure_from<0 and (contact_tick>=0 or tick>=approach_limit or probe):
		initial_wait = tick
		measure_from = tick+(6 if probe else WARM)
		print("BENCHMARK warmup start ",tick," contact ",contact_tick)
	if tick==measure_from:
		started = Time.get_ticks_usec()
	elif measure_from>=0 and tick>measure_from:
		total_hits += hit_count
		var horses := 0
		for row in result.value.entities:
			if row.source_slot==null: horses+=1
		var humans: int = result.value.entities.size()-horses
		min_humans=mini(min_humans,humans)
		max_humans=maxi(max_humans,humans)
		# Visible projectiles are now sampled in _frame() after submission.
		samples.append([tick,authority_us,Time.get_ticks_usec()-started,humans,horses,hit_count,launched])
		if samples.size()==(18 if probe else MEASURE): ending=true
	if tick%120==0:
		print("BENCHMARK tick ",tick," contact ",contact_tick," samples ",samples.size())
		if measure_from<0:
			var view: Dictionary = app.field_view("visual")
			if not _ok(view,"formation positions"): return false
			var centers := {}
			var sizes := {}
			for a in view.value.actors:
				var group := "%s/%s"%[a.team,a.role]
				centers[group] = centers.get(group,0.0)+a.position.x
				sizes[group] = sizes.get(group,0)+1
			for g in centers: centers[g] /= sizes[g]
			print("BENCHMARK approach formation x ",centers)
	return false

func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D and node.skin!=null and visual.is_ancestor_of(node):
		rig_meshes[node]=true

func _frustum() -> Vector2i:
	var rigs := {}
	var shots := 0
	if camera!=root.get_camera_3d(): return Vector2i.ZERO
	for mesh: MeshInstance3D in rig_meshes:
		if mesh.is_visible_in_tree() and (camera.cull_mask & mesh.layers)!=0 and mesh.mesh!=null:
			if camera.is_position_in_frustum(mesh.global_transform*mesh.get_aabb().get_center()):
				var skeleton:=mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
				if skeleton!=null and skeleton.get_bone_count()>0: rigs[skeleton]=true
	if arrows.is_visible_in_tree() and (camera.cull_mask & arrows.layers)!=0:
		for i in arrows.multimesh.visible_instance_count:
			var point:=arrows.multimesh.get_instance_transform(i).origin
			if camera.is_position_in_frustum(arrows.to_global(point)): shots+=1
	return Vector2i(rigs.size(),shots)

func _process(delta: float) -> bool:
	if not ready_field: return false
	if not _ok(desktop.present_frame(delta),"desktop snapshot"): return false
	camera.fov = 60
	var trajectory_tick := tick-initial_wait if trace=="flanks" and measure_from>=0 else tick
	camera.global_position = Vector3(6.0*sin(trajectory_tick/150.0),38,45)
	camera.look_at(Vector3(0,.5,0))
	return false

func _frame() -> void:
	if not ready_field or started==0: return
	var now := Time.get_ticks_usec()
	if prev_frame:
		var vp := root.get_viewport_rid()
		var drawing := visual.report()
		var in_frustum := _frustum()
		frames.append([now-prev_frame,RenderingServer.viewport_get_measured_render_time_cpu(vp),
			RenderingServer.viewport_get_measured_render_time_gpu(vp),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
			drawing.near_skeletons,drawing.far_animated_instances,drawing.mounts,drawing.projectiles,
			drawing.corpses,drawing.impacts,in_frustum.x,in_frustum.y])
	prev_frame=now
	if ending:
		ready_field=false
		_finish.call_deferred()

func _fail(message: String) -> void:
	if not failure.is_empty(): return
	failure=message
	printerr("BENCHMARK_FAILED tick ",tick," ",message)
	ending = true
	ready_field = false
	_finish.call_deferred()

func _finish() -> void:
	var end_view := {"humans":0,"mounts":0,"humans_in_frustum":0,"mounts_in_frustum":0}
	var probe_skin_count: Variant = null
	if app and camera and app.has_field() and failure.is_empty():
		var visible: Dictionary = app.field_view("visual")
		if visible.ok:
			for actor in visible.value.actors:
				var kind := "mounts" if actor.role=="mount" else "humans"
				end_view[kind]+=1
				if camera.is_position_in_frustum(actor.position+Vector3.UP):end_view[kind+"_in_frustum"]+=1
			if probe and not visible.value.actors.is_empty():
				var where: Vector3=visible.value.actors[0].position
				camera.global_position=where+Vector3(2,2,7)
				camera.look_at(where+Vector3.UP)
				await RenderingServer.frame_post_draw
				probe_skin_count=_frustum().x
				if probe_skin_count==0: failure="close real rig absent from view frustum"
	var data := {"count":count,"seed":SEED,"reserve":count,"content_hash":digest,"failure":failure,
		"probe":probe,"input_trace":trace,"engage_order":engaged_order,"approach_ticks":initial_wait,
		"contact_tick":contact_tick,"measure_from":measure_from,
		"authority_first_us":first_step_us,"spawn_retries":retries,"player_order":order_receipt,
		"opening_roles":first_population,"min_humans":min_humans,"max_humans":max_humans,
		"events":events,"hits":total_hits,"ticks":samples,"frames":frames,"final_tick":tick,"end_view":end_view,
		"probe_close_rigs_in_frustum":probe_skin_count,
		"pixels":[root.size.x,root.size.y],"display":DisplayServer.get_name(),
		"renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name(),
		"adapter":RenderingServer.get_video_adapter_name(),"cpu":OS.get_processor_name(),
		"engine":Engine.get_version_info().string,"vsync":DisplayServer.window_get_vsync_mode(),
		"msaa_samples":2 if root.msaa_3d==Viewport.MSAA_2X else 0,"fov":camera.fov if camera else 0,
		"shadow_px":ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size")}
	if not output.is_empty():
		var f := FileAccess.open(output,FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(data))
			f.close()
		else: failure="cannot save results"
	if desktop:
		desktop.release()
		desktop.free()
	if app: app.shutdown()
	print("FIELD_BENCHMARK ticks=",samples.size()," frames=",frames.size()," hits=",total_hits," failure=",failure)
	quit(int(not failure.is_empty()))
