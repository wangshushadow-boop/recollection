extends RefCounted
## Mission-local L3. A decision is a proposal; adopt its memory only from a drained, executed batch.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const MELEE_REACH := 1.45
const GUARD_RADIUS := 6.0
const TARGET_LOCK := 18
const RETRY_TICKS := 12
const DIRECTIONS := ["up", "left", "right", "thrust"]

var _mission: String
var _issuer: int
var _tick := -1
var _members := {}


func _init(mission_id: String, ai_instance_id: int) -> void:
	_mission = mission_id
	_issuer = ai_instance_id


func fork():
	var copy = get_script().new(_mission,_issuer)
	copy._members = _members.duplicate()
	copy._tick = _tick
	return copy


func forget(handle: Dictionary) -> void:
	if not _handle(handle):
		return
	var old: Variant = _members.get(handle.index)
	if old != null and old.handle.generation > handle.generation:
		return
	var retired := handle.duplicate()
	retired.make_read_only()
	_members[handle.index] = {"handle":retired,"tick":_tick,"retired":true}


static func _point(p: Variant) -> bool:
	return typeof(p) == TYPE_VECTOR3 and p.is_finite()


static func _length_value(x: Variant) -> bool:
	return (typeof(x) == TYPE_FLOAT or typeof(x) == TYPE_INT) and is_finite(float(x)) and x >= 0


static func _handle(h: Variant) -> bool:
	return typeof(h) == TYPE_DICTIONARY and h.size()==2 and V.integer(h.get("index"),0,V.MAX_U32) and V.integer(h.get("generation"),1,V.MAX_U32)


static func _contacts_ok(rows: Array) -> bool:
	if rows.size()>12:
		return false
	for row in rows:
		if typeof(row)!=TYPE_DICTIONARY or not _handle(row.get("handle")) or not _point(row.get("position")) or not row.has("team_key") or typeof(row.get("role"))!=TYPE_STRING:
			return false
	return true


static func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x,0,p.z)


static func _can_go(local: Dictionary, origin: Vector3, goal: Vector3) -> bool:
	if origin.is_equal_approx(goal):
		return true
	var allowed: Variant = local.can_travel.call(origin,goal,local.nav_revision)
	return typeof(allowed) == TYPE_BOOL and allowed


func _fresh(job: Dictionary) -> bool:
	var stamp: Variant = job.get("stamp")
	return (
		job.get("layer") == "individual" and typeof(job.get("urgent"))==TYPE_BOOL and _handle(job.get("subject")) and V.integer(job.get("id"),1)
		and typeof(stamp) == TYPE_DICTIONARY and stamp.get("scope_id") == _mission and stamp.get("instance") == _issuer
		and V.integer(stamp.get("tick")) and stamp.tick >= _tick and stamp.get("generation") == job.subject.generation
		and V.integer(stamp.get("order_revision")) and V.integer(stamp.get("control_revision")) and V.integer(stamp.get("nav_revision"))
	)


static func _target(perception: Dictionary, rules: Dictionary, local: Dictionary, memory: Dictionary, tick: int) -> Dictionary:
	var best := {}
	var best_score := INF
	var best_in_reach := false
	var own: Dictionary = perception.self
	for enemy: Dictionary in perception.visible_enemies:
		if is_same(own.team_key,enemy.team_key) or enemy.role == "mount" or enemy.handle in local.get("incapacitated",[]):
			continue
		if not _can_go(local,own.position,enemy.position):
			continue
		var score: float = own.position.distance_to(enemy.position)
		var in_reach: bool = local.get("holding_ground",false) and score <= MELEE_REACH
		if best_in_reach and not in_reach: continue
		score += maxf(0.0,local.slot_position.distance_to(enemy.position)-rules.movement_limit)
		for ally: Dictionary in perception.nearby_allies:
			if ally.position.distance_squared_to(enemy.position) < 2.25:
				score += 0.75
		if enemy.role in ["archer","mounted_archer"] and own.role in ["cavalry","mounted_archer"]:
			score -= 2.0
		if enemy.handle == memory.get("target") and tick < memory.get("lock_until",-1):
			score -= 6.0
		if enemy.handle == rules.focus_target:
			score -= 100.0
		if (in_reach and not best_in_reach) or score < best_score or (score == best_score and enemy.handle.index < best.handle.index):
			best = enemy
			best_score = score
			best_in_reach = in_reach
	return best


static func _move(own: Dictionary, destination: Vector3, local: Dictionary, rules: Dictionary, speed: float, mounted: bool, use_formation_limit := true) -> Dictionary:
	var goal := destination
	if use_formation_limit:
		goal = local.slot_position + _ground(goal-local.slot_position).limit_length(rules.movement_limit)
	var d := _ground(goal-own.position)
	if d.length_squared() < 0.04 or not _can_go(local,own.position,goal):
		return {}
	# Mounted top speed needs about 5 m to brake plus up to 1.8 m between decisions at 5 Hz.
	var braking_distance := 7.0 if mounted else 0.8
	var fraction := minf(speed,d.length()/braking_distance)
	d = d.normalized()
	return {"actor_handle":own.handle,"desired_direction":[roundi(d.x*1000000),0,roundi(d.z*1000000)],"speed_fraction":fraction,"stance":"sprint" if speed>=1.0 else "walk"}


static func _cancel(own: Dictionary, combat: Dictionary) -> Dictionary:
	return {"actor_handle":own.handle,"input_phase":"cancel","direction":combat.direction,"weapon_slot":combat.weapon_slot,"target_hint":null}

static func _stop(handle: Dictionary) -> Dictionary:
	return {"actor_handle":handle,"desired_direction":[0,0,0],"speed_fraction":0.0,"stance":"walk"}

# A quiet member can propose at most one move. An unreachable destination has
# the same outcome as _move returning empty, including stopping a previous drive.
func _without_quiet_move(proposal: Dictionary) -> Dictionary:
	var own: Dictionary = proposal.job.subject
	var prior: Dictionary = _members.get(own.index,{})
	var intents: Array = proposal.intents.slice(1)
	if prior.get("handle")==own and prior.get("moving",false):
		var stop := _stop(own)
		stop.desired_direction.make_read_only()
		stop.make_read_only()
		intents.push_front(stop)
	intents.make_read_only()
	var state: Dictionary = proposal.state.duplicate()
	state.moving = false
	state.make_read_only()
	var corrected := proposal.duplicate()
	corrected.intents = intents
	corrected.state = state
	corrected.make_read_only()
	return corrected


static func _attack(own: Dictionary, combat: Dictionary, target: Dictionary, tick: int) -> Dictionary:
	if combat.phase == "Guard":
		return {"actor_handle":own.handle,"direction":combat.direction,"held":false}
	var phase: String
	var direction: String = combat.direction
	match combat.phase:
		"Ready":
			phase = "start"
			direction = "thrust" if combat.weapon_slot != 0 or own.role == "cavalry" else DIRECTIONS[(own.handle.index + target.handle.index + floori(tick/12.0)) % 4]
		"Windup": phase = "hold"
		"Hold": phase = "release"
		_: return {}
	return {"actor_handle":own.handle,"input_phase":phase,"direction":direction,"weapon_slot":combat.weapon_slot,"target_hint":target.get("handle")}


# local holds only this member's slot/exit, equipment and navigation reachability for this revision.
func decide(job: Dictionary, perception: Dictionary, combat: Dictionary, rules: Dictionary, local: Dictionary) -> Dictionary:
	if not _fresh(job) or perception.get("stamp") != job.stamp or local.get("nav_revision") != job.stamp.nav_revision:
		return R.fail("StaleVersion","individual_job")
	if typeof(perception.get("self"))!=TYPE_DICTIONARY:
		return R.fail("InvalidArgument","individual_member")
	var own: Dictionary = perception.self
	if own.get("handle") != job.subject or combat.get("handle") != job.subject or own.get("control_revision") != job.stamp.control_revision or own.get("order_revision") != job.stamp.order_revision:
		return R.fail("StaleVersion","individual_member")
	if typeof(own.get("role"))!=TYPE_STRING or not own.has("team_key") or not _point(own.get("position")) or not _point(local.get("slot_position")) or not _point(local.get("heading")) or (local.get("exit_position") != null and not _point(local.exit_position)):
		return R.fail("InvalidArgument","individual_pose")
	if not _length_value(local.get("reaction_skill",1.0)) or local.get("reaction_skill",1.0)>1.0 or not V.integer(local.get("react_at",0)) or typeof(local.get("threat_direction","up"))!=TYPE_STRING or typeof(local.get("incapacitated",[]))!=TYPE_ARRAY or local.get("incapacitated",[]).size()>12:
		return R.fail("InvalidArgument","individual_threat")
	if typeof(local.get("can_travel")) != TYPE_CALLABLE or not local.can_travel.is_valid():
		return R.fail("Unavailable","individual_navigation")
	if typeof(rules.get("fire_allowed")) != TYPE_BOOL or typeof(rules.get("engage_allowed")) != TYPE_BOOL or not _length_value(rules.get("slot_tolerance")) or not _length_value(rules.get("movement_limit")) or (rules.get("focus_target") != null and not _handle(rules.focus_target)):
		return R.fail("InvalidArgument","member_constraint")
	if not rules.has("focus_target") or typeof(perception.get("visible_enemies")) != TYPE_ARRAY or typeof(perception.get("nearby_allies")) != TYPE_ARRAY or not _contacts_ok(perception.visible_enemies) or not _contacts_ok(perception.nearby_allies):
		return R.fail("InvalidArgument","individual_perception")
	var tick: int = job.stamp.tick
	var old: Dictionary = _members.get(job.subject.index,{})
	if not old.is_empty() and (job.subject.generation < old.handle.generation or (old.handle == job.subject and (old.get("retired",false) or old.tick >= tick))):
		return R.fail("StaleVersion","individual_tick")
	var was_moving: bool = old.get("handle")==job.subject and old.get("moving",false)
	if old.get("handle") != job.subject or old.get("order_revision") != job.stamp.order_revision or old.get("control_revision") != job.stamp.control_revision:
		old = {}
	var target := {}
	var mode := "Hold"
	var move := {}
	var action := {}
	var look := {}
	var equipment: Variant = combat.get("weapons",local.get("weapons"))
	if typeof(equipment)!=TYPE_ARRAY:
		return R.fail("InvalidArgument","individual_equipment")
	var weapons: Array = equipment
	if (not combat.has_all(["phase","since","direction","role","hp","routing","weapon_slot","ammo","mount_handle"])
			or typeof(combat.phase)!=TYPE_STRING or typeof(combat.direction)!=TYPE_STRING or typeof(combat.routing)!=TYPE_BOOL
			or not V.integer(combat.hp) or not V.integer(combat.ammo) or not V.integer(combat.since)
			or weapons.is_empty() or not V.integer(combat.weapon_slot,0,weapons.size()-1)):
		return R.fail("InvalidArgument","individual_equipment")
	var reload_until: Variant = combat.get("reload_until",local.get("reload_until"))
	if not V.integer(reload_until):
		return R.fail("InvalidArgument","reload_until")
	var mounted: bool = combat.mount_handle != null
	var ranged: bool = weapons.size()>1 and combat.ammo>0
	var current_attack_allowed: bool = rules.engage_allowed if combat.weapon_slot==0 else rules.fire_allowed
	var break_until: int = old.get("break_until",-1)
	var sentry: bool = local.get("officer_guard",false) and not combat.routing and not (ranged and rules.fire_allowed)
	var post: Variant = old.get("guard_post") if sentry else null
	if combat.hp==0 or combat.phase=="Downed" or combat.role=="mount":
		mode = "Incapacitated"
	elif combat.routing:
		mode = "Routing"
		if local.get("exit_position") != null:
			move = _move(own,local.exit_position,local,rules,1.0,mounted,false)
	else:
		target = _target(perception,rules,local,old,tick)
		if job.get("urgent",false) and local.get("threat_handle") != null:
			for seen: Dictionary in perception.visible_enemies:
				if seen.handle==local.threat_handle and seen.handle not in local.get("incapacitated",[]) and own.position.distance_squared_to(seen.position)<=9.0:
					target = seen
					break
		var distance: float = INF if target.is_empty() else own.position.distance_to(target.position)
		# Officer-led sentries may intercept a nearby visible intruder. Keep the original
		# post until they return so a moving target cannot lead the unit across the field.
		if sentry and post==null and distance<=GUARD_RADIUS:
			post = own.position
		var guarding: bool = post!=null and not target.is_empty() and post.distance_squared_to(target.position)<=GUARD_RADIUS*GUARD_RADIUS
		if not guarding and post!=null and own.position.distance_squared_to(post)<0.25:
			post=null
		# A holding formation can strike from its place without gaining permission to pursue.
		var defend_here: bool = local.get("holding_ground",false) and distance <= MELEE_REACH
		if defend_here and combat.weapon_slot==0: current_attack_allowed = true
		var forward := Vector3.ZERO if target.is_empty() else _ground(target.position-own.position).normalized()
		var side := forward.cross(Vector3.UP) * (1.0 if own.handle.index%2==0 else -1.0)
		var direction: String = local.get("threat_direction","up")
		var threat: Variant = local.get("threat_handle")
		var skill: float = local.get("reaction_skill",1.0)
		var react_at: int = local.get("react_at",0) + roundi((1.0-skill)*6.0)
		var threatened: bool = job.get("urgent",false) and distance <= 3.0 and direction in DIRECTIONS and threat != null and threat == target.get("handle") and tick >= react_at
		if threatened:
			mode = "React"
			var can_guard: bool = weapons[combat.weapon_slot]!="bow" and (combat.phase in ["Ready","Guard"] or (combat.phase=="Windup" and tick-combat.since<2))
			if can_guard:
				# An observed swing may be misread. The same local observation must replay identically on retry.
				var observation: int = (own.handle.index*31 + own.handle.generation*17 + threat.index*13 + react_at) % 100
				if observation >= roundi(skill*100.0):
					direction = DIRECTIONS[(DIRECTIONS.find(direction)+1)%DIRECTIONS.size()]
				action = {"actor_handle":own.handle,"direction":direction,"held":true}
			else:
				move = _move(own,own.position+side*2.0,local,rules,1.0,mounted)
		elif combat.phase == "Stagger":
			mode = "Recover"
		elif not defend_here and post!=null:
			mode = "Intercept" if guarding else "ReturnToPost"
			move = _move(own,target.position if guarding else post,local,rules,1.0,mounted,false)
		elif not defend_here and (not rules.engage_allowed or distance == INF) and own.position.distance_to(local.slot_position) > rules.slot_tolerance:
			mode = "MoveToSlot"
			move = _move(own,local.slot_position,local,rules,1.0,mounted)
		elif not target.is_empty() and (defend_here or rules.engage_allowed or (ranged and rules.fire_allowed)):
			var use_ranged: bool = not defend_here and ranged and rules.fire_allowed and (distance > 2.7 or not rules.engage_allowed)
			var slot := 1 if use_ranged else 0
			if combat.weapon_slot != slot and combat.phase in ["Ready","Guard"]:
				mode = "Equip"
				action = {"actor_handle":own.handle,"slot":slot,"item_ref":weapons[slot]}
			elif combat.weapon_slot != slot and combat.phase in ["Windup","Hold"]:
				# Resolve the action on the equipped weapon before switching to the new range.
				mode = "Recover"
				if combat.phase=="Windup" and tick-combat.since<2:
					action = _cancel(own,combat)
				elif current_attack_allowed:
					action = _attack(own,combat,target,tick)
			elif not defend_here and mounted and tick<break_until and not use_ranged:
				mode = "Disengage"
				move = _move(own,own.position+side*3.0-forward,local,rules,1.0,mounted)
			elif use_ranged:
				mode = "MountedArchery" if mounted else "Aim"
				if mounted and rules.engage_allowed:
					move = _move(own,own.position+side*3.0+forward*clampf(distance-10.0,-2.0,2.0),local,rules,0.85,mounted)
				elif distance < 5.0 and rules.engage_allowed:
					move = _move(own,own.position-forward*2.0,local,rules,0.8,mounted)
				if combat.weapon_slot==slot and tick>=reload_until:
					action = _attack(own,combat,target,tick)
			elif distance <= MELEE_REACH and combat.weapon_slot==0:
				mode = "MountedStrike" if mounted else "Melee"
				action = _attack(own,combat,target,tick)
				if mounted and action.get("input_phase")=="release":
					break_until = tick+18
			else:
				mode = "Charge" if mounted else "Approach"
				move = _move(own,target.position,local,rules,1.0,mounted)
			if forward != Vector3.ZERO and _ground(local.heading).normalized().dot(forward)<0.98:
				look = {"actor_handle":own.handle,"yaw":roundi(atan2(-forward.x,-forward.z)*1000000),"pitch":0}
		if action.is_empty() and combat.phase=="Guard" and not threatened:
			action = {"actor_handle":own.handle,"direction":combat.direction,"held":false}
		elif action.is_empty() and combat.phase=="Windup" and tick-combat.since<2 and (target.is_empty() or not current_attack_allowed):
			action = _cancel(own,combat)
		elif action.is_empty() and combat.phase=="Hold" and combat.weapon_slot==0 and not defend_here and local.get("holding_ground",false):
			# The intruder left during windup. Finish the existing swing without a target hint.
			action = _attack(own,combat,{},tick)
	if not action.is_empty() and old.get("rejected") == action and tick<old.get("retry_tick",-1):
		action = {}
		break_until = old.get("break_until",-1)
	var moving := not move.is_empty()
	if not moving and was_moving and mode != "Incapacitated":
		move = _stop(own.handle)
	var intents := []
	for intent in [move,look,action]:
		if not intent.is_empty():
			if intent.has("desired_direction"):
				intent.desired_direction.make_read_only()
			intent.make_read_only()
			intents.append(intent)
	intents.make_read_only()
	var chosen: Variant = target.get("handle")
	var lock_until: int = old.get("lock_until",-1) if chosen == old.get("target") else tick+TARGET_LOCK
	var state := {"handle":own.handle,"tick":tick,"order_revision":job.stamp.order_revision,"control_revision":job.stamp.control_revision,
		"target":chosen,"lock_until":lock_until,"break_until":break_until,"moving":moving,"rejected":old.get("rejected"),"retry_tick":old.get("retry_tick",-1)}
	if post!=null: state["guard_post"]=post
	state.make_read_only()
	var proposal := {"branch":get_instance_id(),"job":job,"mode":mode,"target":chosen,"intents":intents,"state":state,"has_action":not action.is_empty()}
	proposal.make_read_only()
	return R.ok(proposal)


# Pass the matching row from FieldAI.drain after COM/MOV execution. A fork is published only on Mission commit.
func accept(batch: Dictionary, proposal: Dictionary, action_receipt: Dictionary, movement_receipt: Dictionary = {"ok":true}) -> Dictionary:
	var job: Variant = batch.get("job")
	if typeof(job)!=TYPE_DICTIONARY or not _fresh(job) or proposal.get("branch")!=get_instance_id() or not is_same(job,proposal.get("job")) or batch.get("intents")!=proposal.get("intents"):
		return R.fail("StaleVersion","individual_receipt")
	var previous: Dictionary = _members.get(job.subject.index,{})
	if not previous.is_empty() and (job.subject.generation<previous.handle.generation or (previous.handle == job.subject and (previous.get("retired",false) or previous.tick>=job.stamp.tick))):
		return R.fail("StaleVersion","individual_tick")
	if typeof(action_receipt.get("ok"))!=TYPE_BOOL or typeof(movement_receipt.get("ok"))!=TYPE_BOOL or typeof(proposal.get("state"))!=TYPE_DICTIONARY:
		return R.fail("InvalidArgument","action_receipt")
	if proposal.state.get("handle")!=job.subject or proposal.state.get("tick")!=job.stamp.tick:
		return R.fail("InvalidArgument","action_receipt")
	var next: Dictionary = proposal.state
	if proposal.has_action and not action_receipt.ok:
		next = next.duplicate()
		next.rejected = proposal.intents.back()
		next.retry_tick = job.stamp.tick+RETRY_TICKS
		next.break_until = previous.get("break_until",-1)
		next.make_read_only()
	if not movement_receipt.ok:
		next = next.duplicate()
		next.moving = previous.get("moving",false)
		next.make_read_only()
	_members[job.subject.index] = next
	_tick = job.stamp.tick
	return R.ok()
