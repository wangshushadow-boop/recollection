extends "res://mission/runtime/field_pipeline.gd"
## Authenticated local commands and committed field projections for GameSession.

func gateway(operation: String, payload: Dictionary, context: Variant) -> Dictionary:
	if _busy or _accessing or _phase not in ["Deployment","Running","Ending","Finalizing"]:
		return R.fail("InvalidState","field.gateway")
	_accessing=true
	var grant := _identity(context)
	var result := grant
	if grant.ok:
		result=_gateway(operation,payload,context,grant.value)
	_accessing=false
	return result

func _gateway(operation: String, payload: Dictionary, context: Variant, grant: Dictionary) -> Dictionary:
	if _credentials.has(context): return R.fail("Unauthorized","field.principal")
	if payload.get("mission_id",_mission)!=_mission or payload.get("scope_id",_mission)!=_mission: return R.fail("NotFound","mission_id")
	if operation=="field.view": return _projection(payload,grant)
	if operation=="field.check_order":
		var replay:Variant=payload.get("order")
		if not replay is Dictionary or not is_same(replay.get("issuer_id"),grant.issuer_id) or replay.get("mission_id")!=_mission or not replay.get("order_id") is String:
			return R.fail("Unauthorized","field.order")
		var history:Dictionary=_form.order_status(grant.issuer_id,replay.order_id)
		if not history.ok:return history
		return _form.issue_order(replay,context,payload.get("revisions",payload.get("control_revision")))
	if not _active() or _rules.view().outcome!=null: return R.fail("InvalidState","field.outcome")
	if payload.has("revision") and payload.revision!=_tick:return R.fail("StaleVersion","field.revision")
	match operation:
		"field.input":
			if grant.issuer_id!=_local.issuer_id:return R.fail("Unauthorized","field.input")
			var checked := S.validate_shape("IntentBatch",payload.get("batch"))
			if not checked.ok: return checked
			var batch: Dictionary=checked.value
			if batch.mission_id!=_mission: return R.fail("NotFound","mission_id")
			if batch.source_tick==_tick and not _consumed.is_empty() and batch==_consumed.batch: return R.ok({"source_tick":_tick})
			if batch.source_tick!=_tick+1 or batch.control_revision!=_control_revision: return R.fail("StaleVersion","field.input")
			if _rules.view().control_mode!="direct": return R.fail("Unauthorized","field.input")
			for intent in batch.inputs:
				if intent.actor_handle!=_user_handle or not resolve_entity(_mission,intent.actor_handle).ok:
					return R.fail("Unauthorized","actor_handle")
				if intent.has("target_ref"):
					if intent.action=="jump":
						if not _allow_jump or intent.target_ref!="self":return R.fail("Unauthorized","field.jump")
						continue
					if intent.action not in ["mount","dismount"]:return R.fail("NotFound","field.interaction")
					var state:Dictionary=_com.view(intent.actor_handle)
					if not state.ok or state.value.role!="cavalry":return R.fail("InvalidState","mount")
					if intent.action=="dismount":
						if intent.target_ref!="self" or state.value.mount_handle==null:return R.fail("InvalidState","mount")
					else:
						var horse:Dictionary={}
						for row in _entities.rows():
							if row.components.get("rider_handle")==intent.actor_handle:horse=row.handle
						if horse.is_empty() or intent.target_ref!="field/%d/%d"%[horse.index,horse.generation] or state.value.mount_handle!=null:return R.fail("NotFound","mount")
						if _frame.pose[horse.index].position.distance_squared_to(_player_pose.position)>9.0:return R.fail("Unavailable","mount.distance")
				if intent.get("target_hint")!=null and not _visible_handle(intent.target_hint,grant.team_key):
					return R.fail("NotFound","target_hint")
			if not _input.is_empty() and batch!=_input.batch:
				if is_same(context,_input.context) or _pending_input_authorized():return R.fail("Conflict","field.input")
			_input={"batch":batch,"context":context}
			return R.ok({"source_tick":batch.source_tick})
		"field.order":
			if not payload.get("order") is Dictionary: return R.fail("InvalidArgument","field.order")
			var order: Dictionary=payload.order
			if not order.get("formation_ids") is Array: return R.fail("InvalidArgument","formation_ids")
			for id in order.formation_ids:
				if not V.integer(id): return R.fail("InvalidArgument","formation_ids")
				var group: Dictionary=_form.view(id)
				if not group.ok or not is_same(group.value.team_key,grant.team_key): return R.fail("Unauthorized","formation_ids")
			if order.get("target_formation_id")!=null:
				var target: Dictionary=_form.view(order.target_formation_id)
				if not target.ok or not target.value.members.any(func(h):return _visible_handle(h,grant.team_key)): return R.fail("NotFound","target_formation_id")
			var revision: Variant=payload.get("control_revision",payload.get("revisions"))
			if revision is Dictionary:
				var keyed := {}
				for id in order.formation_ids: keyed[id]=revision.get(str(id),revision.get(id))
				revision=keyed
			var admitted:Dictionary=_form.issue_order(order,context,revision)
			if admitted.ok and order.order_type in ["mount","dismount"]:
				_mount_orders[order.order_id]=order.duplicate(true)
			return admitted
		"field.deploy":
			if grant.issuer_id!=_local.issuer_id:return R.fail("Unauthorized","field.deployment")
			return _deploy_placements(payload.get("placements"),grant,context)
		"field.withdraw": return _rules.request_withdrawal(grant.team_key,context) if is_same(payload.get("team_key",grant.team_key),grant.team_key) else R.fail("Unauthorized","team_key")
		"field.downed":
			if not is_same(payload.get("team_key",grant.team_key),grant.team_key): return R.fail("Unauthorized","team_key")
			return _rules.request_downed_mode(grant.team_key,payload.get("mode",""),context)
	return R.fail("InvalidArgument","field.operation")

var _deployment_sequence := 0

func _deploy_placements(placements: Variant, grant: Dictionary, context: Variant) -> Dictionary:
	if _phase!="Deployment" or not placements is Array or placements.is_empty(): return R.fail("InvalidState","field.deployment")
	var zone: Dictionary=_zones[grant.team_key]
	var zone_id: String=zone.get("id","deployment-"+str(_teams[grant.team_key].ordinal))
	var site := 0
	var occupied := {}
	for row in view().entities:
		if row.source_slot!=null and is_same(row.components.team_key,grant.team_key):
			occupied[row.components.spawn_position_mm]=true
	var available: Array=zone.points_mm.filter(func(p):return not occupied.has(p))
	var remaining := mini(available.size(),zone.quota-occupied.size())
	var seen := {}
	var orders := []
	var layouts := []
	for placement in placements:
		if not placement is Dictionary or not V.integer(placement.get("formation_id")) or placement.get("zone_id")!=zone_id:
			return R.fail("InvalidArgument","field.deployment_zone")
		var id: int=placement.formation_id
		if seen.has(id) or not is_same(_base_groups.get(id),grant.team_key): return R.fail("Unauthorized","formation_id")
		seen[id]=true
		var kind: Variant=placement.get("layout","line")
		if kind not in ["line","shield_wall","loose","square","circle","wedge","column"]: return R.fail("InvalidArgument","layout")
		layouts.append({"id":id,"layout":kind})
		for source in _spec.reserved_sources:
			if ROLES.find(_kit(source).role)!=(id-1)%ROLES.size(): continue
			for slot in range(source.source_slot_range[0],source.source_slot_range[1]):
				if site>=remaining: break
				if _entities.spawned.has(slot) or not is_same(_owners.team_for_slot(slot).value,grant.team_key): continue
				orders.append({"source_slot":slot,"components":{"spawn_position_mm":available[site]}})
				site+=1
	if orders.is_empty(): return R.fail("Unavailable","field.deployment")
	var begin: Dictionary=_form.begin_tick()
	if not begin.ok:return begin
	var sequence:=_deployment_sequence
	for layout in layouts:
		sequence+=1
		var cmd:={"mission_id":_mission,"order_id":"deploy-%d"%sequence,"issuer_id":grant.issuer_id,"formation_ids":[layout.id],
			"order_type":"layout","target_position":null,"target_formation_id":null,"parameters":{"layout":layout.layout},"issued_tick":1,"client_sequence":sequence}
		var issued: Dictionary=_form.issue_order(cmd,context,_form.view(layout.id).value.control_revision)
		if not issued.ok:
			_form.rollback_tick()
			return issued
	var deployed:=apply_deployment(orders)
	if not deployed.ok:
		_form.rollback_tick()
		return deployed
	_form.commit_tick()
	_deployment_sequence=sequence
	return R.ok({"deployed":orders.size(),"last_order_sequence":sequence})

func _visible_handle(h: Dictionary, team: Variant) -> bool:
	var resolved:=resolve_entity(_mission,h)
	if not resolved.ok:return false
	return _visible_row(resolved.value,team)

func _visible_row(row: Dictionary, team: Variant) -> bool:
	if is_same(row.components.team_key,team):return true
	if _user_handle==null:return false
	var observer: Dictionary=_player_pose
	var target: Dictionary=_frame.get("pose",{}).get(row.handle.index,{})
	if observer.is_empty() or target.is_empty():return false
	return _engine.field_los(_mission,observer.position,target.position)

func _projection(payload: Dictionary, grant: Dictionary) -> Dictionary:
	var projection: Variant=payload.get("projection")
	if projection=="visual":return _visual(grant.team_key)
	if projection=="metrics":return R.ok(_frame.get("metrics",{}).duplicate(true))
	var decision: Dictionary=_rules.view()
	var chosen: Variant=payload.get("handle",_user_handle)
	var all_groups := _base_groups.duplicate()
	for id in _frame.get("groups",{}): all_groups[id]=_frame.groups[id].team_key
	var groups := []
	var roles: Dictionary = _frame.get("roles",{}) if projection=="hud" else {}
	var preview: bool = projection=="hud" and _phase=="Deployment"
	var opening: Dictionary = _field.opening_roles(grant.team_key,_kit) if preview else {}
	var targets: Array = _brains.visible_formations(grant.team_key) if _brains.has_method("visible_formations") else []
	for id in all_groups:
		var reading: Dictionary=_form.view(id)
		if not reading.ok:continue
		var g: Dictionary=reading.value
		if is_same(g.team_key,grant.team_key):
			var count:=0
			var troop_role := ""
			for h in g.members:
				if not resolve_entity(_mission,h).ok: continue
				count+=1
				if not roles.is_empty() and troop_role!="mixed":
					var role: String = roles.get(h.index,"")
					if not role.is_empty():
						troop_role = role if troop_role.is_empty() or troop_role==role else "mixed"
			if preview and _base_groups.has(id):
				troop_role = ROLES[(id-1)%ROLES.size()]
				g["planned_count"] = opening.get(troop_role,0)
			if not troop_role.is_empty(): g["troop_role"]=troop_role
			g["count"]=count
			g["controllable"]=grant.issuer_id in [g.owner,g.delegate] and decision.outcome==null
			groups.append(g)
	var player := {}
	if _user_handle!=null:
		var read: Dictionary=_com.view(_user_handle)
		if read.ok: player=read.value
	var zone: Dictionary=_zones[grant.team_key]
	var pose: Dictionary=_player_pose
	var phase: String="ended" if decision.outcome!=null else ("deployment" if _phase=="Deployment" else "battle")
	var out := {"scope_id":_mission,"tick":_tick,"revision":_tick,"phase":phase,"team_key":grant.team_key,"control_revision":_control_revision,
		"actor_handle":_user_handle,"player_handle":_user_handle,"player":player,"rules":decision,"control_mode":decision.control_mode,
		"formations":groups,"targets":targets,"position":pose.get("position",_meters(zone.rally_mm)),"heading":pose.get("heading",Vector3.FORWARD),
		"last_order_sequence":_deployment_sequence}
	match projection:
		"input":return R.ok(out)
		"camera":
			if chosen!=null:
				if not chosen is Dictionary or not _visible_handle(chosen,grant.team_key):return R.fail("NotFound","camera.handle")
				if not is_same(resolve_entity(_mission,chosen).value.components.team_key,grant.team_key):return R.fail("Unauthorized","camera.handle")
				var p: Dictionary=_frame.get("pose",{}).get(chosen.index,{})
				if p.is_empty():return R.fail("NotFound","camera.pose")
				out.merge(p,true)
				var read: Dictionary=_com.view(chosen)
				out["mounted"]=read.ok and read.value.mount_handle!=null
				out["collision_handles"]=["field/%d/%d"%[chosen.index,chosen.generation]]
				if out.mounted:out.collision_handles.append("field/%d/%d"%[read.value.mount_handle.index,read.value.mount_handle.generation])
			return R.ok(out)
		"hud":
			out["delegate_candidate"]=_teams[grant.team_key].issuer
			out["confirmed_events"]=_confirmed_events(grant.team_key)
			out["interaction_target"]=_nearby_mount(player,grant.team_key)
			out["can_withdraw"]=decision.outcome==null and not decision.teams.any(func(t):return is_same(t.team_key,grant.team_key) and t.withdrawn)
			out["deployment_zones"]=[{"id":zone.get("id","deployment-"+str(_teams[grant.team_key].ordinal)),"position_mm":zone.rally_mm}]
			var objectives := PackedVector2Array()
			for site: Dictionary in _teams[grant.team_key].sites:
				if site.objective: objectives.append(Vector2(site.position.x,site.position.z))
			out["objective_sites"] = objectives
			out["target_position"]=null
			out["result"]=_result if not _result.is_empty() else null
			return R.ok(out)
	return R.fail("InvalidArgument","field.projection")

func _nearby_mount(player: Dictionary, team: Variant) -> String:
	if _user_handle==null or player.get("mount_handle")!=null or player.get("role")!="cavalry":return ""
	for row in _frame.get("ending_rows",[]):
		if row.components.get("rider_handle")!=_user_handle:continue
		if _frame.rows.get(row.handle.index,{}).get("handle")!=row.handle or not _visible_handle(row.handle,team):continue
		var position: Vector3=_frame.pose[row.handle.index].position
		if position.distance_squared_to(_player_pose.position)<=9:
			return "field/%d/%d"%[row.handle.index,row.handle.generation]
	return ""

func _visual(team: Variant) -> Dictionary:
	var handles := []
	var live_rows := _entities.rows()
	var staged_rows: Dictionary = _frame.get("rows",{})
	var stable := is_same(live_rows,_frame.get("roster"))
	for row in live_rows:
		# New or recycled handles acquire a MOV/COM pose on their first tick.
		if (stable or is_same(staged_rows.get(row.handle.index),row)) and _visible_row(row,team):
			handles.append(row.handle)
	var read: Dictionary=_com.field_view(_mission,handles)
	if not read.ok:return read
	var actors := []
	for a in read.value.actors:
		var actor: Dictionary=a.duplicate()
		actor.merge(_frame.pose[a.handle.index],true)
		actor.role=_frame.roles[a.handle.index]
		if actor.role=="mount":
			actor["rider_handle"]=staged_rows[a.handle.index].components.rider_handle
		actors.append(actor)
	var visible_shots: Array=read.value.projectiles.filter(func(shot):return not _player_pose.is_empty() and _engine.field_los(_mission,_player_pose.position,shot.position))
	return R.ok({"scope_id":_mission,"tick":_tick,"actors":actors,"projectiles":visible_shots,"confirmed_events":_confirmed_events(team)})

func _confirmed_events(team: Variant) -> Array:
	var events := []
	var report: Dictionary=_frame.get("combat_report",{})
	for hit in report.get("hits",[]):
		if hit.damage>0:_display_event(events,"hit",hit.target,team)
	for ev in report.get("events",[]):
		if ev.has("actor_handle"):_display_event(events,ev.type,ev.actor_handle,team)
	return events

func _display_event(events: Array, kind: String, h: Dictionary, team: Variant) -> void:
	var row: Dictionary=_frame.rows.get(h.index,{})
	if row.is_empty() or row.handle!=h or row.source_slot==null:return
	var pos: Vector3=_frame.pose[h.index].position
	if not is_same(row.components.team_key,team):
		if _player_pose.is_empty() or not _engine.field_los(_mission,_player_pose.position,pos):return
	events.append({"type":kind,"event_id":"%s/%d/%d"%[_mission,_tick,events.size()],"confirmed":true,"actor_handle":h,
		"position":pos,"team":_teams[row.components.team_key].ordinal,"role":_kit(row.components).role})

func dispose() -> Dictionary:
	if _accessing:return R.fail("InvalidState","field.gateway")
	var freed:=super.dispose()
	if freed.ok:
		_frame={}
		_input={}
		_consumed={}
		_move=null
		_com=null
		_form=null
		_rules=null
		_brains=null
		_results=null
		_credentials.clear()
		_teams.clear()
		_factory=Callable()
		_principal=Callable()
	return freed
