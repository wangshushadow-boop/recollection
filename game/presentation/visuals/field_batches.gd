extends Node3D
## Uniform transform + pose batches. Capacity only grows when a batch fills.
class Batch:
	var geometry: MultiMesh
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var count := 0
	var capacity := 0

var groups := {}
var _active: Array[Batch] = []
var _previous: Array[Batch] = []
var material := ShaderMaterial.new()

func _init() -> void:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
	varying vec3 cloth_color;
	void vertex() { cloth_color = INSTANCE_CUSTOM.rgb; }
	void fragment() { ALBEDO = mix(COLOR.rgb, cloth_color, COLOR.a); ROUGHNESS = .88; }"""
	material.shader = shader

func add_group(key: String, mesh: Mesh, surface: Material = null) -> void:
	var geometry := MultiMesh.new()
	geometry.transform_format = MultiMesh.TRANSFORM_3D
	geometry.use_custom_data = true
	geometry.mesh = mesh
	var node := MultiMeshInstance3D.new()
	node.multimesh = geometry
	node.material_override = surface if surface != null else material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var batch := Batch.new()
	batch.geometry = geometry
	geometry.visible_instance_count = 0
	groups[key] = batch

func begin_frame() -> void:
	var reuse := _previous
	_previous = _active
	_active = reuse
	_active.clear()
	for batch in _previous:
		batch.count = 0

func push(key: String, transform3: Transform3D, color: Color) -> void:
	var batch: Batch = groups[key]
	var slot := batch.count
	if slot == 0:
		_active.append(batch)
	batch.count += 1

	if slot == batch.transforms.size():
		batch.transforms.append(transform3)
		batch.colors.append(color)
		if slot < batch.capacity:
			batch.geometry.set_instance_transform(slot, transform3)
			batch.geometry.set_instance_custom_data(slot, color.srgb_to_linear())
		return

	if batch.transforms[slot] != transform3:
		batch.transforms[slot] = transform3
		batch.geometry.set_instance_transform(slot, transform3)
	if batch.colors[slot] != color:
		batch.colors[slot] = color
		batch.geometry.set_instance_custom_data(slot, color.srgb_to_linear())

func flush() -> void:
	for batch in _previous:
		if batch.count == 0:
			batch.geometry.visible_instance_count = 0
	for batch in _active:
		if batch.count > batch.capacity:
			# Resizing invalidates instance data, including slots that did not change.
			batch.capacity = maxi(8, ceili(batch.count * 1.3))
			batch.geometry.instance_count = batch.capacity
			for i in batch.count:
				batch.geometry.set_instance_transform(i, batch.transforms[i])
				batch.geometry.set_instance_custom_data(i, batch.colors[i].srgb_to_linear())
		if batch.geometry.visible_instance_count != batch.count:
			batch.geometry.visible_instance_count = batch.count
