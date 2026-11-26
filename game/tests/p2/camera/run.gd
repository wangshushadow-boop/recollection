extends SceneTree
const Camera = preload("res://presentation/camera/ports/field_camera.gd")
const Adapter = preload("res://infrastructure/engine/adapter.gd")
const R = preload("res://contracts/result.gd")
const ARENA = preload("res://tests/p2/camera/arena.tscn")
const SCOPE := "camera-battle"
const PLAYER := {"index":0,"generation":1}
const ALLY := {"index":1,"generation":1}
const ENEMY := {"index":2,"generation":1}
var cam: Camera
var adapter: Adapter
var pose_rows := {
	0:{"handle":PLAYER,"position":Vector3.ZERO,"heading":Vector3.FORWARD,"mounted":false,"collision_handles":["player"]},
	1:{"handle":ALLY,"position":Vector3(0,0,-4.2),"heading":Vector3.FORWARD,"collision_handles":["soldier"]}}
var own := true
var spectate := true
var deploy := true
var revealed := true
var fail_query := false
var checks := 0
var failures := 0
var queries := 0
var functional_results := {}

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL ",label)

func _initialize() -> void:
	run.call_deferred()

func pose(scope: String,h: Dictionary) -> Dictionary:
	if scope!=SCOPE: return R.fail("NotFound")
	var row: Dictionary = pose_rows.get(h.index,{})
	if row.get("handle")!=h: return R.fail("NotFound")
	return R.ok(row)

func permission(scope: String,mode: String,h: Dictionary) -> bool:
	if scope!=SCOPE: return false
	if mode=="deployment": return deploy and h.is_empty()
	if mode=="spectator": return spectate and h==ALLY
	return own and h==PLAYER

func sweep(requests: Array,stamp: Dictionary) -> Dictionary:
	queries += 1
	if fail_query: return R.fail("Unavailable")
	return adapter.query_sweep_batch(requests,stamp)

func visible_entity(scope: String,entity: String) -> Dictionary:
	if scope!=SCOPE: return R.fail("NotFound")
	if entity=="soldier": return R.ok(ALLY.duplicate()) if revealed else R.fail("Unauthorized")
	if entity=="terrain": return R.ok(null)
	return R.fail("Unauthorized")

func bind_camera() -> Dictionary:
	return cam.open_field(SCOPE,pose,permission,sweep,visible_entity,Vector3(15,0,1))

func options_writer() -> void:
	var previous := cam.state()
	check(not cam.set_options(NAN,false).ok and not cam.set_options(44,false).ok,"invalid FOV rejected")
	check(cam.state()==previous,"failed preference leaves in-memory state untouched")
	check(cam.set_options(72.0,true).ok and cam.set_options(91.75,false).ok,"two atomic settings commits")
	var baseline := FileAccess.get_file_as_bytes(Camera.SETTINGS)
	var temp := ProjectSettings.globalize_path(Camera.SETTINGS)+"."+str(OS.get_process_id())+"."+str(cam.get_instance_id())+".tmp"
	check(DirAccess.make_dir_absolute(temp)==OK,"inject write failure in isolated profile")
	var denied := cam.set_options(56.5,true)
	check(not denied.ok and cam.fov==91.75 and not cam.state().shake,"write failure rolls back FOV and shake")
	check(FileAccess.get_file_as_bytes(Camera.SETTINGS)==baseline,"previous committed preferences preserved")
	DirAccess.remove_absolute(temp)

func screen_center() -> Vector2:
	return root.get_visible_rect().get_center()

func chase_framing(tick: int) -> void:
	pose_rows[0].position=Vector3(-4,0,0)
	check(cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_view(SCOPE,tick,.016).ok,"first person before shoulder cut")
	check(cam.set_mode(SCOPE,"third",PLAYER).ok and cam.update_view(SCOPE,tick,.001).ok,"immediate validated third-person cut")
	var chest:=cam.unproject_position(Vector3(-4,1.15,0))
	var viewport_size:=root.get_visible_rect().size
	var normalized_chest:=chest/viewport_size
	check(is_equal_approx(cam.position.z,Camera.CHASE_DISTANCE) and normalized_chest.x<.485 and normalized_chest.y>.53,
		"first third-person frame shows chest below and beside center: camera=%s chest=%s" % [cam.position,normalized_chest])
	var previous:=cam.position
	pose_rows[0].position.x+=.12
	check(cam.update_view(SCOPE,tick+1,.016).ok and cam.position.x>previous.x and cam.position.x<previous.x+.12,
		"normal stride follows promptly with limited positional lag")
	var base:=cam.fov
	cam.set_zoom_held(true)
	check(cam.update_view(SCOPE,tick+2,.13).ok and cam.fov<base-10,"hold narrows the combat view")
	var held:=cam.fov
	cam.set_zoom_held(false)
	check(cam.update_view(SCOPE,tick+3,.016).ok and cam.fov>held and cam.fov<base,"released zoom eases out")
	check(cam.update_view(SCOPE,tick+4,.13).ok and is_equal_approx(cam.fov,base),"release restores the user's FOV")
	check(cam.update_player_view(SCOPE,tick+4,.15,Vector2.ZERO,-1).ok and is_equal_approx(cam.position.z,Camera.CHASE_DISTANCE-.35),"keypad step pulls the chase camera closer")
	check(cam.update_player_view(SCOPE,tick+4,.15,Vector2.ZERO,-1).ok and is_equal_approx(cam.position.z,Camera.CHASE_DISTANCE-.35),"a held camera distance does not drift per frame")
	check(cam.update_player_view(SCOPE,tick+4,.15,Vector2.ZERO,0).ok and is_equal_approx(cam.position.z,Camera.CHASE_DISTANCE),"opposite keypad step restores distance")
	var aim:=Vector2(-PI+.02,.19)
	var forward:=-Basis.from_euler(Vector3(aim.y,aim.x,0)).z
	check(cam.update_view(SCOPE,tick+5,.016,Vector2(PI-.03,1.8)).ok and cam.update_player_view(SCOPE,tick+5,.016,aim).ok and (-cam.global_basis.z).is_equal_approx(forward),
		"absolute combat look returns from a clamped orbit across the yaw seam")
	check(cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_player_view(SCOPE,tick+6,.016,aim).ok and (-cam.global_basis.z).is_equal_approx(forward),
		"first and third person share the supplied combat aim")
	for pitch: float in [-1.570796,1.570796]:
		var steep:=Vector2(aim.x,pitch)
		check(cam.update_player_view(SCOPE,tick+6,.016,steep).ok and (-cam.global_basis.z).is_equal_approx(-Basis.from_euler(Vector3(pitch,aim.x,0)).z),
			"combat view can match the full authoritative pitch range")
	pose_rows[0].position=Vector3(-6,0,0)
	var centered:=adapter.query_sweep_batch([{"from":[-6000,1650,0],"to":[-6000,1650,2650],"radius_mm":Camera.ARM_RADIUS_MM,"mask":1,"ignored_handles":["player"]}],{"scope_id":SCOPE,"tick":tick+7})
	check(centered.ok and centered.value.is_empty() and cam.set_mode(SCOPE,"third",PLAYER).ok and cam.update_player_view(SCOPE,tick+7,.016,Vector2.ZERO).ok and cam.position.z<1.8,
		"off-axis obstacle clips the complete shoulder sweep even when a centered sphere would pass")
	functional_results["combat_framing"]={"first_chase_m":previous.z,"viewport_px":[viewport_size.x,viewport_size.y],"chest_viewport":[normalized_chest.x,normalized_chest.y],
		"base_fov":base,"held_fov":held,"shoulder_wall_z_m":cam.position.z}

func exercises() -> void:
	var start := failures
	check(bind_camera().ok and not cam.state().active and cam.cull_mask==0,"open without presenting an unauthorized view")
	check(not cam.set_mode("foreign","first",PLAYER).ok and not cam.set_mode(SCOPE,"unknown",PLAYER).ok,"scope and mode")
	check(cam.set_mode(SCOPE,"third",PLAYER).ok and not cam.pick(SCOPE,screen_center()).ok,"selection waits for verified transform")
	var original := pose_rows.duplicate(true)
	var timing := PackedInt64Array()
	for step in 60:
		var t := Time.get_ticks_usec()
		var r := cam.update_view(SCOPE,step,.016,Vector2(0,.18) if step==0 else Vector2.ZERO)
		timing.append(Time.get_ticks_usec()-t)
		check(r.ok and cam.position.z>0 and cam.position.z <2.1,"grazing wall clips sphere, step %d"%step)
	timing.sort()
	var arm := cam.position.z
	pose_rows[0].position.x = -3.0
	var cleared := cam.update_view(SCOPE,59,.016)
	check(cleared.ok and cam.position.z>arm and cam.position.z<5,"camera extends smoothly after leaving the wall")
	pose_rows[0].position.x = 0.0
	check(cam.update_view(SCOPE,59,.016).ok and is_equal_approx(cam.position.z,arm),"returning behind obstruction retracts immediately")
	var raw := adapter.query_sweep_batch([{"from":[0,1650,0],"to":[0,1650,5000],"ignored_handles":["player"]}],{"scope_id":SCOPE,"tick":59})
	check(raw.ok and raw.value.is_empty(),"center ray alone misses the narrow obstruction")
	check(cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_view(SCOPE,60,.016).ok,"first person")
	check(cam.position.is_equal_approx(Vector3(0,1.65,0)) and cam.is_current(),"unobstructed eye height")
	var picked := cam.pick(SCOPE,screen_center())
	check(picked.ok and picked.value!=null and picked.value.visible_entity==ALLY and picked.value.position_mm[2] < -3900,"screen center picks foremost visible handle")
	if picked.ok and picked.value!=null: picked.value.visible_entity.index = 42
	check(ALLY.index==1,"picked values do not alias the permitted view")
	revealed = false
	var concealed := cam.pick(SCOPE,screen_center())
	check(concealed.ok and concealed.value==null,"hidden frontline actor withholds identity, coordinates and background")
	revealed = true
	var terrain_screen := cam.unproject_position(Vector3(1.8,1.65,-7))
	var terrain := cam.pick(SCOPE,terrain_screen)
	check(terrain.ok and terrain.value is Dictionary and terrain.value.visible_entity==null,"terrain command returns visible position without actor")
	check(not cam.pick(SCOPE,Vector2(-5,-5)).ok and not cam.pick(SCOPE,screen_center(),0).ok,"invalid screen or ray length")
	check(pose_rows==original,"physics and selected handles left unchanged by the camera")
	pose_rows[0].position = Vector3(10,0,0)
	check(cam.update_view(SCOPE,61,.016).ok and cam.position.y <1.38 and cam.position.y>1.0,"ceiling clips first-person eye sphere")
	pose_rows[0].position = Vector3.ZERO
	pose_rows[0].mounted = true
	pose_rows[0].mount_position = Vector3(-5,0,0)
	check(cam.set_mode(SCOPE,"mounted",PLAYER).ok and cam.update_view(SCOPE,62,.016).ok and is_equal_approx(cam.position.x,-5+Camera.SHOULDER) and cam.position.y>=2.44 and is_equal_approx(cam.position.z,Camera.CHASE_DISTANCE+Camera.MOUNTED_BACK),"mounted chase frames the saddle at full distance on the switching frame")
	check(cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_view(SCOPE,63,.016).ok and is_equal_approx(cam.position.y,2.45),"mounted first-person eye")
	pose_rows[0].mounted = false
	check(not cam.set_mode(SCOPE,"mounted",PLAYER).ok and cam.state().mode=="first","dismounted rider cannot request mounted view")
	pose_rows[0].erase("mount_position")
	var before := cam.global_transform
	check(not cam.update_view(SCOPE,62,.1,Vector2(1,1)).ok and cam.global_transform==before,"stale frame does not move view")
	check(cam.update_view(SCOPE,64,.016).ok and cam.position.is_equal_approx(Vector3(0,1.65,0)),"dismount restores foot eye")
	functional_results["T-CAM-01"] = {"pass":failures==start,"grazing_arm_m":arm,"updates":60,"update_p95_us":timing[56]}
	start = failures
	check(cam.set_mode(SCOPE,"spectator",ALLY).ok and cam.update_view(SCOPE,65,.016).ok,"permitted spectator target")
	var legal := cam.global_transform
	check(not cam.set_mode(SCOPE,"spectator",ENEMY).ok and cam.state().target==ALLY and cam.global_transform==legal,"denied enemy switch preserves permitted camera")
	spectate = false
	check(not cam.update_view(SCOPE,64,.016).ok and cam.state().mode=="deployment" and cam.state().active,"revocation switches to permitted deployment camera")
	check(cam.state().target.is_empty() and cam.position.x>14.9 and cam.position.y>1.0,"safe camera at deployment focus")
	spectate = true
	check(cam.set_mode(SCOPE,"spectator",ALLY).ok and cam.update_view(SCOPE,67,.016).ok,"new grant recovers spectator")
	pose_rows.erase(1)
	deploy = false
	check(not cam.pick(SCOPE,screen_center()).ok and not cam.state().active and cam.cull_mask==0,"destroyed target with no fallback removes world view before selection")
	check(not cam.update_view(SCOPE,68,.016).ok and not cam.set_mode(SCOPE,"spectator",ALLY).ok,"no stale target reuse")
	pose_rows[1] = {"handle":{"index":1,"generation":2},"position":Vector3.ZERO}
	check(not cam.set_mode(SCOPE,"spectator",ALLY).ok,"old generation stays invalid")
	check(cam.set_mode(SCOPE,"third",PLAYER).ok and cam.update_view(SCOPE,69,.016).ok,"owner recovers after spectator target destruction")
	fail_query = true
	check(not cam.update_view(SCOPE,70,.016).ok and not cam.state().active,"unavailable sweep hides unverified position")
	fail_query = false
	check(cam.update_view(SCOPE,70,.016).ok,"camera recovers after physical query becomes available")
	chase_framing(71)
	cam.release_scope("foreign")
	check(cam.state().active,"wrong scope cannot release")
	cam.release_scope(SCOPE)
	check(not cam.state().active and cam.state().scope_id.is_empty() and not cam.update_view(SCOPE,0,.1).ok,"release invalidates callbacks and old frames")
	functional_results["T-CAM-03"] = {"pass":failures==start}

func run() -> void:
	root.size=Vector2i(960,600)
	cam = Camera.new()
	root.add_child(cam)
	var args := OS.get_cmdline_user_args()
	var stage := args[0] if args.size() else "main"
	if stage in ["write","read","damaged"] and OS.get_environment("RECOLLECTION_CAMERA_TEST")!="isolated":
		printerr("Use restart.py for isolated settings tests")
		quit(2)
		return
	if stage=="write":
		options_writer()
	elif stage=="damaged":
		var old := cam.state()
		check(not bind_camera().ok and cam.state()==old,"malformed settings cannot partly bind or apply")
	else:
		adapter = Adapter.new(root,true)
		var token := adapter.open_scope(SCOPE)
		check(token.ok and adapter.load_scene({"id":"base:scene/camera_arena","simulation_scene":"res://tests/p2/camera/arena.tscn"},token.value).ok,"load real EngineAdapter physics world")
		if DisplayServer.get_name()!="headless":
			var fixtures := ARENA.instantiate()
			for name in ["AuthorizedTarget","Terrain"]:
				var body: StaticBody3D = fixtures.get_node(name)
				var mesh := BoxMesh.new()
				mesh.size = body.get_node("Shape").shape.size
				var material := StandardMaterial3D.new()
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				material.albedo_color = Color("#19c347") if name=="AuthorizedTarget" else Color("#aa3718")
				mesh.material = material
				var visual := MeshInstance3D.new()
				visual.mesh = mesh
				visual.position = body.position
				root.add_child(visual)
			fixtures.free()
		await physics_frame
		await physics_frame
		if stage=="read":
			var start := failures
			check(bind_camera().ok and cam.fov==91.75 and not cam.state().shake,"new process reopens saved options")
			check(cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_view(SCOPE,1,.016).ok,"camera after restart")
			var no_roll := cam.global_basis
			check(cam.update_view(SCOPE,2,.016,Vector2.ZERO,0,1).ok and cam.global_basis==no_roll,"disabled shake remains disabled with impact")
			var saved:=FileAccess.get_file_as_bytes(Camera.SETTINGS)
			cam.set_zoom_held(true)
			check(cam.update_view(SCOPE,3,.15).ok and cam.fov<91.75 and FileAccess.get_file_as_bytes(Camera.SETTINGS)==saved,"holding first-person zoom preserves the preferences file")
			cam.release_scope(SCOPE)
			check(bind_camera().ok and cam.state().fov==91.75,"same node scene rebind retains options")
			functional_results["T-CAM-02"] = {"pass":failures==start}
			cam.release_scope(SCOPE)
		else:
			exercises()
			if DisplayServer.get_name()!="headless":
				check(bind_camera().ok and cam.set_mode(SCOPE,"first",PLAYER).ok and cam.update_view(SCOPE,1,.016,Vector2(0,.18)).ok,"window camera active")
				await RenderingServer.frame_post_draw
				var color := root.get_texture().get_image().get_pixelv(Vector2i(screen_center()))
				check(color.g>color.r+.10 and color.g>color.b+.08,"visible green body at center of real window")
				own = false
				cam.update_view(SCOPE,2,.016)
				await RenderingServer.frame_post_draw
				var revoked := root.get_texture().get_image().get_pixelv(Vector2i(screen_center()))
				check(revoked.g<color.g-.12,"revoked window no longer renders old authorized target")
				functional_results["window"] = {"adapter":RenderingServer.get_video_adapter_name(),"driver":RenderingServer.get_current_rendering_driver_name(),
					"pixels":[root.size.x,root.size.y],"before":[color.r,color.g,color.b],"after":[revoked.r,revoked.g,revoked.b]}
				cam.release_scope(SCOPE)
		adapter.release_scope(SCOPE)
	print("CAMERA_RESULT ",JSON.stringify({"stage":stage,"checks":checks,"failures":failures,"queries":queries,"cases":functional_results}))
	cam.free()
	quit(int(failures>0))
