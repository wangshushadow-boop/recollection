extends SceneTree
## Approach the enemy line in the shipped battle, with no orders, attacks or blocks.
const Boot = preload("res://bootstrap/composition_root.gd")
const Config = preload("res://bootstrap/boot_config.gd")
var app: RefCounted
var stats := {"seen_ticks":0,"chosen_ticks":0,"ready_in_reach_ticks":0,"attack_phase_ticks":0,"contact_ticks":0}

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	app = Boot.new(root)
	var result := await exercise()
	app.shutdown()
	print("PLAYER_CONTACT ",JSON.stringify(stats))
	quit(0 if result else 1)

func exercise() -> bool:
	var config := Config.resolve([],DisplayServer.get_name(),{})
	if not app.boot(config.value).ok: return false
	var opened: Dictionary = app.start_field(500,500,241124)
	if not opened.ok: return false
	var initial: Dictionary
	for retry in 60:
		await physics_frame
		initial=app.field_step()
		if initial.ok: break
	if not initial.ok: return false
	var mission: RefCounted = app._field_mission.get_ref()
	var player: Dictionary = mission._user_handle
	var enemies := []
	for row: Dictionary in initial.value.entities:
		if row.source_slot!=null and row.components.team_key==1:
			enemies.append(row.handle)
	if enemies.size()!=250: return false
	stats["player"]=player
	stats["start"]=str(mission._player_pose.position)
	var first_contact := 0
	var on_flank := false
	var across_field := false
	for i in 3800:
		var tick: int = mission._tick
		var pose: Dictionary = mission._frame.pose
		var own: Vector3 = mission._player_pose.position
		var nearest: Dictionary = {}
		var distance := INF
		for h: Dictionary in enemies:
			if not pose.has(h.index): continue
			var d := own.distance_to(pose[h.index].position)
			if d<distance:
				nearest=h
				distance=d
		if nearest.is_empty():return false
		var dest: Vector3 = pose[nearest.index].position
		# Walk around the packed friendly ranks as a player can; cutting directly
		# through friendly bodies makes the approach test crowd separation instead.
		if own.z < -24.0: on_flank = true
		if own.x > 30.0: across_field = true
		if not on_flank: dest = Vector3(own.x,0,-26)
		elif not across_field: dest = Vector3(34,0,-25)
		var direction := own.direction_to(dest)
		var speed := 0.0 if distance<=1.15 else 1.0
		if distance<=1.45:
			stats.contact_ticks+=1
			if first_contact==0:
				first_contact=tick
				stats["first_contact"]=tick
		var brain: RefCounted=mission._brains
		var board: RefCounted=brain._ai._board
		if board.seen_by(nearest.index,player):stats.seen_ticks+=1
		var state: Dictionary=brain._l3._members.get(nearest.index,{})
		if distance<=1.45 and not stats.has("nearest_state"):
			var group_id: int=mission._frame.membership[nearest.index]
			var group: Dictionary=brain._l2[1].view(group_id).value
			var order: Variant = mission._frame.groups[group_id].active
			stats["nearest_state"]={"behavior":group.behavior,"order":order.order_type if order!=null else null,"rules":group.member_constraint,"role":mission._frame.roles[nearest.index],"distance":distance,"index":nearest.index}
		if state.get("target")==player:
			stats.chosen_ticks+=1
			var com: Dictionary=mission._com.view(nearest).value
			if distance<=1.45 and com.phase=="Ready":stats.ready_in_reach_ticks+=1
			if com.phase in ["Windup","Hold","Active"]:stats.attack_phase_ticks+=1
		var move := {"actor_handle":player,"desired_direction":[roundi(direction.x*1000000),0,roundi(direction.z*1000000)],"speed_fraction":speed,"stance":"sprint"}
		var frame := {"mission_id":opened.value,"source_tick":tick+1,"control_revision":mission._control_revision,"inputs":[move]}
		var submitted: Dictionary=app.field_command("field.input",{"batch":frame},tick)
		if not submitted.ok:
			printerr(submitted)
			return false
		var stepped: Dictionary=app.field_step()
		if not stepped.ok:
			printerr(stepped)
			return false
		for hit: Dictionary in mission._frame.combat_report.hits:
			if hit.target==player and hit.damage>0 and first_contact>0 and hit.attacker==nearest and distance<=1.45 and mission._com.view(nearest).value.weapon_slot==0:
				stats["damage"]=hit.damage
				stats["hit_tick"]=tick+1
				stats["attacker"]=hit.attacker
				stats["hp"]=mission._com.view(player).value.hp
				return stats.seen_ticks>0 and stats.chosen_ticks>0 and stats.attack_phase_ticks>0 and stats.hp<100
		if first_contact>0 and tick-first_contact>=180:break
		if i%32==0:await physics_frame
	stats["end"]=str(mission._player_pose.position)
	return false
