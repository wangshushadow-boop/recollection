extends SceneTree
const Mission=preload("res://mission/runtime/field_mission.gd")
const Compiler=preload("res://infrastructure/content/compiler.gd")
const Core=preload("res://core/runtime.gd")
const EngineAdapter=preload("res://infrastructure/engine/adapter.gd")
const R=preload("res://contracts/result.gd")
const UUID:="b48883c0-79fb-4cd3-96fe-43bb44dfddbb"
class Passive:
	extends RefCounted
	func decide(_t,_n,_u,_c,_p):
		return R.ok({"actions":[],"moves":[],"looks":[],"metrics":{}})
	func accept_actions(_a,_m):return R.ok()
	func commit_tick():pass
	func rollback_tick():pass

class OpposingAttacker extends Passive:
	func decide(tick,_nav,units,com,player):
		var actions:=[]
		for actor in units:
			if is_same(actor.team_key,0):continue
			var state:Dictionary=com.view(actor.handle).value
			var input_phase:=""
			if state.phase=="Ready":input_phase="start"
			elif state.phase=="Hold" and tick-state.since>=7:input_phase="release"
			if not input_phase.is_empty():
				actions.append({"actor_handle":actor.handle,"input_phase":input_phase,"direction":"thrust","weapon_slot":0,"target_hint":player})
		return R.ok({"actions":actions,"moves":[],"looks":[],"metrics":{}})

var failed:=0
var checks:=0
var token:=RefCounted.new()
var officer:=RefCounted.new()
var revoke:=false
var mission:RefCounted
var registry:RefCounted
var adapter:RefCounted
var core:=Core.new("1234567890abcdef")
var brain_script:Script
var scope:=""
var site_positions:=[[[0,0,0],[0,0,-5000]],[[1150,0,0],[1150,0,5000]]]
var action_contacts:=0
var drill_attack:=false

func check(condition:bool,label:String)->bool:
	checks+=1
	if not condition:
		failed+=1
		printerr("FAIL ",label)
	return condition

func ok(reply:Dictionary,label:String)->bool:
	return check(reply.ok,label+" "+str(reply.get("error","")))

func _initialize():
	run.call_deferred()

func factory(world,engine,form,teams):
	if drill_attack:return OpposingAttacker.new()
	return brain_script.new(world,engine,form,teams) if brain_script!=null else Passive.new()

func auth(t):
	if is_same(t,officer):return R.ok({"issuer_id":"field-officer","team_key":0})
	return R.ok({"issuer_id":"player","team_key":0}) if is_same(t,token) and not revoke else R.fail("Unauthorized","test.revoked")

func battle(type_ids:Array,counts:Array,quota:int)->Dictionary:
	var sides:=[]
	var sources:=[]
	var zones:=[]
	var exits:=[]
	var at:=0
	for side in 2:
		var start:=at
		var team:Variant=0 if side==0 else "0"
		for i in type_ids.size():
			sources.append({"source_slot_range":[at,at+counts[i]],"count":counts[i],"hero_id":null,"troop_def_id":"field:troop/"+type_ids[i],"source_party_id":"party/"+UUID,"loadout_snapshot_id":"issued"})
			at+=counts[i]
		sides.append({"team_key":team,"faction_id":"river","commander_hero_id":null,"roster_allocations":[{"source_slot_range":[start,at]}]})
		zones.append({"id":"zone%d"%side,"team_key":team,"quota":quota,"rally_mm":site_positions[side][0],"points_mm":site_positions[side].slice(0,quota)})
		exits.append({"team_key":team,"min_mm":[-18000 if side==0 else 17000,-500,-5000],"max_mm":[-17000 if side==0 else 18000,2000,5000]})
	var spec:={"schema_version":1,"encounter_id":"encounter/"+UUID,"mode":"custom","reservation_revision":1,"scene_def_id":"field:scene/river_plain",
		"ruleset_id":"field:ruleset/field_battle","rng_seed":"1234567890abcdef","environment":{},"sides":sides,"reserved_sources":sources,"battle_limit":quota*2,"deployment_constraints":{},"siege_snapshot":null}
	return {"spec":spec,"scene":{"id":spec.scene_def_id,"simulation_scene":"res://tests/p2/mission/ground.tscn","field_zones":zones,"field_exit_zones":exits,
		"field_sites":[{"id":"center","position":Vector3(.5,0,0),"objective":true}]},"rules":{"id":spec.ruleset_id,"battle_mode":"field","wave_cooldown_ticks":2,"wave_size":2}}

func open(data:Dictionary)->bool:
	mission=Mission.new(core,adapter,"custom",registry,auth,factory)
	var prepared:Dictionary=mission.prepare(data.spec,data.scene,data.rules)
	if not ok(prepared,"production field prepare"):return false
	scope=mission.view().mission_id
	for i in 90:
		await physics_frame
		var nav:Dictionary=adapter.sync_navigation(scope)
		if nav.ok and nav.value.status=="applied":
			var path:Dictionary=adapter.query_path_batch([{"from":[0,0,0],"to":[1000,0,0]}],nav.value.applied_revision,scope)
			if path.ok and path.value[0].reachable:return true
	return check(false,"real navigation ready")

func hud()->Dictionary:
	return mission.gateway("field.view",{"projection":"hud"},token).value

func input(t:int,intents:Array)->Dictionary:
	return mission.gateway("field.input",{"batch":{"mission_id":scope,"source_tick":t,"control_revision":0,"inputs":intents}},token)

func move(h:Dictionary)->Dictionary:
	return {"actor_handle":h,"desired_direction":[0,0,1000000],"speed_fraction":0.5,"stance":"walk"}

func field_test()->void:
	if not await open(battle(["infantry","mounted_archer"],[1,1],2)):return
	check(not mission.gateway("field.view",{"projection":"hud"},{}).ok,"opaque credentials required")
	check(not mission.request_end({"outcome":"victory"}).ok and mission.view().phase=="Deployment","invented victory does not freeze")
	var wrong:Dictionary=mission.gateway("field.deploy",{"placements":[{"formation_id":5,"zone_id":"zone0","layout":"line"}]},token)
	check(not wrong.ok and mission.view().spawned_slots.is_empty(),"prevent deploying an enemy group")
	var legal:Dictionary=mission.gateway("field.deploy",{"placements":[{"formation_id":1,"zone_id":"zone0","layout":"line"}]},token)
	if not ok(legal,"authorized local formation deploy"):return
	var fail_at_end:=[false]
	var inject:=func(_ctx,_batch):
		if fail_at_end[0]:revoke=true
		return R.ok()
	ok(mission.register_system("snapshot",{"id":"zz.inject","run":inject}),"install downstream revocation")
	var first:Dictionary=mission.step_fixed(1,[])
	if not ok(first,"open partially populated battle"):return
	check(first.value.spawned_slots.size()==4 and first.value.entities.size()==6,"first wave filled both sides, two true nonsource mounts")
	var h:Dictionary=hud().player_handle
	var enemy:= {}
	for row in first.value.entities:
		if row.source_slot!=null and is_same(row.components.team_key,"0"):enemy=row.handle;break
	check(not input(2,[move(enemy)]).ok and not mission.step_fixed(2,[move(enemy)]).ok,"spoofed direct or envelope actor")
	check(not mission.gateway("field.withdraw",{"team_key":"0"},token).ok,"typed opponent cannot be withdrawn")
	var before:Dictionary=mission.gateway("field.view",{"projection":"camera"},token).value
	ok(input(2,[move(h)]),"authorized movement buffered")
	fail_at_end[0]=true
	var rejected:Dictionary=mission.step_fixed(2,[])
	revoke=false
	check(not rejected.ok and rejected.error.code=="Unauthorized" and mission.view().tick==1,"late final MOV rejection leaves tick unpublished")
	var same:Dictionary=mission.gateway("field.view",{"projection":"camera"},token).value
	check(same.position==before.position and hud().rules.tick==1,"rollback covers MOV/RULES/public projection")
	fail_at_end[0]=false
	ok(mission.step_fixed(2,[]),"retry original authenticated input")
	var live:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
	var horses:Array=live.actors.filter(func(a):return a.role=="mount")
	var riders:Array=live.actors.filter(func(a):return a.role=="mounted_archer")
	check(live.actors.size()==6 and horses.size()==2 and riders.size()==2,"four human models plus both real horse models")
	check(riders.all(func(rider):return horses.any(func(horse):return horse.handle==rider.mount_handle and horse.rider_handle==rider.handle and horse.position==rider.position)),"visible rider shares the actual horse generation and pose")
	ok(mission.gateway("field.withdraw",{},token),"authorized party retires")
	ok(mission.step_fixed(3,[]),"end by rules")
	var decision:Dictionary=hud().rules.outcome
	ok(mission.request_end(decision),"authoritative victory")
	var ended:Dictionary=mission.finalize()
	if ok(ended,"real RESULTS finalize"):
		check(ended.value.slot_outcomes.size()==4 and ended.value.winner_team_keys==["0"],"source-complete result, no horse counted")
	ok(mission.dispose(),"field release")

func real_hits()->void:
	if not await open(battle(["infantry"],[1],1)):return
	ok(mission.step_fixed(1,[]),"opening wave")
	var h:Dictionary=hud().player_handle
	var damaged:=false
	for tick in range(2,20):
		var actions:=[]
		if tick in [2,5]:
			actions.append({"actor_handle":h,"input_phase":"start" if tick==2 else "release","weapon_slot":0,"direction":"thrust","target_hint":null})
		if not actions.is_empty():ok(input(tick,actions),"combat input")
		var ran:Dictionary=mission.step_fixed(tick,[])
		if not ok(ran,"actual ticking field"):break
		for report in ran.value.system_reports:
			if report.id=="field.combat":
				for hit in report.value.hits:
					action_contacts+=1
					if hit.attacker==h and hit.damage>0:damaged=true
		if damaged:break
	check(damaged,"real Jolt contact produced COM health loss")
	ok(mission.gateway("field.withdraw",{},token),"retreat at contact")
	ok(mission.step_fixed(mission.view().tick+1,[]),"field ends after contact")
	ok(mission.request_end(hud().rules.outcome),"natural ending")
	var receipt:Dictionary=mission.finalize()
	if ok(receipt,"actual damage through RESULTS"):check(receipt.value.slot_outcomes[0].xp>=1 and receipt.value.slot_outcomes[1].wounded,"hit provenance and XP")
	mission.dispose()

func commander_bow()->void:
	var saved_positions:=site_positions
	var saved_brains:=brain_script
	site_positions=[[[-5000,0,0]],[[5000,0,0]]]
	brain_script=null # Keep the two physical targets fixed while testing the player's sight.
	var data:=battle(["infantry"],[1],1)
	site_positions=saved_positions
	var source:Dictionary=data.spec.reserved_sources[0]
	source.hero_id="hero/"+UUID
	source.troop_def_id=null
	source.loadout_snapshot_id="field:equipment/commander"
	data.spec.sides[0].commander_hero_id=source.hero_id
	var opened:=await open(data)
	brain_script=saved_brains
	if not opened:return
	ok(mission.step_fixed(1,[]),"commander equipment opening")
	var player:Dictionary=hud().player
	var h:Dictionary=player.handle
	check(player.role=="infantry" and player.weapons==["melee","bow"] and player.shield==32 and player.windup_ticks==9,"captain keeps infantry formation and real melee, shield and bow")
	var aimed:= {"actor_handle":h,"yaw":roundi(-PI*.5*1000000),"pitch":roundi(PI/6*1000000)}
	var level:=aimed.merged({"pitch":0},true)
	var start:={"actor_handle":h,"input_phase":"start","direction":"left","weapon_slot":1,"target_hint":null}
	var release:=start.merged({"input_phase":"release"},true)
	var block:={"actor_handle":h,"held":true,"direction":"up"}
	var landed:=false
	for t in range(2,91):
		var intents:=[]
		match t:
			2:intents=[start.merged({"weapon_slot":0},true)]
			11:intents=[block]
			12:intents=[block.merged({"held":false},true),{"actor_handle":h,"slot":1,"item_ref":"bow"}]
			13,32:intents=[start,aimed]
			14,51:intents=[block]
			31:intents=[start.merged({"input_phase":"cancel"},true)]
			50,80:intents=[release]
			55:intents=[start.merged({"input_phase":"cancel"},true)]
			62:intents=[start,level]
		if not intents.is_empty():ok(input(t,intents),"authorized bow input "+str(t))
		var step:Dictionary=mission.step_fixed(t,[])
		if not ok(step,"captain bow timeline"):break
		var visual:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
		match t:
			11:check(hud().player.phase=="Guard" and hud().player.direction=="up","held melee feint enters directional defense")
			12:check(hud().player.weapon_kind=="bow" and hud().player.windup_ticks==18,"real bow slot changes action timing")
			14:check(hud().player.phase=="Windup","cannot raise a stowed shield with the bow equipped")
			30:check(hud().player.phase=="Windup","short bow still drawing one step before full draw")
			31:check(hud().player.phase=="Ready" and hud().player.ammo==8 and visual.projectiles.is_empty(),"let down full draw without a projectile or debit")
			50:
				var actor:Dictionary=visual.actors.filter(func(a):return a.handle==h)[0]
				check(actor.phase=="Active" and actor.weapon_kind=="bow" and is_equal_approx(actor.aim_pitch,PI/6),"shoot pose uses committed weapon and pitch")
				check(visual.projectiles.size()==1 and visual.projectiles[0].direction.y>.48 and is_equal_approx(visual.projectiles[0].position.y-hud().player.shot_origin.y,.85),"rendered flight rises from the HUD-authority muzzle")
				check(hud().player.ammo==7 and absf(actor.heading.y)<.001,"only the projectile tilts and launch consumes one arrow")
			51:check(hud().player.phase=="Active" and hud().player.ammo==7,"guard cannot undo a released arrow")
			55:check(hud().player.phase=="Recovery","cannot cancel recovery")
		for report in step.value.system_reports:
			if report.id=="field.combat" and report.value.hits.any(func(hit):return hit.attacker==h and hit.damage>0):
				landed=true
				check(t>80,"elevated shot misses, next horizontal arrow physically hits")
	check(landed and hud().player.ammo==6,"level arrow produces confirmed damage and one more debit")
	mission.dispose()

func nonmovement_revocation()->void:
	if not await open(battle(["infantry"],[1],1)):return
	var fault:=[false]
	var late:=func(_ctx,_batch):
		if fault[0]:revoke=true
		return R.ok()
	ok(mission.register_system("snapshot",{"id":"zz.revoke","run":late}),"revoke after candidate COM and look")
	ok(mission.step_fixed(1,[]),"start look/attack authority test")
	var old:Dictionary=mission.gateway("field.view",{"projection":"camera"},officer).value
	var h:Dictionary=old.actor_handle
	var intent:={"actor_handle":h,"input_phase":"start","weapon_slot":0,"direction":"thrust","target_hint":null}
	ok(input(2,[{"actor_handle":h,"yaw":3000000,"pitch":0},intent]),"admit nonmovement batch")
	fault[0]=true
	var denied:Dictionary=mission.step_fixed(2,[])
	var after:Dictionary=mission.gateway("field.view",{"projection":"camera"},officer).value
	check(not denied.ok and denied.error.code=="Unauthorized" and after.tick==old.tick and after.heading==old.heading and after.player.phase==old.player.phase,"revoked nonmovement input cannot publish")
	revoke=false
	fault[0]=false
	ok(mission.step_fixed(2,[]),"restored authority retries original same tick")
	var accepted:Dictionary=mission.gateway("field.view",{"projection":"camera"},officer).value
	check(accepted.tick==2 and accepted.heading!=old.heading and accepted.player.phase=="Windup","retry publishes both original intentions once")
	mission.dispose()

func input_on_incapacitation()->void:
	var data:=battle(["infantry"],[1],1)
	data.spec.reserved_sources[0].count=2
	data.spec.reserved_sources[0].source_slot_range=[0,2]
	data.spec.reserved_sources[1].source_slot_range=[2,3]
	data.spec.sides[0].roster_allocations=[{"source_slot_range":[0,2]}]
	data.spec.sides[1].roster_allocations=[{"source_slot_range":[2,3]}]
	drill_attack=true
	var ready:=await open(data)
	drill_attack=false
	if not ready:return
	ok(mission.step_fixed(1,[]),"bind player and pending reserve")
	var h:Dictionary=hud().player_handle
	var downed:=false
	for tick in range(2,280):
		var look:Dictionary=input(tick,[{"actor_handle":h,"yaw":1500000,"pitch":0}])
		if not look.ok:
			ok(look,"player retained direct control before enemy hit")
			break
		var ran:Dictionary=mission.step_fixed(tick,[])
		if not ran.ok:
			ok(ran,"authorized input can complete its casualty tick")
			break
		for entry in ran.value.system_reports:
			if entry.id=="field.combat" and entry.value.events.any(func(e):return e.type=="downed" and e.actor_handle==h):downed=true
		if downed:break
	check(downed and not mission.resolve_entity(scope,h).ok and hud().rules.commander_downed,"same-tick legitimate input permits actual player incapacity and retirement")
	mission.dispose()

func replace_expired_batch()->void:
	if not await open(battle(["infantry"],[1],1)):return
	ok(mission.step_fixed(1,[]),"open replacement test")
	var actor:Dictionary=hud().player_handle
	var start:={"actor_handle":actor,"input_phase":"start","weapon_slot":0,"direction":"thrust","target_hint":null}
	var look:={"actor_handle":actor,"yaw":2700000,"pitch":0}
	ok(input(2,[start]),"admit first authenticated batch")
	check(not input(2,[look]).ok,"still valid conflicting batch rejected")
	token=RefCounted.new()
	check(not mission.step_fixed(2,[]).ok and mission.view().tick==1,"old credential refuses publication")
	ok(input(2,[look]),"replacement credential supersedes the revoked batch")
	ok(mission.step_fixed(2,[]),"replacement batch publishes")
	check(hud().player.phase=="Ready","revoked attack never executed")
	ok(input(3,[start]),"admit another attack")
	token=RefCounted.new()
	check(not mission.step_fixed(3,[]).ok and mission.view().tick==2,"unreplaced revoked batch rolls back")
	ok(mission.step_fixed(3,[]),"authority advances without unreplaced invalid input")
	check(hud().player.phase=="Ready" and mission.view().tick==3,"server did not replay revoked attack")
	mission.dispose()

func large_field()->void:
	var previous:=site_positions.duplicate(true)
	site_positions=[[],[]]
	for side in 2:
		for i in 250:
			site_positions[side].append([(-42000 if side==0 else 16000)+int(i%25)*1000,0,-6000+int(i/25)*1250])
	var data:=battle(["infantry","archer","cavalry","mounted_archer"],[125,125,125,125],250)
	# Interleave the four authentic troop reservations across the first wave.
	data.spec.reserved_sources.clear()
	for side in 2:
		for i in 500:
			var slot:int=side*500+i
			data.spec.reserved_sources.append({"source_slot_range":[slot,slot+1],"count":1,"hero_id":null,
				"troop_def_id":"field:troop/"+["infantry","archer","cavalry","mounted_archer"][i%4],"source_party_id":"party/"+UUID,"loadout_snapshot_id":"issued"})
	if not await open(data):return
	var began:=Time.get_ticks_usec()
	var first:Dictionary=mission.step_fixed(1,[])
	if not ok(first,"1000 reserve, real 500-person opening"):return
	var opened_us:=Time.get_ticks_usec()-began
	check(first.value.spawned_slots.size()==500 and first.value.entities.size()>700,"mixed kit and horses fill field cap by people")
	var visuals:Dictionary=mission.gateway("field.view",{"projection":"visual"},token)
	if ok(visuals,"large field rendering projection"):
		check(visuals.value.actors.size()==first.value.entities.size() and visuals.value.actors.filter(func(a):return a.role=="mount").size()==248,"flat river view includes 500 humans and 248 same-scope horses")
	began=Time.get_ticks_usec()
	ok(mission.step_fixed(2,[]),"actual 500-person fixed step")
	var fixed_us:=Time.get_ticks_usec()-began
	ok(mission.gateway("field.withdraw",{},token),"entire party withdraws")
	ok(mission.step_fixed(3,[]),"500-person retirement")
	ok(mission.request_end(hud().rules.outcome),"large battle result barrier")
	var done:Dictionary=mission.finalize()
	if ok(done,"1000-source result"):
		var rows:Array=done.value.slot_outcomes
		check(rows.size()==1000 and rows.filter(func(row):return row.end_status=="not_spawned").size()==500 and rows.filter(func(row):return row.end_status=="withdrawn").size()==250,"reserve and withdrawn source conservation")
	print("FIELD 1000 reserved, 500 humans, entities=",first.value.entities.size()," opening_us=",opened_us," tick2_us=",fixed_us)
	mission.dispose()
	site_positions=previous

func hero_and_mount()->void:
	var data:=battle(["infantry"],[1],1)
	data.spec.sides[0].commander_hero_id="hero/"+UUID
	var source:Dictionary=data.spec.reserved_sources[0]
	source.hero_id="hero/"+UUID
	source.troop_def_id=null
	source.loadout_snapshot_id="field:equipment/mounted_archer"
	var broken:=data.duplicate(true)
	broken.spec.reserved_sources[0].loadout_snapshot_id="field:troop/infantry"
	var invalid:=Mission.new(core,adapter,"custom",registry,auth,factory)
	check(not invalid.prepare(broken.spec,broken.scene,broken.rules).ok and adapter.counts().scopes==0,"unresolved hero equipment rejected before scope acquisition")
	invalid.dispose()
	if not await open(data):return
	ok(mission.step_fixed(1,[]),"open hero with explicit equipment")
	var player:Dictionary=hud().player
	check(player.role=="cavalry" and player.weapons==["melee","bow"] and player.mount_handle!=null,"hero mount and bow resolved from gear")
	var h:Dictionary=player.handle
	var old_horse:Dictionary=player.mount_handle
	check(not input(2,[{"actor_handle":h,"target_ref":"self","action":"jump"}]).ok,"scene denies jump")
	check(not input(2,[{"actor_handle":h,"target_ref":"missing","action":"interact"}]).ok,"unknown interaction rejected without ending battle")
	ok(input(2,[{"actor_handle":h,"target_ref":"self","action":"dismount"}]),"actual dismount")
	ok(mission.step_fixed(2,[]),"player dismount and same-tick MOV synchronization")
	check(hud().player.mount_handle==null and not hud().player.has("mount_heading"),"dismounted COM projection has no horse heading")
	var seen:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
	check(seen.actors.any(func(a):return a.role=="mount" and a.handle==old_horse and a.rider_handle==h),"dismounted player's own nearby mount remains identifiable")
	ok(input(3,[{"actor_handle":h,"target_ref":"field/%d/%d"%[old_horse.index,old_horse.generation],"action":"mount"}]),"remount own nearby horse")
	ok(mission.step_fixed(3,[]),"renews COM and MOV mounted profile")
	check(hud().player.mount_handle==old_horse,"same real horse generation")
	var course: Vector3=hud().player.mount_heading
	var aim := course.rotated(Vector3.UP,PI/2)
	var aim_yaw := roundi(atan2(-aim.x,-aim.z)*1000000)
	ok(input(4,[{"actor_handle":h,"yaw":aim_yaw,"pitch":0}]),"mounted rider looks to the side")
	ok(mission.step_fixed(4,[]),"commit mounted look independently of travel")
	var rider=mission._frame.projections[h.index]
	var horse=mission._frame.projections[old_horse.index]
	check(rider.pose.heading.dot(aim)>.999 and rider.body.facing.dot(aim)>.999,"rider and physical facing follow aim")
	check(horse.pose.heading.dot(course)>.999 and horse.body.facing.dot(course)>.999 and hud().player.mount_heading.dot(course)>.999,"stationary horse render, collision and steering share MOV heading")
	check(rider.combat.facing_ppm!=horse.combat.facing_ppm,"combat receives independent horse and rider facings")
	var steer := move(h)
	steer.desired_direction=[roundi(aim.x*1000000),0,roundi(aim.z*1000000)]
	ok(input(5,[steer]),"steer while keeping the same rider aim")
	ok(mission.step_fixed(5,[]),"MOV turns the horse at riding turn rate")
	var turned: Vector3=hud().player.mount_heading
	check(turned.dot(aim)>course.dot(aim)+.001 and turned.dot(aim)<.99 and mission._frame.pose[h.index].heading.dot(aim)>.999,"limited horse turn is published while rider holds aim")
	ok(mission.gateway("field.withdraw",{},token),"hero leaves")
	ok(mission.step_fixed(6,[]),"ending after cavalry participation")
	ok(mission.request_end(hud().rules.outcome),"sealed decision")
	var result:Dictionary=mission.finalize()
	if ok(result,"equipment-only hero result"):
		check(result.value.hero_outcomes.size()==1 and result.value.hero_outcomes[0].hero_id==source.hero_id and result.value.hero_outcomes[0].end_status=="withdrawn","hero identity retained")
	mission.dispose()

func checked_order(issuer:String, seq:int, kind:String, params:Dictionary, revision:int)->Dictionary:
	return {"type":"field.order","scope_id":scope,"revision":mission.view().tick,"revisions":{1:revision},"order":{
		"mission_id":scope,"issuer_id":issuer,"order_id":issuer+"-"+str(seq),"client_sequence":seq,"issued_tick":mission.view().tick+1,
		"formation_ids":[1],"order_type":kind,"target_position":null,"target_formation_id":null,"parameters":params}}

func historical_grants()->void:
	if not await open(battle(["infantry"],[1],1)):return
	ok(mission.step_fixed(1,[]),"open command authority")
	var initial:Dictionary=checked_order("player",1,"delegate",{"actor":"field-officer"},1)
	ok(mission.gateway("field.order",initial,token),"grant officer control")
	ok(mission.step_fixed(2,[]),"delegate applied")
	var old:=checked_order("field-officer",1,"layout",{"layout":"line"},2)
	ok(mission.gateway("field.order",old,officer),"officer admits own order")
	ok(mission.step_fixed(3,[]),"officer order executed")
	ok(mission.gateway("field.check_order",old,officer),"same grant may replay after advancing ticks")
	var never:=checked_order("field-officer",2,"layout",{"layout":"square"},2)
	check(not mission.gateway("field.check_order",never,officer).ok,"checking a missing order cannot enqueue")
	ok(mission.gateway("field.order",checked_order("player",2,"delegate",{"actor":""},2),token),"revoke officer")
	ok(mission.step_fixed(4,[]),"revocation published")
	check(not mission.gateway("field.check_order",old,officer).ok,"revocation invalidates old acknowledgment")
	ok(mission.gateway("field.order",checked_order("player",3,"delegate",{"actor":"field-officer"},3),token),"new distinct grant")
	ok(mission.step_fixed(5,[]),"new grant applied")
	check(not mission.gateway("field.check_order",old,officer).ok,"old order cannot replay under new grant")
	mission.dispose()

func real_jump()->void:
	var data:=battle(["infantry"],[1],1)
	data.scene.field_allow_jump=true
	data.scene.simulation_scene="res://content/base/field/river_plain.tscn"
	if not await open(data):return
	ok(mission.step_fixed(1,[]),"open authored river ground")
	var h:Dictionary=hud().player_handle
	ok(input(2,[{"actor_handle":h,"target_ref":"self","action":"jump"}]),"configured jump enters MOV")
	ok(mission.step_fixed(2,[]),"jump authority and floor sweep")
	var pos:Vector3=mission.gateway("field.view",{"projection":"camera"},token).value.position
	check(pos.y>0.03,"actual character pose leaves ground")
	var landed:=false
	for tick in range(3,100):
		if not ok(mission.step_fixed(tick,[]),"jump fixed step"):break
		var altitude:float=mission.gateway("field.view",{"projection":"camera"},token).value.position.y
		if tick>12 and altitude<0.02:
			landed=true
			break
	check(landed,"same Mission Jolt ground catches the descent")
	mission.dispose()

func casualty_wave(reserve:bool, enemy_general:=false)->void:
	var data:=battle(["infantry"],[1],1)
	if reserve:
		data.spec.reserved_sources[1].count=2
		data.spec.reserved_sources[1].source_slot_range=[1,3]
		data.spec.sides[1].roster_allocations=[{"source_slot_range":[1,3]}]
		data.scene.field_zones[1].points_mm.append([12000,0,0])
		if enemy_general:
			var starting:Dictionary=data.spec.reserved_sources[1]
			data.spec.reserved_sources.append(starting.merged({"source_slot_range":[2,3],"count":1},true))
			starting.merge({"source_slot_range":[1,2],"count":1,"troop_def_id":null,
				"hero_id":"hero/"+UUID,"loadout_snapshot_id":"field:equipment/commander"},true)
			data.spec.sides[1].commander_hero_id=starting.hero_id
	if not await open(data):return
	ok(mission.step_fixed(1,[]),"actual casualty baseline")
	if enemy_general:
		var first:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
		check(first.actors.filter(func(a):return a.team==1 and a.commander).size()==1,"true enemy general starts on the front line")
	var actor:Dictionary=hud().player_handle
	var charged:=0
	var saw_loss:=false
	var saw_rout:=false
	for tick in range(2,260):
		var state:Dictionary=hud().player
		var commands:=[]
		if state.get("phase")=="Ready":
			charged=tick
			commands.append("start")
		elif charged!=0 and tick>=charged+7 and state.get("phase")=="Hold":
			commands.append("release")
			charged=0
		if not commands.is_empty():
			if not ok(input(tick,[{"actor_handle":actor,"input_phase":commands[0],"direction":"thrust","weapon_slot":0,"target_hint":null}]),"combat command"):break
		var ran:Dictionary=mission.step_fixed(tick,[])
		if not ok(ran,"real damage through all phases"):break
		for report in ran.value.system_reports:
			if report.id=="field.combat":
				if report.value.events.any(func(e):return e.type=="downed"):saw_loss=true
				if report.value.events.any(func(e):return e.type=="routed"):saw_rout=true
		if hud().rules.outcome!=null or (reserve and ran.value.spawned_slots.size()==3):break
	check(saw_loss or (not reserve and saw_rout),"repeated real contacts cause COM incapacity or decisive rout")
	if reserve:
		check(mission.view().spawned_slots==[0,1,2] and mission.view().entities.any(func(row):return row.source_slot==2 and row.handle.generation==2),"vacancy filled by a new generation from the actual reserve")
		if enemy_general:
			ok(mission.step_fixed(mission.view().tick+1,[]),"reserved soldier actually enlists")
			var reinforced:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
			check(reinforced.actors.any(func(a):return a.team==1 and not a.commander and a.handle.generation==2) and not reinforced.actors.any(func(a):return a.commander),"retired enemy general cannot be replaced by a duplicate commander")
		ok(mission.gateway("field.withdraw",{},token),"withdraw following reinforcement")
		ok(mission.step_fixed(mission.view().tick+1,[]),"new wave participates in ending")
	else:
		check(hud().rules.outcome!=null and hud().rules.outcome.outcome=="victory","natural victory after actual incapacity")
	if hud().rules.outcome!=null:
		ok(mission.request_end(hud().rules.outcome),"trusted ending")
		var result:Dictionary=mission.finalize()
		if ok(result,"whole receipt built at barrier"):
			check(result.value.slot_outcomes[1].end_status=="wounded" and result.value.slot_outcomes[0].xp>0,"durable slot attribution after loss")
	mission.dispose()

func meeting_objective()->void:
	var previous:=site_positions.duplicate(true)
	site_positions=[[],[]]
	for side in 2:
		for k in 4:site_positions[side].append([-52000 if side==0 else 52000,0,(k-2)*1800])
	var data:=battle(["infantry","archer","cavalry","mounted_archer"],[1,1,1,1],4)
	data.scene.simulation_scene="res://content/base/field/river_plain.tscn"
	data.scene.field_sites=[{"id":"line","position":Vector3.ZERO,"objective":true}]
	if not await open(data):return
	var approach:=false
	var contact:=false
	var goal_order:=false
	var at_tick:=0
	var closest:=104.0
	for tick in range(1,1501):
		var advanced:Dictionary=mission.step_fixed(tick,[])
		if not advanced.ok:
			ok(advanced,"objective tick "+str(tick))
			break
		at_tick=tick
		for report in advanced.value.system_reports:
			if report.id=="field.combat" and report.value.hits.any(func(hit):return hit.damage>0):contact=true
		if tick%20==0:
			var v:Dictionary=mission.gateway("field.view",{"projection":"visual"},token).value
			var west:Array=v.actors.filter(func(a):return a.team==0 and a.role!="mount")
			var east:Array=v.actors.filter(func(a):return a.team==1 and a.role!="mount")
			for a in west:
				for b in east:closest=minf(closest,a.position.distance_to(b.position))
			approach=approach or closest<94
			for group in hud().formations:
				if group.active!=null and group.active.target_position==[0,0,0]:goal_order=true
		if contact or hud().rules.outcome!=null:break
	check(goal_order and approach,"genuine L2 objective order moves the opposing ranks toward the authored line")
	check(contact,"automatic objective march reaches physical combat")
	print("FIELD objective ticks=",at_tick," closest_observed_metres=",closest," real_contact=",contact)
	mission.dispose()
	site_positions=previous

func run()->void:
	var compiler:=Compiler.new()
	var compiled:=compiler.compile(compiler.scan_packages([Compiler.BASE_PACKAGE,"res://content/base/field"]),{})
	if not ok(compiled,"compiled definitions"):
		quit(1)
		return
	registry=compiled.value.registry
	adapter=EngineAdapter.new(root,true)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--brains="):
			brain_script=load(arg.trim_prefix("--brains="))
			if not check(brain_script!=null,"real brain assembly"):
				quit(1)
				return
	await field_test()
	await real_hits()
	await commander_bow()
	await nonmovement_revocation()
	await input_on_incapacitation()
	await replace_expired_batch()
	await historical_grants()
	if "--casualties" in OS.get_cmdline_user_args():
		await casualty_wave(false)
		await casualty_wave(true)
		await casualty_wave(true,true)
	if "--mount" in OS.get_cmdline_user_args():
		await hero_and_mount()
		await real_jump()
	if "--large" in OS.get_cmdline_user_args():await large_field()
	if "--objective" in OS.get_cmdline_user_args():await meeting_objective()
	check(adapter.counts().scopes==0,"released field scopes")
	check(checks>=35 and action_contacts>0,"all mandatory scenario entry points reached")
	print("P2-FIELD-INTEGRATION-006 ","PASS" if failed==0 else "FAIL"," checks=",checks," failures=",failed," confirmed_contacts=",action_contacts," real_brains=",brain_script!=null)
	quit(0 if failed==0 else 1)
