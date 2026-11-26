extends SceneTree
## Real BASE loadout + COM equipment/ride state rendered at both LODs.
const Compiler = preload("res://infrastructure/content/compiler.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const Visual = preload("res://presentation/visuals/ports/field_visuals.gd")
const Batches = preload("res://presentation/visuals/field_batches.gd")
const R = preload("res://contracts/result.gd")
const FIELD := "res://content/base/field"
const SCOPE := "mounted_visual"
var vis := Visual.new()
var combat := Combat.new(SCOPE)
var camera := Camera3D.new()
var handles := []
var classes := []
var places := []
var tick := 0
var failures := 0
var checks := 0
var troop: Dictionary
var bow_path: String
var sidearm_path: String
var captions := CanvasLayer.new()

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		printerr("FAIL mounted visual ",message)
		failures += 1

func setup() -> bool:
	var service := Compiler.new()
	var compiled := service.compile(service.scan_packages([Compiler.BASE_PACKAGE,FIELD]),{})
	check(compiled.ok,"compile official field package")
	if not compiled.ok: return false
	var defs: RefCounted = compiled.value.registry
	troop = defs.get_definition("field:troop/mounted_archer","troop").value
	var kit: Dictionary = defs.get_definition(troop.equipment_set_ids[0],"equipment").value
	var bow: Dictionary = defs.get_definition(kit.slots.ranged,"item").value
	bow_path = FIELD.path_join(bow.asset_ref)
	var melee: Dictionary = defs.get_definition(kit.slots.melee,"item").value
	check(troop.role=="mounted_archer" and troop.metadata.model==melee.asset_ref and melee.category=="halberd" and bow.category=="bow","compiled troop, original halberd model and bow")
	var archer: Dictionary = defs.get_definition("field:troop/archer","troop").value
	var archer_kit: Dictionary = defs.get_definition(archer.equipment_set_ids[0],"equipment").value
	sidearm_path = FIELD.path_join(defs.get_definition(archer_kit.slots.melee,"item").value.asset_ref)
	for i in 6:
		var rider := i<4
		var h := {"index":i,"generation":1}
		handles.append(h)
		classes.append(troop.role if rider else "mount")
		var col := i if rider else i-4
		places.append(Vector3((float(col)-1.5)*2.1,0,0))
		var profile := {"role":"cavalry","team":0,"ranged":bow.category} if rider else {"role":"mount","team":0}
		check(combat.enlist(h,profile).ok,"COM enlist "+str(i))
	for i in 2: check(combat.mount(handles[i],handles[4+i]).ok,"COM mounts "+str(i))
	root.add_child(vis)
	root.add_child(camera)
	camera.position = Vector3(0,1.82,10.6)
	camera.fov = 26
	camera.look_at(Vector3(0,1.25,0))
	camera.make_current()
	root.add_child(captions)
	if DisplayServer.get_name()!="headless":
		for i in 4:
			var label := Label.new()
			label.text = ["马上 · 短弓","马上 · 近战","步行 · 短弓","步行 · 近战"][i]
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.add_theme_constant_override("outline_size",4)
			label.size.x = 160
			label.position = Vector2(camera.unproject_position(places[i]).x-80,root.size.y*.80)
			captions.add_child(label)
	var opened := vis.open_field(SCOPE)
	check(opened.ok,"VIS loads GLBs and short bow")
	return opened.ok

func equip(index: int, slot: int) -> Dictionary:
	return {"actor_handle":handles[index],"slot":slot,"item_ref":"bow" if slot==1 else "melee"}

func advance(intents: Array, saddle_turn := 0.0) -> void:
	tick += 1
	var stepped := combat.step(tick,intents,func(_t,_s):return R.ok([]))
	check(stepped.ok,"COM tick")
	if not stepped.ok: return
	for r in stepped.value.get("receipts",[]):
		check(r.get("ok",true),"COM intent")
	var snap: Dictionary = combat.field_view(SCOPE,handles).value.duplicate(true)
	for i in snap.actors.size():
		var a: Dictionary = snap.actors[i]
		a.role = classes[i]
		a.position = places[i]
		a.heading = Vector3(.48,0,1).normalized()
		if a.handle==handles[0]: a.heading=a.heading.rotated(Vector3.UP,saddle_turn)
		a.velocity = Vector3.ZERO
	check(vis.apply_snapshot(snap).ok,"VIS receives COM slots and mount handles")

func figure(i: int) -> Node3D:
	return vis.find_child("Agent_%d_1"%i,true,false)

func inspect_near(i: int, on_horse: bool, bow: bool) -> void:
	var rig := figure(i)
	check(rig!=null and rig.scene_file_path==FIELD.path_join(troop.metadata.model),"near imported general "+str(i))
	if rig==null: return
	var blade := rig.find_child("attach-righthand-mesh",true,false) as MeshInstance3D
	var prop := rig.find_child("ShortBow",true,false) as Node3D
	check(blade!=null and blade.skin!=null and prop!=null and prop.scene_file_path==bow_path,"original skin + actual bow scene")
	if prop==null: return
	var hand := prop.get_parent() as BoneAttachment3D
	var skel := hand.get_parent() as Skeleton3D
	check(hand.bone_name=="LeftHand" and hand.get_bone_idx()==skel.find_bone("LeftHand"),"bow grip attached to left hand")
	check(prop.has_node("Segment6") and prop.has_node("UpperString") and prop.has_node("LowerString") and prop.has_node("NockedArrow/Shaft"),"sixth bow limb, split string and arrow")
	check(prop.is_visible_in_tree()==bow and blade.is_visible_in_tree()!=bow,"exclusive equipped visual")
	check((rig.position.y>.4)==on_horse,"saddle height "+str(i))
	check(prop.global_position.distance_to(skel.to_global(skel.get_bone_global_pose(hand.get_bone_idx()).origin))<.005,"bow grip tracks actual hand")

func leg(i: int) -> Quaternion:
	var skel := figure(i).find_children("*","Skeleton3D",true,false)[0] as Skeleton3D
	return skel.get_bone_pose_rotation(skel.find_bone("LeftUpLeg"))

func batches() -> Dictionary:
	var result := {}
	for node in vis.find_children("*","Node3D",true,false):
		if not node is Batches: continue
		for group in node.groups.values():
			var m: MultiMesh = group.geometry
			for j in m.visible_instance_count:
				# The dummy renderer returns identity for every MultiMesh transform.
				var gpu := DisplayServer.get_name()!="headless"
				var point: Vector3 = m.get_instance_transform(j).origin if gpu else group.transforms[j].origin
				for i in 4:
					if absf(point.x-places[i].x)<.12 and ((i<2 and point.y>.4) or (i>=2 and absf(point.y)<.01)):
						result[i] = m.mesh
	return result

func waiting_frames() -> void:
	await process_frame
	await process_frame

func visible_uses(mesh: Mesh) -> int:
	var count := 0
	for node: MultiMeshInstance3D in vis.find_children("*","MultiMeshInstance3D",true,false):
		if node.multimesh.mesh==mesh: count += node.multimesh.visible_instance_count
	return count

func capture(stage: String) -> void:
	if DisplayServer.get_name()=="headless": return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			var path := arg.trim_prefix("--output=").path_join("mounted-"+stage+".png")
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(path)==OK,"window screenshot "+stage)
			print("MOUNTED_SNAPSHOT ",path)

func original_roles() -> void:
	var actors := []
	for role in ["infantry","cavalry","archer"]:
		var i := actors.size()
		actors.append({"handle":{"index":10+i,"generation":1},"team":0,"role":role,"weapon_slot":0,"position":places[i],"velocity":Vector3.ZERO,"heading":Vector3.BACK})
	tick += 1
	check(vis.apply_snapshot({"scope_id":SCOPE,"tick":tick,"actors":actors}).ok,"original three roles")
	vis.render_interpolated(1,camera.position)
	for i in 2:
		var weapon := figure(10+i).find_child("attach-righthand-mesh",true,false) as MeshInstance3D
		check(weapon!=null and weapon.skin!=null and weapon.is_visible_in_tree(),"native infantry / cavalry weapon "+str(i))
	var sidearm := figure(12).find_child("Sidearm",true,false) as MeshInstance3D
	var crossbow := figure(12).find_child("attach-righthand-mesh",true,false) as MeshInstance3D
	check(sidearm!=null and sidearm.scene_file_path==sidearm_path and sidearm.get_parent().bone_name=="RightHand" and sidearm.visible and not crossbow.visible,"official archer sidearm")
	actors[2].weapon_slot = 1
	check(vis.apply_snapshot({"scope_id":SCOPE,"tick":tick+1,"actors":actors}).ok,"archer swaps back")
	vis.render_interpolated(1,camera.position)
	check(not sidearm.visible and crossbow.visible,"crossbow restored")

func run() -> void:
	if not setup():
		quit(1)
		return
	advance([equip(0,1),equip(2,1)])
	vis.render_interpolated(1,camera.position)
	await waiting_frames()
	for i in 4: inspect_near(i,i<2,i%2==0)
	check(leg(0).angle_to(leg(2))>.45,"mounted and standing skeleton poses differ")
	var bow_tip: MeshInstance3D = figure(0).find_child("Segment1",true,false)
	var near_tip := figure(0).global_transform.affine_inverse()*bow_tip.global_position
	await capture("near")
	vis.render_interpolated(1,camera.position,0)
	await waiting_frames()
	check(vis.report().near_skeletons==0 and vis.report().far_animated_instances==6,"same camera renders real far meshes")
	var far := batches()
	check(far.size()==4,"four rider meshes found")
	if far.size()==4:
		var mesh_ids := {}
		for i in 4: mesh_ids[far[i].get_instance_id()] = true
		check(mesh_ids.size()==4,"four independently visible far variants")
		var verts: PackedVector3Array = far[0].surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(Array(verts).any(func(p):return p.distance_to(near_tip)<.11),"far bow limb matches near hand pose")
		check(verts.size()!=far[1].surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),"far bow and original melee have different geometry")
	await capture("far")
	check(combat.dismount(handles[0]).ok,"COM dismount")
	advance([equip(0,0)])
	vis.render_interpolated(1,camera.position,0)
	if far.size()==4:
		check(visible_uses(far[0])==0 and visible_uses(far[3])==2,"same far rider switches from mounted bow to standing halberd")
	vis.render_interpolated(1,camera.position)
	await waiting_frames()
	inspect_near(0,false,false)
	check(leg(0).angle_to(leg(2))<.07,"legs restored on dismount")
	check(combat.mount(handles[0],handles[4]).ok,"COM remount")
	advance([equip(0,1)])
	vis.render_interpolated(1,camera.position,0)
	if far.size()==4:
		check(visible_uses(far[0])==1 and visible_uses(far[3])==1,"far rider restores mounted bow")
	vis.render_interpolated(1,camera.position)
	await waiting_frames()
	inspect_near(0,true,true)
	check(leg(0).angle_to(leg(2))>.45,"remount updates immediately")
	var skel := figure(0).find_children("*","Skeleton3D",true,false)[0] as Skeleton3D
	var upper := skel.find_bone("RightArm")
	var at_rest := skel.get_bone_pose_rotation(upper)
	var starts := []
	for i in 4:
		starts.append({"actor_handle":handles[i],"input_phase":"start","direction":"up","weapon_slot":1 if i%2==0 else 0,"target_hint":null})
	advance(starts)
	vis.render_interpolated(1,camera.position)
	await waiting_frames()
	check(skel.get_bone_pose_rotation(upper).angle_to(at_rest)>.3,"committed bow action poses the drawing arm")
	inspect_near(0,true,true)
	await capture("action")
	vis.render_interpolated(1,camera.position,0)
	await waiting_frames()
	var attacking := batches()
	check(attacking.size()==4 and far.size()==4 and attacking[0]!=far[0] and attacking[1]!=far[1],"bow and halberd switch to actual far action meshes")
	await capture("action-far")
	vis.render_interpolated(1,camera.position)
	var rider := figure(0)
	skel = rider.find_children("*","Skeleton3D",true,false)[0] as Skeleton3D
	var initial_course := rider.global_basis
	var seated_leg := leg(0)
	var spine := skel.find_bone("Spine")
	var before_turn := skel.global_basis*skel.get_bone_global_pose(spine).basis
	advance([],PI/2)
	vis.render_interpolated(1,camera.position)
	var after_turn := skel.global_basis*skel.get_bone_global_pose(spine).basis
	check(after_turn.x.normalized().dot(before_turn.x.rotated(Vector3.UP,PI/2).normalized())>.95 and after_turn.z.normalized().dot(before_turn.z.rotated(Vector3.UP,PI/2).normalized())>.95,"sideways mounted aim turns the torso through the requested angle")
	check(rider.global_basis.is_equal_approx(initial_course) and seated_leg.angle_to(leg(0))<.05,"saddle and legs keep the horse course during sideways aim")
	var instance: WeakRef = weakref(figure(0))
	original_roles()
	check(instance.get_ref()==null,"despawn frees rider and both weapon instances")
	instance = weakref(figure(12))
	vis.release_scope(SCOPE)
	check(vis.get_child_count()==0 and vis.report().visible_actors==0 and instance.get_ref()==null,"release rigs and mesh batches")
	captions.free()
	camera.free()
	vis.free()
	print("MOUNTED_VISUAL checks=",checks," failures=",failures," display=",DisplayServer.get_name()," viewport=",root.size)
	quit(int(failures>0))
