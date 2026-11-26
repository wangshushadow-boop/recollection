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
var role: String
var poses: Array[Mesh] = []
var vertex_paint := StandardMaterial3D.new()

class Figure:
	var root: Node3D
	var player: AnimationPlayer
	var skeleton: Skeleton3D
	var spine: int
	var right: int
	var forearm: int
	var left_leg: int
	var right_leg: int
	var tunic: MeshInstance3D
	var ranged_weapon: Node3D
	var melee_weapon: MeshInstance3D
	var hand: BoneAttachment3D
	var clip := ""

func load_model(kind: String, host: Node3D) -> bool:
	role = kind
	vertex_paint.vertex_color_use_as_albedo = true
	vertex_paint.vertex_color_is_srgb = true
	vertex_paint.roughness = .9
	var path := "res://content/base/field/models/%s.glb" % FILES[kind]
	if not ResourceLoader.exists(path):
		return false
	scene = load(path) as PackedScene
	if scene == null:
		return false
	if role in ["mounted_archer","archer"]:
		hand_prop = load(SHORT_BOW if role=="mounted_archer" else SIDEARM) as PackedScene
		if hand_prop == null: return false
	var figure := instantiate(host)
	if figure.skeleton == null or figure.player == null or (hand_prop != null and (figure.ranged_weapon == null or figure.melee_weapon == null)):
		figure.root.free()
		return false
	# The mounted archer and cavalry use the same general.glb melee mesh and pose bank.
	var variants := 2 if role in ["cavalry","archer","mounted_archer"] else 1
	for variant in variants:
		for frame in POSES_PER_SET:
			var phase := "Guard" if frame == 7 else ("Active" if frame >= 3 else "Ready")
			var direction: String = DIRECTIONS[clampi(frame-3,0,3)]
			pose(figure, float(frame) * 13.0, 0 if frame == 0 else 2.8, phase, direction,
				frame*13-1, role in ["cavalry","mounted_archer"] and variant==0, role=="mounted_archer" or (role=="archer" and variant==0))
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
	f.right = f.skeleton.find_bone("RightArm")
	f.forearm = f.skeleton.find_bone("RightForeArm")
	f.left_leg = f.skeleton.find_bone("LeftUpLeg")
	f.right_leg = f.skeleton.find_bone("RightUpLeg")
	f.tunic = f.root.find_child("garment-tunic", true, false) as MeshInstance3D
	if role in ["archer","mounted_archer"] and f.skeleton.find_bone("RightHand")>=0:
		var original := f.root.find_child("attach-righthand-mesh",true,false) as MeshInstance3D
		f.hand = BoneAttachment3D.new()
		f.skeleton.add_child(f.hand)
		f.hand.bone_name = "RightHand"
		if role == "mounted_archer":
			f.melee_weapon = original
			f.ranged_weapon = hand_prop.instantiate()
			f.hand.add_child(f.ranged_weapon)
		else:
			f.ranged_weapon = original
			f.melee_weapon = hand_prop.instantiate() as MeshInstance3D
			f.hand.add_child(f.melee_weapon)
	return f

func pose(f: Figure, time: float, speed: float, phase: String, direction: String, since: int,
		mounted: bool, ranged: bool) -> void:
	var clip := "Idle"
	if speed > .12 and not mounted:
		clip = ("Gallop" if role == "mount" else "Run") if speed > 3.3 else "Walk"
	if f.clip != clip:
		f.player.play(clip)
		f.clip = clip
	var duration := f.player.get_animation(clip).length
	f.player.seek(fposmod(time / 60.0, maxf(duration, .01)), true)
	if f.right < 0:
		return
	if f.ranged_weapon:
		f.ranged_weapon.visible = ranged
		f.melee_weapon.visible = not ranged
	if mounted:
		for joint in [f.left_leg, f.right_leg]:
			var sign_x := -1 if joint == f.left_leg else 1
			f.skeleton.set_bone_pose_rotation(joint, f.skeleton.get_bone_rest(joint).basis.get_rotation_quaternion()
				* Quaternion(Vector3.RIGHT, -.67) * Quaternion(Vector3.BACK, sign_x*.24))
	if phase not in ["Windup","Hold","Guard","Active","Recovery","Stagger"]:
		return
	var elapsed := maxf(0.0, time-since)
	var arm := Quaternion.IDENTITY
	var bend := 0.0
	if phase == "Guard":
		arm = Quaternion(Vector3.RIGHT, -.65) * Quaternion(Vector3.BACK, .75)
		bend = -.55
	elif phase == "Stagger":
		arm = Quaternion(Vector3.BACK, -.38)
	elif role=="mounted_archer" and ranged:
		# Aim along character forward while preserving the mounted or walking lower body.
		_aim_bone(f.skeleton,"RightArm","RightForeArm",Vector3(-.2,-.15,1))
		_aim_bone(f.skeleton,"RightForeArm","RightHand",Vector3(.4,.22,1))
		_aim_bone(f.skeleton,"LeftArm","LeftForeArm",Vector3(.65,-.1,-.22))
		_aim_bone(f.skeleton,"LeftForeArm","LeftHand",Vector3(-.7,.5,.45))
		var wrist := f.hand.get_bone_idx()
		var forearm_rotation := f.skeleton.get_bone_global_pose(f.forearm).basis.get_rotation_quaternion()
		f.skeleton.set_bone_pose_rotation(wrist,forearm_rotation.inverse()*Quaternion(Vector3.UP,PI))
		return
	else:
		var sweep := -.78
		match phase:
			"Windup": sweep *= clampf(elapsed / 3.0, 0, 1)
			"Active": sweep = lerpf(-.78, 1.15, clampf((elapsed+.5)/2.0, 0, 1))
			"Recovery": sweep = 1.15 * (1.0-clampf(elapsed/3.0,0,1))
		match direction:
			"left": arm = Quaternion(Vector3.UP, sweep) * Quaternion(Vector3.BACK, -.66)
			"right": arm = Quaternion(Vector3.UP, -sweep) * Quaternion(Vector3.BACK, -.66)
			"up": arm = Quaternion(Vector3.RIGHT, sweep) * Quaternion(Vector3.BACK, -1.1)
			"thrust":
				arm = Quaternion(Vector3.UP, -1.20) * Quaternion(Vector3.BACK, -.45)
				bend = -.7 + sweep*.55
	f.skeleton.set_bone_pose_rotation(f.right, f.skeleton.get_bone_pose_rotation(f.right)*arm)
	f.skeleton.set_bone_pose_rotation(f.forearm, f.skeleton.get_bone_pose_rotation(f.forearm)*Quaternion(Vector3.UP,bend))

## Apply mounted aim after sampling the clip and positioning hands. The pelvis
## and legs stay with the saddle while the bow or melee weapon follows the torso.
static func turn_in_saddle(f: Figure, turn: float) -> void:
	if f.spine<0 or is_zero_approx(turn): return
	var parent := f.skeleton.get_bone_global_pose(f.skeleton.get_bone_parent(f.spine)).basis
	var up := (f.skeleton.global_basis*parent).inverse()*Vector3.UP
	f.skeleton.set_bone_pose_rotation(f.spine,Quaternion(up.normalized(),turn)*f.skeleton.get_bone_pose_rotation(f.spine))

func _aim_bone(skel: Skeleton3D, bone: String, child: String, direction: Vector3) -> void:
	var id := skel.find_bone(bone)
	var rotation := skel.get_bone_global_pose(id).basis.get_rotation_quaternion()
	var axis := skel.get_bone_rest(skel.find_bone(child)).origin.normalized()
	var aim := Quaternion(rotation*axis,direction.normalized())*rotation
	var parent := skel.get_bone_global_pose(skel.get_bone_parent(id)).basis.get_rotation_quaternion()
	skel.set_bone_pose_rotation(id,parent.inverse()*aim)

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
		if f.hand != null and f.hand.is_ancestor_of(part):
			# During synchronous baking BoneAttachment's render notification may be pending.
			var joint_pose := f.skeleton.get_bone_global_pose(f.hand.get_bone_idx())
			mesh_xform = root_xform * f.skeleton.global_transform * joint_pose * f.hand.global_transform.affine_inverse() * part.global_transform
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
				col.a = 1.0 if part == f.tunic else 0.0
				bake.set_color(col)
				bake.set_normal(directions[i])
				bake.add_vertex(posed[i])
	bake.index()
	return bake.commit()
