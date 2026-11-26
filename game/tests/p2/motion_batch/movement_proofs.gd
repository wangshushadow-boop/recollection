extends SceneTree
const Field = preload("res://mission/movement/ports/field_movement.gd")
const R = preload("res://contracts/result.gd")
var checks := 0
var errors := 0

class Terrain:
	var top := 0.0
	var rise_mm := 0
	var width_mm := 18000
	var wall := false
	var probes := 0
	func sync_navigation(_scope: String) -> Dictionary:
		return R.ok({"status":"applied","applied_revision":1})
	func field_scenery_top(_scope: String,_mask: int) -> float:
		return top
	func query_path_batch(batch: Array, revision: int,_scope: String) -> Dictionary:
		var results := []
		for q in batch:
			var start: Array = q.from
			results.append({"nav_revision":revision,"reachable":true,"points":[start,[start[0]+width_mm,start[1]+rise_mm,start[2]]]})
		return R.ok(results)
	func query_sweep_batch(batch: Array,_options: Dictionary) -> Dictionary:
		probes += batch.size()
		return R.ok([{"query_index":0,"fraction_ppm":0}] if wall else [])

func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:
		errors+=1
		printerr("FAIL ",label)

func fixture(terrain: Terrain,height: float) -> Field:
	var m := Field.new(terrain,"terrain",func(_s,_h,_c,_t):return true)
	var stage: RefCounted = m.begin_step(1).value
	for i in 64:
		var h := {"index":i,"generation":1}
		m.spawn(h,Vector3(0,height,2*i),"foot",Vector3.RIGHT,stage)
		m.apply_move_intent(stage,{"actor_handle":h,"stance":null,"speed_fraction":1 if i==0 else 0,"desired_direction":[1,0,0]},null)
	var step := m.stage_step(1,0.1,stage)
	check(step.ok and m.commit_step(stage).ok,"install certified paths")
	return m

func clearance_cases() -> void:
	for geometry in [[0.0,0,18000],[0.0,0,2],[0.0,-600,1000],[1023.0,0,18000]]:
		var certified := Terrain.new()
		certified.rise_mm=geometry[1]
		certified.width_mm=geometry[2]
		var conservative := Terrain.new()
		conservative.top=3000.0
		conservative.rise_mm=certified.rise_mm
		conservative.width_mm=certified.width_mm
		var quick := fixture(certified,geometry[0])
		var reference := fixture(conservative,geometry[0])
		var actor := {"index":0,"generation":1}
		check(quick.view(actor).value==reference.view(actor).value,"maximum dt, limited extent and descent "+str(geometry))
		check(quick._draft._legs_clear_scenery==(geometry[0]==0.0 and geometry[1]==0),"bulk proof eligible "+str(geometry))
		if geometry[2]!=18000 or geometry[0]!=0.0: continue
		certified.wall=true
		certified.top=2.0
		conservative.wall=true
		conservative.top=3000.0
		var before: Vector3=quick.view(actor).value.position
		check(quick.step(2,0.1).ok and reference.step(2,0.1).ok and quick.view(actor).value==reference.view(actor).value,"wall added without nav revision")
		check(certified.probes>0 and quick.view(actor).value.position==before,"new wall blocks")
		certified.wall=false
		certified.top=0.0
		conservative.wall=false
		check(quick.step(3,0.1).ok and reference.step(3,0.1).ok and quick.view(actor).value==reference.view(actor).value and quick.view(actor).value.position.x>before.x,"wall removed")

func passage_witness() -> void:
	var mov := Field.new(Terrain.new(),"gate")
	var actor := {"index":0,"generation":1}
	var guard := {"index":1,"generation":1}
	mov.spawn(actor,Vector3(-0.1,0,0),"foot",Vector3.RIGHT)
	mov.spawn(guard,Vector3(-0.1,0,0.68))
	var b := mov._body(actor)
	b.drive=Field.Drive.new()
	b.drive.fraction=1.0
	b.scene_travel=INF
	b.passages=[{"bounds":AABB(Vector3(0,-1,0),Vector3(2,2,2)),"axis":0,"side":2,"lane":0.8,"two":false}]
	mov._prepare_grid(mov._bodies.values())
	var goal := Vector3.RIGHT*3
	mov._advance(b,goal,0.1,1.0,true)
	check(b.blocked=="yield" and b.last_drive_block!=null,"lateral gate approach hits a soldier")
	var first_checks := mov._checks
	mov._advance(b,goal,0.1,1.0,true)
	check(b.blocked=="yield" and mov._checks==first_checks,"identical sweep reuses contact")
	b.passages=[]
	mov._advance(b,goal,0.1,1.0,true)
	check(b.position.x>0 and b.last_drive_block==null,"straight sweep after passage change is clear")

func blocker_changes() -> void:
	var mov := Field.new(Terrain.new(),"crowd")
	var actor := {"index":0,"generation":1}
	var guard := {"index":1,"generation":1}
	mov.spawn(actor,Vector3.ZERO)
	mov.spawn(guard,Vector3(0.75,0,0))
	var b := mov._body(actor)
	b.drive=Field.Drive.new()
	b.drive.fraction=1
	b.scene_travel=INF
	mov._prepare_grid(mov._bodies.values())
	var goal := Vector3.RIGHT*3
	mov._advance(b,goal,0.1,1.0,true)
	check(b.blocked=="yield","initial contact")
	mov._body(guard).position.x=1.16
	mov._advance(b,goal,0.1,1.0,true)
	check(b.position.x>0.3 and b.last_drive_block==null,"blocker moves inside its existing cell")
	mov._advance(b,goal,0.1,1.0,true)
	check(b.blocked=="yield","contact at new point")
	mov.despawn(guard)
	mov.spawn({"index":1,"generation":2},Vector3(8,0,0))
	mov._prepare_grid(mov._bodies.values())
	mov._advance(b,goal,0.1,1.0,true)
	check(b.position.x>0.6 and b.last_drive_block==null,"retired blocker index reused elsewhere")

func dense_yield() -> void:
	var mov := Field.new(Terrain.new(),"dense")
	var actor := {"index":0,"generation":1}
	var guard := {"index":1,"generation":1}
	mov.spawn(actor,Vector3.ZERO)
	mov.spawn(guard,Vector3(0.75,0,0))
	var b := mov._body(actor)
	b.drive=Field.Drive.new()
	b.drive.fraction=1
	b.scene_travel=INF
	mov._prepare_grid(mov._bodies.values())
	var goal := Vector3.RIGHT*3
	mov._advance(b,goal,0.1,1.0,true)
	var checks_before := mov._checks
	for i in Field.NEIGHBOURS:
		mov.spawn({"index":i+2,"generation":1},Vector3(-0.3,10+i,0))
	mov._prepare_grid(mov._bodies.values())
	mov._advance(b,goal,0.1,1.0,true)
	check(b.blocked=="yield" and mov._checks==checks_before,"earlier crowded cell still requires a yield")
	mov._body(guard).position.x=1.16
	mov._advance(b,goal,0.1,1.0,true)
	check(b.last_drive_block==null and b.blocked=="yield" and mov._checks-checks_before==Field.NEIGHBOURS,"changed witness reverts to the original neighbour budget")

func _initialize() -> void:
	clearance_cases()
	passage_witness()
	blocker_changes()
	dense_yield()
	print("MOV_PROOFS checks=",checks," failures=",errors)
	quit(int(errors>0))
