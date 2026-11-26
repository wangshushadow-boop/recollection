extends "res://tests/p2/field_pipeline/run.gd"

func visual() -> Array:
	var report: Dictionary = mission.gateway("field.view", {"projection":"visual"}, token)
	if not ok(report, "committed visual projection"):
		return []
	return report.value.actors

func projected_rows() -> void:
	site_positions = [[[-2000, 0, 0]], [[2000, 0, 0]]]
	var setup := battle(["cavalry"], [1], 1)
	setup.scene.simulation_scene = "res://tests/p2/ai/arena.tscn"
	if not await open(setup):
		return
	if not ok(mission.step_fixed(1, []), "open two mounted sides behind real wall"):
		return
	var rider: Dictionary = hud().player_handle
	var horse: Dictionary = hud().player.mount_handle
	var concealed := visual()
	check(concealed.size() == 2 and concealed.all(func(a):return a.handle in [rider,horse]), "wall occludes opposing rider and horse while both friends stay visible")
	if concealed.is_empty(): return
	var original := var_to_bytes(concealed)
	concealed[0].position = Vector3(2000,1000,500)
	concealed[0].role = "changed-by-caller"
	concealed[0].hp = -1024
	concealed.clear()
	var old := visual()
	check(var_to_bytes(old)==original, "editing projected row or actor array cannot affect same-tick requery")
	var blockers := get_nodes_in_group("ai_test_wall")
	if not check(blockers.size()==1,"authored wall exists"):return
	blockers[0].collision_layer=0
	await physics_frame
	await physics_frame
	var exposed := visual()
	check(exposed.size()==4 and mission.view().tick==1, "same-tick repeated query sees current LOS")
	if not ok(input(2,[{"actor_handle":rider,"yaw":1000000,"pitch":0},move(rider)]),"admit look and move"):return
	if not ok(mission.step_fixed(2,[]),"publish changed rider and horse heading"):return
	var next := visual()
	check(var_to_bytes(old)==original, "older returned pose stays stable across tick")
	var prior_rider: Dictionary = old.filter(func(a):return a.handle==rider)[0]
	var next_rider: Dictionary = next.filter(func(a):return a.handle==rider)[0]
	var next_horse: Dictionary = next.filter(func(a):return a.handle==horse)[0]
	check(prior_rider.heading!=next_rider.heading and next_rider.position==next_horse.position and next_rider.heading==next_horse.heading,"motion and look update both actor poses")
	blockers[0].collision_layer=4
	await physics_frame
	await physics_frame
	check(visual().size()==2, "restored wall hides enemy on requery")
	check(exposed.size()==4, "previously returned visible list remains detached")
	var original_horse: Dictionary = mission.resolve_entity(scope,horse)
	if not ok(original_horse,"read old horse components"):return
	if not ok(mission.remove_entity(scope,horse),"retire horse between fixed steps"):return
	check(visual().all(func(a):return a.handle!=horse), "retired generation disappears before next fixed step")
	var replacement: Dictionary = mission.allocate_entity(null, original_horse.value.components)
	if not ok(replacement,"allocate replacement horse before step"):return
	var newer: Dictionary = replacement.value
	check(newer.index==horse.index and newer.generation==horse.generation+1, "slot reused with advanced generation")
	var between := visual()
	check(between.size()==1 and between[0].handle==rider, "between ticks neither retired nor uncommitted horse appears")
	if not ok(mission.step_fixed(3,[]),"first authoritative step of replacement horse"):return
	var replaced := visual()
	check(replaced.size()==2 and replaced.any(func(a):return a.handle==newer and a.role=="mount" and a.rider_handle==rider), "replacement becomes visible with correct role and rider")
	check(replaced.all(func(a):return a.handle!=horse), "retired horse never reappears")

func run() -> void:
	var compiler := Compiler.new()
	var compiled := compiler.compile(compiler.scan_packages([Compiler.BASE_PACKAGE,"res://content/base/field"]),{})
	if not ok(compiled,"load field definitions"):
		quit(1)
		return
	registry=compiled.value.registry
	adapter=EngineAdapter.new(root,true)
	await projected_rows()
	if mission!=null:mission.dispose()
	print("POSE_PROJECTION checks=",checks," failures=",failed)
	quit(int(failed>0))
