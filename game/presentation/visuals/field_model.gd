extends RefCounted
## Near meshes retain the imported skeleton, equipment and gait clips. The same
## mesh and joint weights supply a small shared pose bank for distant units.
const FILES := {"infantry":"spear_soldier", "archer":"crossbowman", "cavalry":"general", "mount":"horse", "mounted_archer":"general"}
const SHORT_BOW := "res://content/base/field/short_bow.tscn"
const SIDEARM := "res://content/base/field/sidearm.tscn"
const COLORS := [Color("#a73325"), Color("#276d98")]
const HORSE_SCALE := 0.43
const SADDLE_OFFSET := Vector3(0, .59, .039)
const DIRECTIONS := ["up","left","right","thrust"]
const POSES_PER_SET := 8
var scene: PackedScene
var hand_prop: PackedScene
var commander_arms := {}
var shoulder_plate: SphereMesh
var role: String
var poses: Array[Mesh] = []
var vertex_paint := StandardMaterial3D.new()

class Figure:
	var root: Node3D
	var player: AnimationPlayer
	var skeleton: Skeleton3D
	var spine: int
	var neck: int
	var torso_chain: PackedInt32Array
	var right: int
	var forearm: int
	var wrist: int
	var left: int
	var left_forearm: int
	var left_wrist: int
	var left_leg: int
	var right_leg: int
	var tunic: MeshInstance3D
	var cape: MeshInstance3D
	var ranged_weapon: Node3D
	var melee_weapon: MeshInstance3D
	var shield: MeshInstance3D
	var upper_string: MeshInstance3D
	var lower_string: MeshInstance3D
	var arrow: Node3D
	var draw := 0.0
	var hand: BoneAttachment3D
	var clip := ""
	var posed := false

func load_model(kind: String, host: Node3D) -> bool:
	role = kind
	vertex_paint.vertex_color_use_as_albedo = true
	vertex_paint.vertex_color_is_srgb = true
	vertex_paint.roughness = .9
	var path := "res://content/base/field/models/%s.glb" % ("general" if role=="commander" else FILES[kind])
	if not ResourceLoader.exists(path):
		return false
	scene = load(path) as PackedScene
	if scene == null:
		return false
	if role=="commander":
		# These two pieces are each bound to one named hand. Keep their original
		# inverse binds so each grip is measured from that wrist on the general.
		var donor := preload("res://content/base/field/models/spear_soldier.glb").instantiate()
		for name in ["attach-righthand-mesh","attach-lefthand-mesh"]:
			var piece := donor.find_child(name,true,false) as MeshInstance3D
			if piece==null or piece.skin==null:
				donor.free()
				return false
			var hand_name := "RightHand" if name=="attach-righthand-mesh" else "LeftHand"
			for bind in piece.skin.get_bind_count():
				if piece.skin.get_bind_name(bind)==StringName(hand_name):
					commander_arms[name] = {"mesh":piece.mesh,"bone":hand_name,"offset":piece.skin.get_bind_pose(bind)}
					break
		donor.free()
		if commander_arms.size()!=2: return false
		shoulder_plate = SphereMesh.new()
		shoulder_plate.radius = .15
		shoulder_plate.height = .15
		shoulder_plate.radial_segments = 12
		shoulder_plate.rings = 4
		var brass := StandardMaterial3D.new()
		brass.albedo_color = Color("#b38b4c")
		brass.metallic = .5
		brass.roughness = .63
		shoulder_plate.material = brass
	if role in ["mounted_archer","archer"]:
		hand_prop = load(SHORT_BOW if role=="mounted_archer" else SIDEARM) as PackedScene
		if hand_prop == null: return false
	var figure := instantiate(host)
	if figure.skeleton == null or figure.player == null or (hand_prop != null and (figure.ranged_weapon == null or figure.melee_weapon == null)):
		figure.root.free()
		return false
	# The mounted archer and cavalry use the same general.glb melee mesh and pose bank.
	var variants := 3 if role in ["infantry","commander"] else (1 if role=="mount" else 2)
	for variant in variants:
		for frame in POSES_PER_SET:
			var phase := "Guard" if frame == 7 else ("Active" if frame >= 3 else "Ready")
			var direction: String = DIRECTIONS[clampi(frame-3,0,3)]
			var ranged := role=="mounted_archer" or (role=="archer" and variant==0) or (role in ["infantry","commander"] and variant==1)
			if ranged and role!="archer" and frame>=3 and frame<=6:
				phase = ["Windup","Hold","Active","Recovery"][frame-3]
			pose(figure, float(frame) * 13.0, 0 if frame == 0 else 2.8, phase, direction,
				frame*13-1, role in ["cavalry","mounted_archer"] and variant==0, ranged,0,2.0 if ranged else 1.0,variant!=2)
			poses.append(_bake(figure))
	figure.root.free()
	return true

func instantiate(host: Node3D) -> Figure:
	var f := Figure.new()
	f.root = scene.instantiate()
	host.add_child(f.root)
	if role == "mount":
		f.root.scale = Vector3.ONE * HORSE_SCALE
	else:
		# These imported materials omit the flag although every surface carries COLOR_0.
		for part: MeshInstance3D in f.root.find_children("*","MeshInstance3D",true,false):
			part.material_override = vertex_paint
	var players := f.root.find_children("*", "AnimationPlayer", true, false)
	var skeletons := f.root.find_children("*", "Skeleton3D", true, false)
	if players.is_empty() or skeletons.is_empty():
		return f
	f.player = players[0]
	f.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	f.skeleton = skeletons[0]
	f.spine = f.skeleton.find_bone("Spine")
	f.neck = f.skeleton.find_bone("Neck")
	f.right = f.skeleton.find_bone("RightArm")
	f.forearm = f.skeleton.find_bone("RightForeArm")
	f.wrist = f.skeleton.find_bone("RightHand")
	f.left = f.skeleton.find_bone("LeftArm")
	f.left_forearm = f.skeleton.find_bone("LeftForeArm")
	f.left_wrist = f.skeleton.find_bone("LeftHand")
	f.left_leg = f.skeleton.find_bone("LeftUpLeg")
	f.right_leg = f.skeleton.find_bone("RightUpLeg")
	f.tunic = f.root.find_child("garment-tunic", true, false) as MeshInstance3D
	if role=="commander":
		_dress_commander(f)
	if role in ["infantry","commander"]:
		f.melee_weapon = f.root.find_child("attach-righthand-mesh",true,false) as MeshInstance3D
		f.shield = f.root.find_child("attach-lefthand-mesh",true,false) as MeshInstance3D
	if role in ["archer","mounted_archer"] and f.wrist>=0:
		var original := f.root.find_child("attach-righthand-mesh",true,false) as MeshInstance3D
		f.hand = BoneAttachment3D.new()
		f.skeleton.add_child(f.hand)
		f.hand.bone_name = "LeftHand" if role=="mounted_archer" else "RightHand"
		if role == "mounted_archer":
			f.melee_weapon = original
			_attach_bow(f)
		else:
			f.ranged_weapon = original
			f.melee_weapon = hand_prop.instantiate() as MeshInstance3D
			f.hand.add_child(f.melee_weapon)
	return f

func _dress_commander(f: Figure) -> void:
	f.root.find_child("attach-righthand-mesh",true,false).free()
	for name: String in commander_arms:
		var arm: Dictionary = commander_arms[name]
		var grip := BoneAttachment3D.new()
		f.skeleton.add_child(grip)
		grip.bone_name = arm.bone
		var part := MeshInstance3D.new()
		part.name = name
		part.mesh = arm.mesh
		part.skeleton = NodePath("")
		part.transform = arm.offset
		part.material_override = vertex_paint
		grip.add_child(part)
	f.cape = f.root.find_child("garment-cape",true,false)
	for name in ["Spine1","Spine2","Neck","Head"]:
		f.torso_chain.append(f.skeleton.find_bone(name))
	for side in ["Left","Right"]:
		var attachment := BoneAttachment3D.new()
		f.skeleton.add_child(attachment)
		attachment.bone_name = side+"Arm"
		var plate := MeshInstance3D.new()
		plate.name = "CommandPauldron"+side
		plate.mesh = shoulder_plate
		plate.position = Vector3(.035 if side=="Left" else -.035,.038,0)
		attachment.add_child(plate)

func _attach_bow(f: Figure) -> void:
	if f.hand==null:
		f.hand = BoneAttachment3D.new()
		f.skeleton.add_child(f.hand)
		f.hand.bone_name = "LeftHand"
	f.ranged_weapon = preload(SHORT_BOW).instantiate()
	f.hand.add_child(f.ranged_weapon)
	f.upper_string = f.ranged_weapon.get_node("UpperString")
	f.lower_string = f.ranged_weapon.get_node("LowerString")
	f.arrow = f.ranged_weapon.get_node("NockedArrow")

func pose(f: Figure, time: float, speed: float, phase: String, direction: String, since: int,
		mounted: bool, ranged: bool, pitch := 0.0, phase_ticks := 3.0, shield_intact := true) -> void:
	var clip := "Idle"
	if speed > .12 and not mounted:
		clip = ("Gallop" if role == "mount" else "Run") if speed > 3.3 else "Walk"
	if f.clip != clip:
		f.player.play(clip)
		f.clip = clip
	# A GLB gait may omit static joints. Start each overlay from the sampled
	# gait even when a clip has no rotation key to undo the last render's twist.
	if f.posed:
		for bone: int in [f.spine,f.neck,f.right,f.forearm,f.wrist,f.left,f.left_forearm,f.left_wrist]:
			f.skeleton.reset_bone_pose(bone)
	f.posed = f.right>=0 and (role=="commander" or mounted or ranged or phase not in ["Ready","Downed"])
	var duration := f.player.get_animation(clip).length
	f.player.seek(fposmod(time / 60.0, maxf(duration, .01)), true)
	if f.right < 0:
		return
	if not mounted and clip in ["Run","Walk"] and not f.torso_chain.is_empty():
		# The source run rotates two consecutive chest joints by up to 27° and
		# 39°. Reduce this double lean and its neck compensation before actions.
		for bone in f.torso_chain:
			var rest := f.skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
			f.skeleton.set_bone_pose_rotation(bone,rest.slerp(f.skeleton.get_bone_pose_rotation(bone),.24))
	if ranged and role in ["infantry","commander"] and f.ranged_weapon==null:
		_attach_bow(f)
	if f.ranged_weapon:
		f.ranged_weapon.visible = ranged
		f.melee_weapon.visible = not ranged
	if f.shield: f.shield.visible = shield_intact and not ranged
	if f.arrow: f.arrow.visible = ranged and phase in ["Windup","Hold"]
	if mounted:
		for joint in [f.left_leg, f.right_leg]:
			var sign_x := -1 if joint == f.left_leg else 1
			f.skeleton.set_bone_pose_rotation(joint, f.skeleton.get_bone_rest(joint).basis.get_rotation_quaternion()
				* Quaternion(Vector3.RIGHT, -.67) * Quaternion(Vector3.BACK, sign_x*.24))
	var weight := smoothstep(0.0,maxf(1.0,phase_ticks),time-since)
	if f.arrow and ranged:
		_bow_pose(f,phase,pitch,weight)
		return
	if role=="commander" and not ranged:
		# The general's original carry clip was authored for a halberd. Point
		# the transferred spear above the right shoulder, clear of the cloak.
		var shoulder := f.skeleton.get_bone_global_pose(f.right).origin
		var swing := clampf(f.skeleton.get_bone_global_pose(f.wrist).origin.z-shoulder.z,-.35,.35)
		_reach(f.skeleton,f.right,f.forearm,f.wrist,shoulder+Vector3(-.16,-.33,.12+.32*swing),Vector3(-.7,-.4,-.35),1)
		_set_world_rotation(f.skeleton,f.wrist,Quaternion(Vector3.BACK,Vector3(-.2,.85,.50).normalized()))
	if phase not in ["Windup","Hold","Guard","Active","Recovery","Stagger"]:
		return
	if phase=="Stagger":
		turn_in_saddle(f,-.18*(1.0-weight))
		return
	if ranged:
		var forward := Vector3.BACK.rotated(Vector3.RIGHT,-pitch)
		_aim_bone(f.skeleton,f.right,f.forearm,Vector3(-.2,-.55,.7))
		_aim_bone(f.skeleton,f.forearm,f.wrist,forward)
		_set_world_rotation(f.skeleton,f.wrist,Quaternion(Vector3.LEFT,forward))
		_aim_bone(f.skeleton,f.left,f.left_forearm,Vector3(.3,-.45,.55))
		_aim_bone(f.skeleton,f.left_forearm,f.left_wrist,Vector3(-.65,.25,.7))
		return
	_melee_pose(f,phase,direction,weight)

## Apply mounted aim after sampling the clip and positioning hands. The pelvis
## and legs stay with the saddle while the bow or melee weapon follows the torso.
static func turn_in_saddle(f: Figure, turn: float) -> void:
	if f.spine<0 or is_zero_approx(turn): return
	var parent := f.skeleton.get_bone_global_pose(f.skeleton.get_bone_parent(f.spine)).basis
	var up := (f.skeleton.global_basis*parent).inverse()*Vector3.UP
	f.skeleton.set_bone_pose_rotation(f.spine,Quaternion(up.normalized(),turn)*f.skeleton.get_bone_pose_rotation(f.spine))

func _melee_pose(f: Figure, phase: String, direction: String, progress: float) -> void:
	# The imported people face +Z with their left shoulder on +X.
	var side := 1.0 if direction=="left" else -1.0
	var lift := 1.0 if direction=="up" else (-.55 if direction=="thrust" else .1)
	var line := Vector3(side if direction in ["left","right"] else 0.0,lift,1.0).normalized()
	var skel := f.skeleton
	var blade_axis := Vector3(.26,.89,.38).normalized() if role in ["cavalry","mounted_archer"] else Vector3.BACK
	var shoulder := skel.get_bone_global_pose(f.right).origin
	if phase=="Guard":
		var guard := Vector3(line.x*.20,.01+line.y*.28,.30)
		_reach(skel,f.right,f.forearm,f.wrist,shoulder+guard,Vector3(-.8,-.6,.1),1.0)
		var blade_line := Vector3(-line.x,.8,-.05) if lift<=.9 else Vector3(.95,.12,.12)
		_set_world_rotation(skel,f.wrist,Quaternion(blade_axis,blade_line.normalized()))
		if f.shield and f.shield.visible:
			var left := skel.get_bone_global_pose(f.left).origin
			_reach(skel,f.left,f.left_forearm,f.left_wrist,left+Vector3(-.16,0,.10)+guard,Vector3(.7,-.6,0),1)
			_set_world_rotation(skel,f.left_wrist,Quaternion(Vector3.UP,line))
		return
	var blend := progress if phase=="Windup" else (1.0-progress if phase=="Recovery" else 1.0)
	var swing := progress if phase=="Active" else (1.0 if phase=="Recovery" else 0.0)
	var wind_hand := Vector3(side*.28,.10,-.03)
	var end_hand := Vector3(-side*.19,-.02,.38)
	var start_tip := Vector3(side,.16,-.22)
	var end_tip := Vector3(-side,-.12,.28)
	var twist := side*lerpf(.42,-.32,swing)
	if direction=="up":
		wind_hand = Vector3(-.10,.42,.01)
		end_hand = Vector3(.04,-.14,.43)
		start_tip = Vector3(-.05,1,-.35)
		end_tip = Vector3(.02,-.65,.77)
		twist = .16*(1-2*swing)
	elif direction=="thrust":
		wind_hand = Vector3(-.16,-.08,-.12)
		end_hand = Vector3(.08,-.03,.51)
		start_tip = Vector3(-.08,-.17,1)
		end_tip = Vector3(.02,.02,1)
		twist = lerpf(-.30,.35,swing)
	turn_in_saddle(f,twist*blend)
	shoulder = skel.get_bone_global_pose(f.right).origin
	var reach := wind_hand.lerp(end_hand,swing)
	reach.z += .12*sin(swing*PI)
	_reach(skel,f.right,f.forearm,f.wrist,shoulder+reach,Vector3(-.8,-.5,0),blend)
	var tip := start_tip.lerp(Vector3.BACK,swing*2) if swing<.5 else Vector3.BACK.lerp(end_tip,swing*2-1)
	_set_world_rotation(skel,f.wrist,Quaternion(blade_axis,tip.normalized()),blend)

func _bow_pose(f: Figure, phase: String, pitch: float, progress: float) -> void:
	var engaged := phase in ["Windup","Hold","Active","Recovery"]
	var draw := progress if phase=="Windup" else (1.0 if phase=="Hold" else 0.0)
	var nock := Vector3(0,0,.14+.34*draw)
	if draw!=f.draw or (f.arrow.visible and f.arrow.position!=nock):
		for thread: MeshInstance3D in [f.upper_string,f.lower_string]:
			var end := Vector3(0,.48 if thread==f.upper_string else -.48,.14)
			var span := end-nock
			thread.transform = Transform3D(Basis(Quaternion(Vector3.UP,span.normalized())).scaled_local(Vector3(1,span.length(),1)),(nock+end)*.5)
		f.arrow.position = nock
		f.draw = draw
	var skel := f.skeleton
	if not engaged:
		if phase=="Ready":
			var shoulder := skel.get_bone_global_pose(f.left).origin
			var swing := clampf(skel.get_bone_global_pose(f.left_wrist).origin.z-shoulder.z,-.35,.35)
			_reach(skel,f.left,f.left_forearm,f.left_wrist,shoulder+Vector3(.19,-.39,.07+.32*swing),Vector3(.65,-.4,-.4),1.0)
			_set_world_rotation(skel,f.left_wrist,(Basis(Vector3.BACK,-.42)*Basis(Vector3.RIGHT,.70)*Basis(Vector3.UP,PI)).get_rotation_quaternion())
		return
	var raised := draw if phase=="Windup" else 1.0
	var aim := Basis(Vector3.RIGHT,-pitch+.29*(1.0-raised))
	var forward := aim.z
	var blend := 1.0-progress if phase=="Recovery" else 1.0
	var head_line := skel.get_bone_global_pose(f.neck).basis.get_rotation_quaternion()
	turn_in_saddle(f,-.45*blend)
	_set_world_rotation(skel,f.neck,head_line,.78)
	var shoulder := skel.get_bone_global_pose(f.left).origin
	var grip := shoulder+aim*Vector3(-.24,lerpf(-.14,.11,raised),.36+.08*raised)
	_reach(skel,f.left,f.left_forearm,f.left_wrist,grip,aim*Vector3(.6,-.45,0),blend)
	# Cant the limbs across the silhouette while the arrow still follows camera pitch.
	_set_world_rotation(skel,f.left_wrist,(aim*Basis(Vector3.BACK,.53)*Basis(Vector3.UP,PI)).get_rotation_quaternion(),blend)
	var draw_length := .54 if phase in ["Active","Recovery"] else nock.z
	var string_hand := skel.get_bone_global_pose(f.left_wrist).origin - forward*draw_length
	_reach(skel,f.right,f.forearm,f.wrist,string_hand,aim*Vector3(-1,.08,-.35),blend)

## Place a hand with a two-link arm; the pole selects the bend side of the elbow.
func _reach(skel: Skeleton3D, upper: int, lower: int, hand: int, target: Vector3, pole: Vector3, blend: float) -> void:
	var start := skel.get_bone_global_pose(upper).origin
	var axis := (target-start).normalized()
	var a := skel.get_bone_rest(lower).origin.length()
	var b := skel.get_bone_rest(hand).origin.length()
	var reach := clampf(target.distance_to(start),absf(a-b)+.001,a+b-.001)
	var along := (a*a-b*b+reach*reach)/(2.0*reach)
	var elbow := axis*along + pole.slide(axis).normalized()*sqrt(maxf(0,a*a-along*along))
	_aim_bone(skel,upper,lower,elbow,blend)
	_aim_bone(skel,lower,hand,axis*reach-elbow,blend)

func _aim_bone(skel: Skeleton3D, id: int, child: int, direction: Vector3, blend := 1.0) -> void:
	var rotation := skel.get_bone_global_pose(id).basis.get_rotation_quaternion()
	var axis := skel.get_bone_rest(child).origin.normalized()
	var aim := Quaternion(rotation*axis,direction.normalized())*rotation
	_set_world_rotation(skel,id,aim,blend)

func _set_world_rotation(skel: Skeleton3D, id: int, aim: Quaternion, blend := 1.0) -> void:
	var parent := skel.get_bone_global_pose(skel.get_bone_parent(id)).basis.get_rotation_quaternion()
	skel.set_bone_pose_rotation(id,skel.get_bone_pose_rotation(id).slerp(parent.inverse()*aim,blend))

static func saddle_offset(f: Figure) -> Vector3:
	if f == null: return SADDLE_OFFSET
	var chest := f.skeleton.find_bone("Torso2")
	if chest < 0: return SADDLE_OFFSET
	var local := f.root.global_transform.affine_inverse() * f.skeleton.global_transform * f.skeleton.get_bone_global_pose(chest)
	# Saddle leather sits .22 m above the spine. Human hips sit .81 m above the root.
	return local.origin * HORSE_SCALE + Vector3.UP * (.22-.81)

func _bake(f: Figure) -> Mesh:
	var bake := SurfaceTool.new()
	bake.begin(Mesh.PRIMITIVE_TRIANGLES)
	f.skeleton.force_update_all_bone_transforms()
	var root_xform := f.root.get_parent_node_3d().global_transform.affine_inverse()
	for part: MeshInstance3D in f.root.find_children("*", "MeshInstance3D", true, false):
		if part.mesh == null or not part.is_visible_in_tree():
			continue
		var mesh_xform := root_xform * part.global_transform
		var ancestor := part.get_parent() as Node3D
		while ancestor!=null and ancestor!=f.root and not ancestor is BoneAttachment3D:
			ancestor = ancestor.get_parent_node_3d()
		if ancestor is BoneAttachment3D:
			# During synchronous baking BoneAttachment's render notification may be pending.
			var joint_pose := f.skeleton.get_bone_global_pose(ancestor.get_bone_idx())
			mesh_xform = root_xform * f.skeleton.global_transform * joint_pose * ancestor.global_transform.affine_inverse() * part.global_transform
		var binds: Array[Transform3D] = []
		if part.skin:
			for b in part.skin.get_bind_count():
				var joint := f.skeleton.find_bone(part.skin.get_bind_name(b))
				if joint < 0:
					joint = part.skin.get_bind_bone(b)
				binds.append(f.skeleton.get_bone_global_pose(joint) * part.skin.get_bind_pose(b))
		for surface in part.mesh.get_surface_count():
			var a := part.mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var posed := PackedVector3Array()
			var directions := PackedVector3Array()
			posed.resize(verts.size())
			directions.resize(verts.size())
			var weights: Variant = a[Mesh.ARRAY_WEIGHTS]
			var bones: Variant = a[Mesh.ARRAY_BONES]
			for i in verts.size():
				var v := verts[i]
				var n := normals[i]
				if weights != null and not binds.is_empty():
					v = Vector3.ZERO
					n = Vector3.ZERO
					var stride: int = weights.size()/verts.size()
					for j in stride:
						var w: float = weights[i*stride+j]
						if w > 0:
							var bind := binds[int(bones[i*stride+j])]
							v += (bind * verts[i])*w
							n += (bind.basis * normals[i])*w
				posed[i] = mesh_xform * v
				directions[i] = (mesh_xform.basis*n).normalized()
			var tint := Color.WHITE
			var mat := part.mesh.surface_get_material(surface) as StandardMaterial3D
			if mat:
				tint = mat.albedo_color.srgb_to_linear()
			var colors: Variant = a[Mesh.ARRAY_COLOR]
			var indices: Variant = a[Mesh.ARRAY_INDEX]
			var total: int = indices.size() if indices != null else verts.size()
			for j in total:
				var i: int = indices[j] if indices != null else j
				var col: Color = colors[i].srgb_to_linear()*tint if colors != null else tint
				# Vertex alpha masks the cloth for the per-instance faction color.
				col.a = 1.0 if part == f.tunic or part == f.cape else 0.0
				bake.set_color(col)
				bake.set_normal(directions[i])
				bake.add_vertex(posed[i])
	bake.index()
	return bake.commit()
