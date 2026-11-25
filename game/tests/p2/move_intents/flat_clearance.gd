extends SceneTree
## Compare a crowded river lane with a single driver's exact physical queries.

const Field = preload("res://mission/movement/ports/field_movement.gd")
const SCOPE := "river-crowd-clearance"
const DT := 1.0/60.0
const CROWD := 64
var engine: CountedAdapter
var crowded: Field
var single: Field
var next_tick := 1
var failures := 0
var checks := 0
var ai := RefCounted.new()

class CountedAdapter extends "res://infrastructure/engine/adapter.gd":
	var count_requests := false
	var exact := 0
	func query_sweep_batch(rows: Array, stamp: Dictionary) -> Dictionary:
		if count_requests:
			for row in rows:
				if row.radius_mm == 280 or row.radius_mm == 470:
					exact += 1
		return super.query_sweep_batch(rows,stamp)

func check(good: bool, label: String) -> void:
	checks += 1
	if not good:
		failures += 1
		printerr("FAIL ",label)

func handle(i: int) -> Dictionary:
	return {"index":i,"generation":1}

func _initialize() -> void:
	run.call_deferred()

func authorize(scope: String, _actor: Dictionary, credential: Variant, _tick: int) -> bool:
	return scope == SCOPE and is_same(credential,ai)

func ready_river() -> bool:
	var opened := engine.open_scope(SCOPE)
	var scene := {"id":"base:scene/river_crowd_test","simulation_scene":"res://content/base/field/river_plain.tscn"}
	if not opened.ok or not engine.load_scene(scene,opened.value).ok: return false
	for frame in 120:
		await physics_frame
		var nav := engine.sync_navigation(SCOPE)
		if nav.ok and nav.value.status == "applied":
			var paths := engine.query_path_batch([{"from":[-6000,0,4000],"to":[6000,0,4000]}],
				nav.value.applied_revision,SCOPE)
			if paths.ok and paths.value[0].reachable: return true
	return false

func start_lane(field: Field, count: int) -> bool:
	for i in count:
		var position := Vector3(-6,0,4) if i == 0 else Vector3(-46 + i % 8 * 1.8,0,26 + floori(i/8.0) * 1.8)
		if not field.spawn(handle(i),position,"mounted" if i % 5 == 4 else "foot",Vector3.RIGHT).ok:
			return false
	var stage := field.begin_step(0)
	if not stage.ok: return false
	for i in count:
		var move := {"actor_handle":handle(i),"desired_direction":[1000000,0,0],"speed_fraction":1.0,"stance":null}
		if not field.apply_move_intent(stage.value,move,ai).ok: return false
	return field.stage_step(0,DT,stage.value).ok and field.commit_step(stage.value).ok

func run_steps(count: int) -> void:
	for i in count:
		engine.count_requests = true
		var many := crowded.step(next_tick,DT)
		engine.count_requests = false
		var one := single.step(next_tick,DT)
		check(many.ok and one.ok and crowded.view(handle(0)) == single.view(handle(0)),
			"crowd driver matches exact solo pose at tick %d" % next_tick)
		next_tick += 1

func lead_x() -> float:
	return crowded.view(handle(0)).value.position.x

func one_sided_wall(ground: Node3D) -> void:
	# The crowd cell center is at x=-4, behind the face; the driver starts at x=-6, in front.
	const FIN_X := -5.2
	var body := StaticBody3D.new()
	body.set_meta("entity_handle","front_only")
	body.position = Vector3(FIN_X,0,4)
	var faces := PackedVector3Array([Vector3(0,-2,-3),Vector3(0,3,-3),Vector3(0,1,3)])
	var mesh := ConcavePolygonShape3D.new()
	mesh.set_faces(faces)
	var shape := CollisionShape3D.new()
	shape.shape = mesh
	body.add_child(shape)
	ground.get_parent().add_child(body)
	var contact := false
	for orientation in 2:
		await physics_frame
		await physics_frame
		var reply: Dictionary = engine.query_sweep_batch([{"from":[-5420,320,4000],
			"to":[-5380,320,4000],"radius_mm":280,"mask":1}],{"scope_id":SCOPE,"tick":0})
		contact = reply.ok and reply.value.any(func(h): return h.entity_handle == "front_only")
		if contact: break
		faces.reverse()
		mesh.set_faces(faces)
	check(contact,"exact physical sphere identifies the front side of the fin")
	crowded = Field.new(engine,SCOPE,authorize)
	single = Field.new(engine,SCOPE,authorize)
	next_tick = 1
	check(start_lane(crowded,CROWD) and start_lane(single,1),"start lanes for one-sided wall")
	run_steps(25)
	check(lead_x() < FIN_X-0.28 and crowded.view(handle(0)).value.blocked == "scene",
		"crowd respects the fin faced away from its coarse cell center")
	body.free()

func run() -> void:
	engine = CountedAdapter.new(root,true)
	if not await ready_river():
		check(false,"open actual river plain")
		quit(1)
		return
	var ground := root.find_child("RiverPlain",true,false).get_node("Ground") as StaticBody3D
	crowded = Field.new(engine,SCOPE,authorize)
	single = Field.new(engine,SCOPE,authorize)
	check(start_lane(crowded,CROWD) and start_lane(single,1),"start crowded and exact lanes")
	run_steps(32)
	check(lead_x() > -4.5 and engine.exact == 0,"flat crowd advances without individual sweeps")
	print("FLAT_CLEARANCE crowd=",CROWD," steps=32 exact=",engine.exact," x=",lead_x())

	var door := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var solid := BoxShape3D.new()
	solid.size = Vector3(0.12,2,1)
	shape.shape = solid
	door.add_child(shape)
	door.position = Vector3(lead_x()+0.8,1,4)
	ground.get_parent().add_child(door)
	await physics_frame
	await physics_frame
	run_steps(24)
	var stopped := lead_x()
	check(engine.exact > 0 and crowded.view(handle(0)).value.blocked == "scene"
		and stopped < door.position.x-0.28,"closed thin door in floor cell blocks crowd driver")
	door.position.y += 3
	door.force_update_transform()
	await physics_frame
	await physics_frame
	run_steps(24)
	check(lead_x() > stopped+1,"opening door releases driver without a new intent")

	# A wall may belong to the same collision object as the walkable top.
	var wall := CollisionShape3D.new()
	wall.shape = solid
	ground.add_child(wall)
	wall.global_position = Vector3(lead_x()+0.8,1,4)
	wall.force_update_transform()
	await physics_frame
	await physics_frame
	run_steps(24)
	check(crowded.view(handle(0)).value.blocked == "scene" and lead_x() < wall.global_position.x-0.28,
		"wall on the ground body still blocks exact and crowded drivers")
	wall.free()
	door.free()
	await one_sided_wall(ground)
	ground.position.y += 0.08
	ground.force_update_transform()
	await physics_frame
	await physics_frame
	next_tick = 1
	crowded = Field.new(engine,SCOPE,authorize)
	single = Field.new(engine,SCOPE,authorize)
	check(start_lane(crowded,CROWD) and start_lane(single,1),"start with initially overlapping floor")
	run_steps(4)
	check(is_equal_approx(lead_x(),-6.0) and crowded.view(handle(0)).value.blocked == "scene",
		"raising the river floor by 80 mm keeps the initial overlap")
	engine.release_scope(SCOPE)
	print("FLAT_CLEARANCE_RESULT checks=",checks," failures=",failures)
	quit(int(failures>0))
