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

func run() -> void:
	var config := Config.resolve([],DisplayServer.get_name(),{})
	if not check(config.ok,"default configuration"): quit(1); return
	app=Composition.new(root)
	var boot: Dictionary=app.boot(config.value)
	if not check(boot.ok,"normal boot "+str(boot)): quit(1); return
	var custom: bool = config.value.profile=="client" or "--practice" in OS.get_cmdline_user_args()
	if custom and config.value.profile=="headless":
		if not check(app.session().start_session("custom",{}).ok,"single player practice session"): quit(1);return
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
	check(captain.equipped_items==[{"slot":"melee","id":"field:item/spear","name":"长枪"}],"possessed unit's actual river loadout")
	captain.equipped_items.clear()
	check(app.field_view("hud").value.player.equipped_items.size()==1,"HUD inventory snapshot is isolated")
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
