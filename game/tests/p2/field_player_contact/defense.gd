extends "res://tests/p2/individual/run.gd"
## Exercise stationary defence with real combat phases and remove the target during windup.
const FieldBrains = preload("res://mission/runtime/field_brains.gd")

func moving_orders() -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.enlist(A,{"team":0,"role":"infantry"})
	var home := Vector3(-4,0,8)
	var rules := ORDERS.duplicate()
	rules.merge({"engage_allowed":false,"fire_allowed":false},true)
	var job := job_for(ai,1,[unit(A,home,0,"infantry"),unit(B,home+Vector3.RIGHT,1,"infantry")])
	var local := context(home+Vector3.FORWARD*4)
	for pair in [["Regroup","move"],["Retreat","retreat"],["Hold","retreat"]]:
		local.holding_ground=FieldBrains._holds_position(pair[0],{"order_type":pair[1]})
		var plan: Dictionary=brain.decide(job,ai.sense(A).value,com.view(A).value,rules,local).value
		check(plan.target==B and plan.mode=="MoveToSlot" and actions(plan.intents).is_empty() and plan.intents[0].desired_direction==[0,0,-1000000],"move to assigned slot past visible enemy "+str(pair))

func sentry(role: String) -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	var kit := {"team":0,"role":role}
	if role=="archer": kit.merge({"ranged":"bow","ammo":4})
	com.enlist(A,kit)
	com.enlist(B,{"team":1,"role":"infantry"})
	var home := Vector3(-4,0,8)
	var released := false
	var started := 0
	var rules := ORDERS.duplicate()
	rules.merge({"engage_allowed":false,"fire_allowed":false,"movement_limit":0.0},true)
	for tick in range(1,34):
		var contact := started==0 or tick<=started+2
		var foe := home+Vector3.RIGHT*(1.1 if contact else 4.0)
		var job := job_for(ai,tick,[unit(A,home,0,role),unit(B,foe,1,"infantry")])
		var local := context(home)
		local.holding_ground = FieldBrains._holds_position("Regroup",{"order_type":"hold"})
		var proposal := brain.decide(job,ai.sense(A).value,com.view(A).value,rules,local)
		if not proposal.ok:
			check(false,"valid defence decision "+str(proposal))
			return
		var plan: Dictionary = proposal.value
		check(plan.intents.all(func(i):return not i.has("desired_direction")),"sentry never pursues")
		check(ai.collect(job,plan.intents).ok,"admit defence intents")
		var batch: Dictionary = ai.drain().value[0]
		var commands := actions(plan.intents)
		for cmd: Dictionary in commands:
			if cmd.get("input_phase")=="start":
				check(contact and started==0 and cmd.weapon_slot==0,"only begin an in-reach melee swing")
				started=tick
			if cmd.get("input_phase")=="release":
				check(not contact and cmd.weapon_slot==0 and cmd.target_hint==null,"finish one untracked melee swing after withdrawal")
				released=true
		var actual := com.step_field(tick,commands,poses(home,foe),sweep)
		check(actual.ok and actual.value.receipts.all(func(r):return r.ok),"combat legality")
		check(brain.accept(batch,plan,{"ok":true} if commands.is_empty() else actual.value.receipts[0]).ok,"commit valid command")
	check(started>0 and released and com.view(A).value.phase=="Ready","defender can lower the weapon after the target steps back")
	if role=="archer":check(com.view(A).value.ammo==4,"defending archer never fires under hold fire")

func guard_leash() -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.enlist(A,{"team":0,"role":"infantry"})
	var home := Vector3(-4,0,8)
	var rules := ORDERS.duplicate()
	rules.merge({"engage_allowed":false,"fire_allowed":false,"movement_limit":0.0},true)
	var local := context(home)
	local.holding_ground = true
	local.officer_guard = true
	for tick in range(1,5):
		var pos := home + Vector3.RIGHT * (3.0 if tick in [2,3] else 0.0)
		var foe := home + Vector3.RIGHT * (5.0 if tick==1 else 8.0)
		var job := job_for(ai,tick,[unit(A,pos,0,"infantry"),unit(B,foe,1,"infantry")])
		var plan: Dictionary = brain.decide(job,ai.sense(A).value,com.view(A).value,rules,local).value
		var expected: String = ["Intercept","ReturnToPost","ReturnToPost","Hold"][tick-1]
		check(plan.mode==expected,"obey officer guard leash "+expected)
		if tick<=3:
			check(plan.intents[0].desired_direction[0]==(1000000 if tick==1 else -1000000),"guard moves toward intruder then back to original post")
		check(ai.collect(job,plan.intents).ok and brain.accept(ai.drain().value[0],plan,{"ok":true}).ok,"commit guard-post memory")

func run() -> void:
	for behavior in ["Hold","Regroup","Retreat","Move","Follow"]:
		for order: Variant in [null,{"order_type":"hold"},{"order_type":"retreat"},{"order_type":"move"}]:
			var allowed: bool = (behavior=="Hold" and order==null) or (behavior in ["Hold","Regroup"] and order!=null and order.order_type=="hold")
			check(FieldBrains._holds_position(behavior,order)==allowed,"stationary defence eligibility "+str([behavior,order]))
	engine = EnginePort.new(root,true)
	var scope: Dictionary = engine.open_scope(SCOPE)
	check(engine.load_scene({"id":"base:scene/individual","simulation_scene":"res://tests/p2/individual/arena.tscn"},scope.value).ok,"real field fixture")
	for i in 120:
		await physics_frame
		var synced: Dictionary = engine.sync_navigation(SCOPE)
		if synced.ok and synced.value.status=="applied":
			nav = synced.value.applied_revision
			if path(Vector3(-4,0,8),Vector3(-2,0,8),nav): break
	sentry("infantry")
	sentry("archer")
	moving_orders()
	guard_leash()
	engine.release_scope(SCOPE)
	print("POSITION_DEFENCE checks=",checks," failures=",errors)
	quit(0 if errors==0 else 1)
