extends SceneTree
const Composition = preload("res://bootstrap/composition_root.gd")
const Config = preload("res://bootstrap/boot_config.gd")
var errors := 0
var app: RefCounted
func check(ok: bool, label: String) -> bool:
	if not ok:
		errors += 1
		printerr("FAIL ",label)
	return ok

func _initialize() -> void:
	run.call_deferred()

func leaders(manual:bool)->void:
	var opened:Dictionary=app.start_field(500,500)
	if not check(opened.ok,"500-person general practice opened"):return
	var mission:RefCounted=app._field_mission.get_ref()
	var stolen:Dictionary=mission.apply_deployment([{"source_slot":1,"components":{"spawn_position_mm":mission._zones[0].points_mm[0]}}])
	check(not stolen.ok and stolen.error.field=="deployment.opening_slot","manual deployment cannot occupy the general's reserved point")
	if manual:
		for attempts in 60:
			await physics_frame
			var placement:Dictionary=app.field_command("field.deploy",{"placements":[{"formation_id":2,"zone_id":"west","layout":"line"}]},0)
			if placement.ok:break
			if not check(attempts<59 and placement.error.code in ["Unavailable","StaleVersion"],"explicit archers deployed first"):return
	var first:Dictionary
	for attempt in 60:
		await physics_frame
		first=app.field_step()
		if first.ok:break
	if not check(first.ok,"initial formations spawned"):return
	var people:Array=first.value.entities.filter(func(r):return r.source_slot!=null)
	var spots:={}
	for r in people:spots[r.components.spawn_position_mm]=true
	check(people.size()==500 and first.value.entities.size()==600 and spots.size()==500,"500 independent human positions and 100 horses")
	var heroes:Array=people.filter(func(r):return r.components.hero_id!=null)
	if not check(heroes.size()==2 and heroes[0].components.hero_id!=heroes[1].components.hero_id,"two unique hero source slots"):return
	var controls:Dictionary=app.field_view("input").value
	var west_start:=Vector3.ZERO
	for t in range(1,182):
		if manual and t>1:
			var idle:={"actor_handle":controls.actor_handle,"desired_direction":[0,0,0],"speed_fraction":0.0,"stance":"walk"}
			var batch:={"mission_id":opened.value,"source_tick":t,"control_revision":controls.control_revision,"inputs":[idle]}
			if not check(app.field_command("field.input",{"batch":batch},t-1).ok,"normal idle player input"):return
		if t!=1 and not check(app.field_step().ok,"idle river tick"):return
		if t not in [1,61,181]:continue
		var actors:Array=app.field_view("visual").value.actors
		var generals:Array=actors.filter(func(a):return a.commander)
		if not check(generals.size()==2,"two visible generals"):return
		var west:Dictionary=generals.filter(func(a):return a.team==0)[0]
		var east:Dictionary=generals.filter(func(a):return a.team==1)[0]
		for general in [west,east]:
			var direction:=1 if general.team==0 else -1
			var front:float=-INF
			for actor in actors:
				if actor.team==general.team and actor.role!="mount" and not actor.commander:
					front=maxf(front,direction*actor.position.x)
			var gap:float=direction*general.position.x-front
			check(general.role=="infantry" and general.mount_handle==null and general.weapon_kind=="melee" and general.shield==32,"equipped foot general")
			check(gap>0.1,"general leads ranks "+str([t,general.team,gap,general.position]))
			if t==1:check(absf(general.position.z)<.001 and general.heading.x*direction>.98,"starts at frontline center facing enemy")
			print("FIELD_GENERAL tick=",t," team=",general.team," gap=",gap," position=",general.position," heading=",general.heading)
		if t==1:
			west_start=west.position
			check(controls.actor_handle==west.handle,"only west general possessed")
			var batch:={"mission_id":opened.value,"source_tick":2,"control_revision":controls.control_revision,"inputs":[{"actor_handle":east.handle,"yaw":0,"pitch":0}]}
			check(not app.field_command("field.input",{"batch":batch},1).ok,"enemy general cannot be possessed by input")
		else:check(west.position.distance_to(west_start)<.005 and west.heading.x>.98,"idle player never marches to an infantry slot")
	var hud:Dictionary=app.field_view("hud").value
	check(app.field_command("field.withdraw",{},hud.revision).ok and app.field_step().ok,"end actual field")
	check(app.field_view("hud").value.result.slot_outcomes.size()==500,"all 500 returned to result")
	check(app.leave_field().ok,"dispose field")

func run() -> void:
	var config := Config.resolve([],DisplayServer.get_name(),{})
	if not check(config.ok,"default configuration"): quit(1); return
	app=Composition.new(root)
	var boot: Dictionary=app.boot(config.value)
	if not check(boot.ok,"normal boot "+str(boot)): quit(1); return
	var custom: bool = config.value.profile=="client" or "--practice" in OS.get_cmdline_user_args()
	if custom and config.value.profile=="headless":
		if not check(app.session().start_session("custom",{}).ok,"single player practice session"): quit(1);return
	if "--leaders" in OS.get_cmdline_user_args():
		await leaders("--manual" in OS.get_cmdline_user_args())
		check(app.shutdown().ok,"release all general test modules")
		print("FIELD_GENERALS errors=",errors)
		quit(1 if errors else 0)
		return
	var opened: Dictionary=app.start_field(20,40)
	if not check(opened.ok,"normal field start "+str(opened)): quit(1); return
	var attempts := []
	var trace := func(_ctx,tick_batch):
		if tick_batch.source_tick==2:
			attempts.append(tick_batch.source_tick)
			if attempts.size()==1: return preload("res://contracts/result.gd").fail("Unavailable","sweep_contact")
		return {"ok":true,"value":null}
	check(app._field_mission.get_ref().register_system("snapshot",{"id":"qa.contact_retry","run":trace}).ok,"install one transient contact failure")
	var hud: Dictionary=app.field_view("hud")
	check(hud.ok and hud.value.phase=="deployment" and not hud.value.formations.is_empty(),"initial deployment")
	var opening := {}
	for group: Dictionary in hud.value.formations: opening[group.troop_role]=group.planned_count
	check(opening=={"infantry":5,"archer":3,"cavalry":1,"mounted_archer":1},"own first wave preview excludes reserves and the opposing side")
	if not check(not app.session().finish_mission({"outcome":"victory"}).ok,"premature end rejected"): quit(1);return
	var first: Dictionary
	for i in 50:
		await physics_frame
		first=app.field_step()
		if first.ok:break
		if first.error.code not in ["Unavailable","StaleVersion"]:break
	if not check(first.ok,"first field step "+str(first)):quit(1);return
	var humans: Array=first.value.entities.filter(func(e):return e.source_slot!=null)
	check(humans.size()==20 and first.value.tick==1,"20 real humans deployed")
	var input: Dictionary=app.field_view("input")
	if not check(input.ok and input.value.actor_handle is Dictionary,"real player possession"):quit(1);return
	var captain: Dictionary = app.field_view("hud").value.player
	check(captain.hp==captain.max_hp and captain.max_hp==100,"commander real health capacity")
	if custom:
		var captain_rows: Array = humans.filter(func(row):return row.handle==input.value.actor_handle and row.components.hero_id!=null)
		check(captain_rows.size()==1 and captain.commander and captain.level==1 and not captain.has("troop_tier"),"possessed commander is a starting training hero in both battle rules and combat")
	else:
		check(captain.troop_tier==1 and not captain.has("level"),"anonymous troop has tier and no hero level")
	check(not captain.stamina_enabled,"training stamina is unrestricted")
	var kit := [{"slot":"melee","id":"field:item/spear","name":"长枪"}]
	if custom:
		kit.append({"slot":"ranged","id":"field:item/bow","name":"短弓"})
		kit.append({"slot":"shield","id":"field:item/round_shield","name":"圆盾"})
		check(captain.shield==32 and captain.ammo>0,"equipped shield and bow use mission resources")
	check(captain.equipped_items==kit,"possessed unit's actual river loadout")
	captain.equipped_items.clear()
	check(app.field_view("hud").value.player.equipped_items.size()==kit.size(),"HUD inventory snapshot is isolated")
	var handle: Dictionary=input.value.actor_handle
	var batch := {"mission_id":opened.value,"source_tick":2,"control_revision":input.value.control_revision,
		"inputs":[{"actor_handle":handle,"desired_direction":[1000000,0,0],"speed_fraction":1.0,"stance":"walk"}]}
	var accepted: Dictionary=app.field_command("field.input",{"batch":batch},input.value.revision,"smoke-input")
	if not check(accepted.ok,"normal player command "+str(accepted)):quit(1);return
	var client_loop := preload("res://bootstrap/main.gd").new()
	client_loop._root = app
	client_loop._running = true
	client_loop._physics_process(1.0/60)
	check(client_loop._running and app.field_view("hud").value.tick==1,"transient contact leaves the prior tick committed")
	client_loop._physics_process(1.0/60)
	check(attempts==[2,2] and client_loop._last_tick==2,"client retries the same battle step and commits it exactly once")
	client_loop.free()
	hud=app.field_view("hud")
	var left: Dictionary=app.field_command("field.withdraw",{},hud.value.revision)
	if not check(left.ok,"authorized withdrawal "+str(left)):quit(1);return
	var terminal: Dictionary=app.field_step()
	if not check(terminal.ok,"finish authoritative result "+str(terminal)):quit(1);return
	hud=app.field_view("hud")
	check(hud.ok and hud.value.phase=="ended" and hud.value.result.slot_outcomes.size()==40,"complete results in same view")
	var session: Dictionary=app.session().query()
	check(session.value.state=="Results","final session phase")
	if not custom: check(app.report().last_match.winner_team_keys==[1],"headless results sink")
	check(app.leave_field().ok and not app.has_field(),"dispose grants")
	check(app.shutdown().ok,"release all modules")
	print("FIELD_BOOT errors=",errors," people=",humans.size()," slots=40")
	quit(1 if errors else 0)
