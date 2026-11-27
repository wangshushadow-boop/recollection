extends SceneTree
const Vis = preload("res://presentation/visuals/ports/field_visuals.gd")
const Melee = preload("res://mission/combat/melee.gd")
const R = preload("res://contracts/result.gd")
const A := {"index":0,"generation":1}
const B := {"index":1,"generation":1}
var failures := 0
var vis: Vis

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ",label)

func _initialize() -> void:
	call_deferred("_run")

func actor(handle: Dictionary, role: String, at: Vector3, team: int) -> Dictionary:
	return {"handle":handle,"role":role,"team":team,"position":at,"heading":Vector3.BACK,
		"velocity":Vector3.ZERO,"phase":"Ready","since":0,"direction":""}

func fig(id: int) -> Node3D:
	return vis.find_child("Agent_%d_1"%id,true,false)

func draw_player(tick: int, row: Dictionary) -> void:
	check(vis.apply_snapshot({"scope_id":"weapons","tick":tick,"actors":[row]}).ok,"weapon pose snapshot")
	vis.render_interpolated(1.0,Vector3.ZERO)

func check_general_grips(person: Vis.Models.Figure) -> void:
	# Read the rendered rigid geometry after the attachment updated its transform.
	await process_frame
	await process_frame
	for part: MeshInstance3D in [person.melee_weapon,person.shield]:
		var bone := person.wrist if part==person.melee_weapon else person.left_wrist
		var hand := person.skeleton.to_global(person.skeleton.get_bone_global_pose(bone).origin)
		var nearest := INF
		var faces := part.mesh.get_faces()
		var local_hand := part.to_local(hand)
		for i in range(0,faces.size(),3):
			for edge in 3:
				var point := Geometry3D.get_closest_point_to_segment(local_hand,faces[i+edge],faces[i+(edge+1)%3])
				nearest = minf(nearest,hand.distance_to(part.to_global(point)))
		var center := hand.distance_to(part.to_global(part.mesh.get_aabb().get_center()))
		print("COMMANDER_GRIP ",part.name," nearest_m=%.3f center_m=%.3f"%[nearest,center])
		check(nearest<.18 and center<.24,"actual equipped geometry follows "+str(part.name))

func weapon_poses() -> void:
	check(vis.open_field("weapons").ok,"open equipment poses")
	var hero := actor(A,"infantry",Vector3.ZERO,0)
	hero.merge({"commander":true,"weapon_kind":"melee","weapon_slot":0,"shield":32,"windup_ticks":9,"active_ticks":4,"recovery_ticks":9})
	draw_player(1,hero)
	var person: Vis.Models.Figure = vis._actors[0].figure
	check(person.root.scene_file_path.ends_with("/general.glb") and person.root.find_child("CommandPauldronRight",true,false)!=null,"commander wears own general rig and shoulder armour")
	var donor := preload("res://content/base/field/models/spear_soldier.glb").instantiate()
	check(person.melee_weapon.mesh==donor.find_child("attach-righthand-mesh",true,false).mesh and person.shield.mesh==donor.find_child("attach-lefthand-mesh",true,false).mesh,"real transferred spear and shield")
	donor.free()
	check(person.shield.visible and person.melee_weapon.visible,"melee kit drawn")
	await check_general_grips(person)
	var normals: Array[Vector3] = []
	hero.phase = "Guard"
	for i in Vis.Models.DIRECTIONS.size():
		hero.direction = Vis.Models.DIRECTIONS[i]
		hero.since = 2+i
		draw_player(2+i,hero)
		var normal := person.skeleton.get_bone_global_pose(person.left_wrist).basis.y
		for previous in normals: check(normal.dot(previous)<.91,"shield covers distinct direction")
		normals.append(normal)
	await check_general_grips(person)
	hero.phase = "Ready"
	hero.shield = 0
	draw_player(6,hero)
	check(not person.shield.visible and person.melee_weapon.visible,"broken shield hidden")
	hero.merge({"phase":"Windup","since":7,"weapon_kind":"bow","weapon_slot":1,"shield":32,"windup_ticks":18,"aim_pitch":.31},true)
	draw_player(7,hero)
	check(person.hand.bone_name=="LeftHand" and person.ranged_weapon.visible and not person.shield.visible and not person.melee_weapon.visible,"same infantry skin swaps to left-hand bow")
	check(person.arrow.is_visible_in_tree() and is_equal_approx(person.arrow.position.z,.14),"arrow nocked to undrawn string")
	draw_player(16,hero)
	check(is_equal_approx(person.arrow.position.z,.31),"half draw follows authority duration")
	hero.phase = "Hold"
	hero.since = 25
	draw_player(25,hero)
	var bow_hand := person.skeleton.get_bone_global_pose(person.left_wrist)
	var nock := bow_hand*person.arrow.position
	var drawing_hand := person.skeleton.get_bone_global_pose(person.wrist).origin
	check(nock.distance_to(drawing_hand)<.025 and person.arrow.is_visible_in_tree(),"drawing hand reaches the full draw nock")
	check((-bow_hand.basis.z).dot(Vector3.BACK.rotated(Vector3.RIGHT,-.31))>.999,"arrow follows elevation despite canted limbs")
	check(absf(bow_hand.basis.y.x)>.4,"canted bow visible around shoulder")
	for string: MeshInstance3D in [person.upper_string,person.lower_string]:
		check((string.position-string.basis.y*.5).distance_to(person.arrow.position)<.002,"string meets nock")
	hero.phase = "Active"
	hero.since = 27
	draw_player(27,hero)
	check(not person.arrow.is_visible_in_tree() and is_equal_approx(person.arrow.position.z,.14),"released arrow leaves the string")
	hero.phase = "Ready"
	hero.weapon_kind = "melee"
	hero.weapon_slot = 0
	draw_player(28,hero)
	check(person.melee_weapon.visible and person.shield.visible and not person.ranged_weapon.visible,"original arms restored")
	command_gait(person)
	var enemy := hero.duplicate()
	enemy.handle = B
	enemy.team = 1
	enemy.position = Vector3(1,0,0)
	var soldier := actor({"index":2,"generation":1},"infantry",Vector3(-1,0,0),1)
	check(vis.apply_snapshot({"scope_id":"weapons","tick":29,"actors":[hero,enemy,soldier]}).ok,"opposing commander and troop")
	vis.render_interpolated(1,Vector3.ZERO)
	var rival: Vis.Models.Figure = vis._actors[1].figure
	check(rival.root.scene_file_path==person.root.scene_file_path and rival.cape.material_override!=person.cape.material_override and vis._actors[2].figure.root.scene_file_path.ends_with("/spear_soldier.glb"),"two colours and distinct common infantry")
	vis.render_interpolated(1,Vector3(100,0,0))
	check(vis._batches.groups["commander0"].geometry.visible_instance_count==2 and vis._batches.groups["infantry0"].geometry.visible_instance_count==1,"both general rigs retained at distance")
	vis.release_scope("weapons")

func command_gait(person: Vis.Models.Figure) -> void:
	var raw := preload("res://content/base/field/models/general.glb").instantiate()
	root.add_child(raw)
	var sk := person.skeleton
	var baseline: Skeleton3D = raw.find_children("*","Skeleton3D",true,false)[0]
	var animation: AnimationPlayer = raw.find_children("*","AnimationPlayer",true,false)[0]
	animation.play("Run")
	var model: Vis.Models = vis._models["commander"]
	var chest := sk.find_bone("Spine2")
	var head := sk.find_bone("Head")
	var leg := sk.find_bone("LeftLeg")
	var original_lean := 0.0
	var lean := 0.0
	var tilt := 0.0
	var offset := 0.0
	var leg_error := 0.0
	for tick in 90:
		# Leaving full draw cannot accumulate twists into a running or idle pose.
		model.pose(person,tick,4.5,"Hold","up",tick,false,true,.3)
		model.pose(person,tick,4.5,"Ready","",tick,false,true)
		animation.seek(fposmod(tick/60.0,animation.get_animation("Run").length),true)
		var ch := sk.get_bone_global_pose(chest)
		var face := sk.get_bone_global_pose(head)
		original_lean = maxf(original_lean,baseline.get_bone_global_pose(chest).basis.y.angle_to(Vector3.UP))
		lean = maxf(lean,ch.basis.y.angle_to(Vector3.UP))
		tilt = maxf(tilt,ch.basis.y.angle_to(face.basis.y))
		offset = maxf(offset,absf(ch.origin.x-face.origin.x))
		leg_error = maxf(leg_error,sk.get_bone_pose_rotation(leg).angle_to(baseline.get_bone_pose_rotation(leg)))
	print("COMMANDER_RUN original_chest_deg=%.2f chest_deg=%.2f head_chest_deg=%.2f head_chest_lateral_m=%.3f leg_error_deg=%.3f" % [rad_to_deg(original_lean),rad_to_deg(lean),rad_to_deg(tilt),offset,rad_to_deg(leg_error)])
	check(original_lean>deg_to_rad(40) and lean<deg_to_rad(20) and tilt<deg_to_rad(15) and offset<.055,"chest and head stay aligned across full run cycle")
	check(leg_error<deg_to_rad(.2),"original run footwork")
	model.pose(person,0,0,"Ready","",0,false,true)
	animation.play("Idle")
	animation.seek(0,true)
	check(sk.get_bone_global_pose(head).is_equal_approx(baseline.get_bone_global_pose(head)),"head and chest return to neutral after full draw and run")
	raw.free()

func controls() -> void:
	var ra := actor(A,"cavalry",Vector3(1,0,0),0)
	var rb := actor(B,"mount",Vector3.ZERO,0)
	var rc := actor({"index":2,"generation":1},"archer",Vector3(2,0,0),1)
	ra.mount_handle = B
	var missile := {"id":"a","position":Vector3.UP,"direction":Vector3.FORWARD}
	check(vis.apply_snapshot({"scope_id":"test","tick":1,"actors":[ra,rb,rc],"projectiles":[missile]}).ok,"accept mixed roles")
	vis.render_interpolated(1,Vector3.ZERO)
	check(vis.report().near_skeletons==3 and vis.report().mounts==1 and vis.report().projectiles==1,"live skeletons and arrow")
	check(fig(0).position.y > .40 and fig(0).position.y < .85 and absf(fig(0).position.x)<.15,"registered horse torso anchors rider hips")
	var archer := fig(2)
	var helmet := archer.find_child("garment-hat",true,false) as MeshInstance3D
	check(helmet != null and helmet.material_override.vertex_color_use_as_albedo and helmet.material_override.vertex_color_is_srgb,"imported vertex paint visible on close meshes")
	var crossbow := archer.find_child("attach-righthand-mesh",true,false) as MeshInstance3D
	check(crossbow != null and crossbow.skin != null and crossbow.visible,"equipped crossbow uses skin weights")
	rc.weapon_slot = 0
	rc.position = Vector3(6,0,0)
	ra.mount_handle = null
	check(vis.apply_snapshot({"scope_id":"test","tick":2,"actors":[ra,rb,rc]}).ok,"next frame")
	vis.render_interpolated(.5,Vector3.ZERO)
	check(fig(2).position.x==4 and fig(0).position.y==0,"interpolation and dismount")
	vis.render_interpolated(1,Vector3.ZERO)
	check(not crossbow.visible,"melee slot hides ranged weapon")
	var early := {"type":"hit","actor_handle":A,"event_id":"early","confirmed":true,"position":Vector3.ZERO}
	var deferred_hit := vis.consume_view_events("test",3,[early])
	check(not deferred_hit.ok and deferred_hit.error.retryable and vis.report().impacts==0,"future effect waits for its snapshot")
	var before := vis.report()
	check(not vis.apply_snapshot({"scope_id":"other","tick":3,"actors":[]}).ok,"foreign scope")
	check(not vis.apply_snapshot({"scope_id":"test","tick":2,"actors":[]}).ok,"stale snapshot")
	check(not vis.apply_snapshot({"scope_id":"test","tick":3,"actors":[ra,ra]}).ok and vis.report()==before,"reject duplicate atomically")
	for bad in [{"aim_pitch":NAN},{"windup_ticks":0},{"active_ticks":0.5},{"recovery_ticks":"x"},{"shield":-1},{"weapon_kind":12}]:
		check(not vis.apply_snapshot({"scope_id":"test","tick":3,"actors":[ra,rc.merged(bad,true)],"projectiles":[missile]}).ok and vis.report()==before,"reject invalid action pose atomically")
	var hit := {"type":"hit","actor_handle":A,"event_id":"h","confirmed":false}
	vis.consume_view_events("test",2,[hit])
	check(vis.report().impacts==0,"predicted hit does not create confirmed feedback")
	hit.confirmed = true
	vis.consume_view_events("test",2,[hit,hit,{"type":"downed","event_id":"d","actor_handle":B,"confirmed":true}])
	check(vis.report().impacts==1 and vis.report().corpses==1,"bounded confirmed effects deduplication")
	vis.render_interpolated(1,Vector3(300,0,0))
	check(vis.report().far_animated_instances==3 and vis.report().near_skeletons==0,"distance switches to shared mesh poses")
	check(vis.apply_snapshot({"scope_id":"test","tick":3,"actors":[ra,rb,rc]}).ok,"publish next snapshot")
	check(vis.consume_view_events("test",3,[early,early]).ok and vis.report().impacts==2,"retried effect applied once")
	check(vis.apply_snapshot({"scope_id":"test","tick":190,"actors":[]}).ok,"release actors")
	vis.render_interpolated(1,Vector3.ZERO)
	check(vis.report().corpses==0 and vis.report().impacts==0,"visual lifetimes")
	vis.release_scope("test")
	check(vis.get_child_count()==0 and vis.report().visible_actors==0,"scope cleanup")

func replay(scope: String, eye: Vector3, direction: String) -> Array:
	var sim := Melee.new()
	sim.add_actor(A)
	sim.add_actor(B)
	var results := []
	var attack_pose := Quaternion.IDENTITY
	check(vis.open_field(scope).ok,"new replay scope")
	for tick in range(1,15):
		var inputs := []
		var changes := {1:"start",3:"hold",8:"release"}
		if changes.has(tick):
			inputs.append({"actor_handle":A,"input_phase":changes[tick],"direction":direction,"weapon_slot":0,"target_hint":B})
		var step := sim.step(tick,inputs,func(_t,swings):
			var contacts := []
			for swing in swings:
				contacts.append({"attacker":A,"attack_id":swing.attack_id,"target":B,"contact_order":0})
			return R.ok(contacts))
		check(step.ok,"real COM fixed step")
		var a := actor(A,"infantry",Vector3.ZERO,0)
		var b := actor(B,"infantry",Vector3.BACK,1)
		a.merge(sim.view(A).value,true)
		b.merge(sim.view(B).value,true)
		var snap := {"scope_id":scope,"tick":tick,"actors":[a,b]}
		var original := snap.duplicate(true)
		check(vis.apply_snapshot(snap).ok,"consume combat read models")
		if eye == Vector3.ZERO:
			for sample in [.25,.5,.75,1.0]:
				vis.render_interpolated(sample,eye)
		elif tick%2==0:
			vis.render_interpolated(1.0,eye)
		check(snap==original,"render does not alter authoritative projection")
		if tick==9 and fig(0):
			var skeleton := fig(0).find_children("*","Skeleton3D",true,false)[0] as Skeleton3D
			attack_pose = skeleton.get_bone_pose_rotation(skeleton.find_bone("RightArm"))
		results.append([a.phase,b.hp,step.value.hits])
	check(sim.view(B).value.hp==86,"real charged hit applied once")
	vis.release_scope(scope)
	return [results,attack_pose]

# Pose batches can empty, reuse old slots in a different order, or grow
# beyond their previous capacity without a change to the underlying pose mesh.
func batch_slot_reuse() -> void:
	var batches := Vis.Batches.new()
	root.add_child(batches)
	batches.add_group("pose", BoxMesh.new())
	var group = batches.groups.pose
	var mesh: MultiMesh = group.geometry
	for ids: Array in [[1,2,3], [1,2,3], [], [3,1], [3,1,2,4,5,6,7,8,9], [9]]:
		batches.begin_frame()
		for id: int in ids:
			var transform3 := Transform3D(Basis.IDENTITY, Vector3(id,0,0))
			batches.push("pose", transform3, Color.RED if id % 2 else Color.BLUE)
		batches.flush()
		check(mesh.visible_instance_count == ids.size(), "batch visible count after reuse")
		for i in ids.size():
			var id: int = ids[i]
			var expected_color := Color.RED if id % 2 else Color.BLUE
			check(group.transforms[i].origin.x == id and group.colors[i] == expected_color,
				"cached transform and tint after reorder")
			if DisplayServer.get_name() != "headless":
				check(mesh.get_instance_transform(i).origin.x == id and mesh.get_instance_custom_data(i).is_equal_approx(expected_color),
					"rendered transform and tint after reallocation")
	batches.free()

func _run() -> void:
	batch_slot_reuse()
	vis = Vis.new()
	root.add_child(vis)
	var opened := vis.open_field("test")
	check(opened.ok,"BASE imported field models")
	if opened.ok:
		controls()
		await weapon_poses()
		var poses := []
		for dir: String in ["left","right","up","thrust"]:
			var near_run := replay("close-"+dir,Vector3.ZERO,dir)
			var far_run := replay("distant-"+dir,Vector3(250,0,0),dir)
			check(near_run[0]==far_run[0],"identical authoritative actions, damage and HP across LOD")
			for prior: Quaternion in poses:
				check(prior.angle_to(near_run[1])>.025,"distinct active weapon shoulder pose")
			poses.append(near_run[1])
	vis.free()
	print("VIS_FUNCTIONAL failures=",failures)
	quit(int(failures>0))
