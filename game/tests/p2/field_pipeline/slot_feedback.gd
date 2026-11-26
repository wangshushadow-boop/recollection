extends "res://tests/p2/field_pipeline/run.gd"

class SlotAdapter extends EngineAdapter:
	var block_slots := false
	var blocked_batches := 0

	func query_path_batch(requests: Array, revision: Variant, id: String) -> Dictionary:
		if block_slots and requests.size()==2:
			blocked_batches+=1
			return R.ok([{"reachable":false},{"reachable":false}])
		return super.query_path_batch(requests,revision,id)

class ObservingBrains extends "res://mission/runtime/field_brains.gd":
	var opening: Dictionary

	func decide_compact(tick: int, nav: int, columns: Dictionary, combat: RefCounted, player: Variant) -> Dictionary:
		opening=columns.groups[1]
		return super.decide_compact(tick,nav,columns,combat,player)

var observer: ObservingBrains

func factory(world,engine,form,teams):
	observer=ObservingBrains.new(world,engine,form,teams)
	return observer

func move_order(sequence: int, target: Array) -> Dictionary:
	var order:=checked_order("player",sequence,"move",{},hud().formations[0].control_revision)
	order.order.target_position=target
	return mission.gateway("field.order",order,token)

func test_feedback() -> void:
	if not await open(battle(["infantry"],[2],2)): return
	if not ok(mission.step_fixed(1,[]),"publish formations and initial slot layout"): return
	if not ok(move_order(1,[3000,0,0]),"admit move to reachable center"): return
	adapter.block_slots=true
	if not ok(mission.step_fixed(2,[]),"failed slot projection still commits"): return
	check(adapter.blocked_batches>0,"slot projection was blocked")
	check(observer.opening.terrain_feedback.get("reason")=="unreachable" and observer.opening.active==null,
		"compact AI sees failed terrain and completed active order in the same tick")
	adapter.block_slots=false
	if not ok(move_order(2,[4000,0,0]),"admit a new move after terrain recovers"): return
	if not ok(mission.step_fixed(3,[]),"successful slot projection commits"): return
	check(observer.opening.terrain_feedback.is_empty() and observer.opening.active!=null and observer.opening.active.order_id=="player-2",
		"compact AI sees cleared terrain and current active order on recovery")

func run() -> void:
	var compiler:=Compiler.new()
	var compiled:=compiler.compile(compiler.scan_packages([Compiler.BASE_PACKAGE,"res://content/base/field"]),{})
	if ok(compiled,"compile river field definitions"):
		registry=compiled.value.registry
		adapter=SlotAdapter.new(root,true)
		await test_feedback()
	if mission!=null:mission.dispose()
	print("SLOT_FEEDBACK checks=",checks," failures=",failed)
	quit(int(failed>0))
