extends SceneTree
## Follow the all-formations general charge from the opening river deployment to live contact.
const Boot = preload("res://bootstrap/composition_root.gd")
const Config = preload("res://bootstrap/boot_config.gd")

func _initialize() -> void:
	run.call_deferred()

func formation_center(mission: RefCounted, id: int) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for h in mission._frame.groups[id].members:
		if mission._frame.pose.has(h.index):
			total += Vector3(mission._frame.pose[h.index].position)
			count += 1
	return total / maxi(1,count)

func exercise(app: RefCounted) -> bool:
	if not app.boot(Config.resolve([],DisplayServer.get_name(),{}).value).ok: return false
	if not app.session().start_session("custom",{}).ok: return false
	var opened: Dictionary = app.start_field(500,500,241124)
	if not opened.ok: return false
	var initial: Dictionary
	for wait in 60:
		await physics_frame
		initial = app.field_step()
		if initial.ok: break
	if not initial.ok: return false
	var hud: Dictionary = app.field_view("hud").value
	var ids := []
	var revisions := {}
	for g: Dictionary in hud.formations:
		if g.controllable:
			ids.append(g.id)
			revisions[str(g.id)] = g.control_revision
	var mission: RefCounted=app._field_mission.get_ref()
	var tick: int=mission._tick
	var order := {"mission_id":opened.value,"order_id":"opening-charge","issuer_id":"player","formation_ids":ids,
		"order_type":"free_attack","target_position":null,"target_formation_id":null,
		"parameters":{},"issued_tick":tick+1,"client_sequence":1}
	if not app.field_command("field.order",{"order":order,"revisions":revisions},tick,"opening-charge").ok: return false
	var start := formation_center(mission,1)
	var moved := 0.0
	var first_hit := [0,0]
	var admitted := false
	var labels := {}
	for step in 2400:
		var advanced: Dictionary = app.field_step()
		if not advanced.ok:
			printerr(advanced)
			return false
		tick=mission._tick
		for hit: Dictionary in mission._frame.combat_report.hits:
			if hit.damage<=0: continue
			var side: int = mission._frame.groups[mission._frame.membership[hit.attacker.index]].team_key
			if first_hit[side]==0: first_hit[side]=tick
		if step==2:
			admitted=ids.size()==4 and ids.all(func(id):
				var active: Variant=mission._frame.groups[id].active
				return active!=null and active.order_type=="free_attack" and active.issuer_id=="player")
		if step==180 or step==600:
			moved=formation_center(mission,1).x-start.x
			labels[str(step)]={"infantry_forward_m":moved,"center":str(formation_center(mission,1)),"known":mission._brains.visible_formations(0)}
		if step>=600 and ((first_hit[0]>0 and first_hit[1]>0) or moved<3.0): break
		if step%40==0: await physics_frame
	print("OPENING_CHARGE ",JSON.stringify({"received_by_four":admitted,"start":str(start),"samples":labels,"first_hits":first_hit,"last_tick":tick}))
	return admitted and moved>8.0 and first_hit[0]>0 and first_hit[1]>0

func run() -> void:
	var app: RefCounted = Boot.new(root)
	var passed := await exercise(app)
	app.shutdown()
	quit(0 if passed else 1)
