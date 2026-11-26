extends RefCounted

const Field = preload("res://mission/combat/ports/field_combat.gd")
const R = preload("res://contracts/result.gd")
const A := {"index":0,"generation":1}
const B := {"index":1,"generation":1}
const M := {"index":2,"generation":1}
const SCOPE := "combat-field-physics"
var adapter: RefCounted
var check: Callable
var target := B.duplicate()
var batches := 0
var queries := 0


func attack(phase: String, slot := 1) -> Dictionary:
	return {"actor_handle":A,"input_phase":phase,"weapon_slot":slot,"direction":"up","target_hint":null}


func guard(direction: String) -> Dictionary:
	return {"actor_handle":B,"held":true,"direction":direction}


func poses(lane: int, facing := -1000000) -> Dictionary:
	return {0:{"position_mm":[0,0,lane],"facing_ppm":[1000000,0,0]},
		1:{"position_mm":[2500,0,lane],"facing_ppm":[facing,0,0]},2:{"position_mm":[2400,0,lane],"facing_ppm":[facing,0,0]}}


func physics(requests: Array, tick: int) -> Dictionary:
	batches += 1
	queries += requests.size()
	var result: Dictionary = adapter.query_sweep_batch(requests, {"scope_id":SCOPE,"tick":tick})
	if not result.ok:
		return result
	var hits := []
	for shape: Dictionary in result.value:
		var hit := {"query_index":shape.query_index, "fraction_ppm":shape.fraction_ppm, "region":shape.region}
		if shape.entity_handle == "foe":
			hit.target = target
		elif shape.entity_handle == "mounted_horse":
			hit.target = M
		hits.append(hit)
	hits.reverse() # Physics backend traversal order must not change occlusion.
	return R.ok(hits)


func field(kind := "bow", ammo := 3, armor := {}, shield := 0) -> RefCounted:
	var sim := Field.new()
	check.call(sim.enlist(A,{"team":1,"role":"archer","ranged":kind,"ammo":ammo}).ok, "enlist ranged")
	check.call(sim.enlist(B,{"team":2,"role":"infantry","armor":armor,"shield":shield}).ok, "enlist target")
	return sim


func shot(sim: RefCounted, lane: int, guard_dir := "", facing := -1000000, retire := false) -> Array:
	var hits := []
	for tick in range(1,8):
		var intents := []
		if tick == 1 or tick == 4:
			intents.append(attack("start" if tick == 1 else "release"))
		if tick == 4 and not guard_dir.is_empty():
			intents.append(guard(guard_dir))
		var r: Dictionary = sim.step_field(tick,intents,poses(lane,facing),physics)
		check.call(r.ok,"advance live field tick %d"%tick)
		if not r.ok:
			return []
		for receipt in r.value.receipts:
			check.call(receipt.ok, "legal ranged or guard receipt")
		hits.append_array(r.value.hits)
		if retire and tick == 4:
			check.call(r.value.projectiles == 1 and sim.remove_actor(A).ok,"remove shooter after release")
		if target == M and r.value.events.any(func(e): return e.type == "dismounted"):
			check.call(sim.view(B).value.phase == "Stagger" and sim.view(B).value.hp == 10,"disabled mount staggers living rider on impact tick")
	return hits


func missiles() -> bool:
	for kind: String in ["bow","crossbow","throw"]:
		var sim := field(kind)
		var hits := shot(sim,0)
		var power: int = {"bow":16,"crossbow":20,"throw":12}[kind]
		check.call(hits.size() == 1 and sim.view(B).value.hp == 100-power and sim.view(A).value.ammo == 2,"real swept %s hit and single debit"%kind)
		var wall := field(kind)
		check.call(shot(wall,3000).is_empty() and wall.view(B).value.hp == 100,"thin obstacle precedes target for "+kind)
	var gone := field()
	check.call(shot(gone,0,"",-1000000,true).size() == 1 and gone.view(B).value.hp == 84,"airborne projectile survives shooter removal")
	var empty := field("crossbow",0)
	var denied: Dictionary = empty.step_field(1,[attack("start")],poses(0),physics)
	check.call(not denied.value.receipts[0].ok and empty.view(A).value.phase == "Ready","empty ammo rejects start")
	var reload := field("crossbow")
	shot(reload,0)
	for tick in range(8,20):
		var inputs := [attack("start")] if tick == 9 else []
		var r: Dictionary = reload.step_field(tick,inputs,poses(0),physics)
		if tick == 9:
			check.call(not r.value.receipts[0].ok and r.value.receipts[0].error.field == "reload","crossbow reload window")
	var ready: Dictionary = reload.step_field(20,[attack("start")],poses(0),physics)
	check.call(ready.value.receipts[0].ok, "reload completed on fixed tick")
	var pending := field()
	for tick in [1,2,3]:
		pending.step_field(tick,[attack("start")] if tick == 1 else [],poses(0),physics)
	var before: Dictionary = pending.view(A).value
	var fail: Dictionary = pending.step_field(4,[attack("release")],poses(0),func(_q,_t): return R.ok([{"query_index":55,"fraction_ppm":0}]))
	check.call(not fail.ok and pending.view(A).value == before and not pending.has_pending_projectiles(),"invalid sweep rolls back shot and ammo")
	pending.step_field(4,[attack("release")],poses(0),physics)
	var branch: RefCounted = pending.fork()
	branch.step_field(5,[],poses(0),physics)
	check.call(pending.has_pending_projectiles() and pending.view(B).value.hp == 100 and not branch.has_pending_projectiles() and branch.view(B).value.hp == 84,"mid-flight fork independent")
	return true


func protection() -> bool:
	var captain:=Field.new(SCOPE)
	captain.enlist(A,{"role":"infantry","team":1,"action_profile":"commander"})
	var trace:=[]
	var record:=func(lines,_tick):
		trace.append(lines[0].from[2])
		return R.ok([])
	for tick in range(1,14):
		var intents:=[]
		if tick in [1,10]:
			intents.append(attack("start" if tick==1 else "release",0).merged({"direction":"left"},true))
		captain.step_field(tick,intents,poses(0),record)
	check.call(trace==[330,110,-110,-330],"commander side swing crosses the four authoritative active samples")
	var sim := field("bow",1,{},10)
	var hits := shot(sim,6000,"up")
	check.call(hits.size() == 1 and hits[0].blocked and hits[0].shield_broken and sim.view(B).value.shield == 0 and sim.view(B).value.hp == 100,"directional shield intercepts and breaks")
	for args in [["left",-1000000],["up",1000000]]:
		var wrong := field("bow",1,{},10)
		var missed := shot(wrong,6000,args[0],args[1])
		check.call(missed.size() == 1 and not missed[0].blocked and wrong.view(B).value.hp == 84 and wrong.view(B).value.shield == 10,"shield direction and facing coverage")
	for args in [[0,"body",100,8],[9000,"head",300,8]]:
		var protected := field("bow",1,{"body":100,"head":300})
		var impact := shot(protected,args[0])
		check.call(impact.size() == 1 and impact[0].breakdown.zone == args[1] and impact[0].breakdown.armor == args[2] and impact[0].damage == args[3],"zone multiplier and armor breakdown")
	var gear := field()
	var equip := {"actor_handle":A,"slot":0,"item_ref":"melee"}
	var first: Dictionary = gear.step_field(1,[{"actor_handle":A,"slot":1,"item_ref":"forged"},equip,attack("start",0)],poses(12000),physics)
	check.call(not first.value.receipts[0].ok and first.value.receipts[1].ok and first.value.receipts[2].ok and gear.view(A).value.weapon_slot == 0,"inventory-bound weapon switch")
	for tick in [2,3,4,5]:
		gear.step_field(tick,[attack("release",0)] if tick == 4 else [],poses(12000),physics)
	check.call(gear.view(B).value.hp == 90 and gear.view(A).value.ammo == 3,"field melee real sweep and dedup")
	return true


func cavalry() -> bool:
	for fallen: Dictionary in [M,B]:
		var sim := Field.new()
		sim.enlist(A,{"team":1,"role":"archer"})
		sim.enlist(B,{"team":2,"role":"cavalry","hp":10})
		sim.enlist(M,{"team":2,"role":"mount","hp":10})
		check.call(sim.mount(B,M).ok and not sim.mount(B,M).ok and sim.dismount(B).ok and sim.mount(B,M).ok,"reciprocal mount, conflict and dismount")
		target = fallen
		shot(sim,0)
		var rider: Dictionary = sim.view(B).value
		var horse: Dictionary = sim.view(M).value
		check.call(rider.mount_handle == null and horse.rider_handle == null and sim.view(fallen).value.phase == "Downed","independent fall detaches")
		check.call(horse.hp == (0 if fallen == M else 10) and rider.hp == (10 if fallen == M else 0),"horse and rider hp independent")
	target = B.duplicate()
	var charge := Field.new()
	charge.enlist(A,{"team":1,"role":"cavalry"})
	charge.enlist(M,{"team":1,"role":"mount"})
	charge.enlist(B,{"team":2,"role":"infantry"})
	charge.mount(A,M)
	var charging := poses(12000)
	charging[0].speed_mm_tick = 9000
	for tick in range(1,5):
		var input := [attack("start",0)] if tick == 1 else ([attack("release",0)] if tick == 4 else [])
		var r: Dictionary = charge.step_field(tick,input,charging,physics)
		if tick == 4:
			check.call(r.value.hits.size() == 1 and r.value.hits[0].breakdown.mount_bonus == 5 and charge.view(B).value.hp == 85,"mounted approach bonus capped")
	return true


func mounted_field() -> RefCounted:
	var sim := Field.new()
	sim.enlist(A,{"team":1,"role":"cavalry"})
	sim.enlist(M,{"team":1,"role":"mount","hp":10})
	sim.enlist(B,{"team":2,"role":"infantry"})
	check.call(sim.mount(A,M).ok,"impact rider attached")
	return sim


func mounted_poses(x: int) -> Dictionary:
	var map := poses(12000)
	map[0].position_mm = [0,0,12000]
	map[1].position_mm = [1000,0,12000]
	map[2] = {"position_mm":[x,0,12000],"facing_ppm":[1000000,0,0]}
	return map


func mount_impact() -> bool:
	var sim := mounted_field()
	sim.step_field(1,[],mounted_poses(0),physics)
	var rejected: Dictionary = sim.step_field(2,[],mounted_poses(850),func(_q,_t): return R.fail("Unavailable","test"))
	check.call(not rejected.ok and sim.view(B).value.hp == 100,"failed mount sweep rolls back motion")
	var branch: RefCounted = sim.fork()
	var r: Dictionary = sim.step_field(2,[],mounted_poses(850),physics)
	check.call(r.ok and r.value.hits.size() == 1 and r.value.hits[0].kind == "mount_impact" and r.value.hits[0].attacker == M and sim.view(B).value.hp == 84,"horse body hits with no attack intent")
	var replay: Dictionary = branch.step_field(2,[],mounted_poses(850),physics)
	check.call(replay == r,"independent fork reproduces mount impact")
	var positions := [930,930,1090,1500,2400,-1000,920]
	for i in positions.size():
		var step: Dictionary = sim.step_field(i+3,[],mounted_poses(positions[i]),physics)
		check.call(step.ok and step.value.hits.size() == (1 if i == 6 else 0), "ongoing contact deduplicates; reentry after separation rearms")
	check.call(sim.view(B).value.hp == 68,"exactly two separate impacts")
	for route in [[1200,800],[700,740],[900,900]]:
		var quiet := mounted_field()
		quiet.step_field(1,[],mounted_poses(route[0]),physics)
		var second: Dictionary = quiet.step_field(2,[],mounted_poses(route[1]),physics)
		check.call(second.ok and second.value.hits.is_empty() and quiet.view(B).value.hp == 100,"backwards, below threshold or stationary movement")
	var together := mounted_field()
	for tick in range(1,5):
		var inp := [attack("start",0)] if tick == 1 else ([attack("release",0)] if tick == 4 else [])
		var step: Dictionary = together.step_field(tick,inp,mounted_poses(850 if tick == 4 else 0),physics)
		if tick == 4:
			check.call(step.value.hits.size() == 2 and together.view(B).value.hp == 74,"weapon swing and body impact independently resolve in one tick")
	var mutual := mounted_field()
	var archer := {"index":3,"generation":1}
	mutual.enlist(archer,{"team":2,"role":"archer","ranged":"crossbow"})
	for tick in range(1,5):
		var state := mounted_poses(850 if tick == 4 else 0)
		state[3] = {"position_mm":[0,0,15000],"facing_ppm":[1000000,0,0]}
		var inputs := []
		if tick == 1 or tick == 4:
			var cmd := attack("start" if tick == 1 else "release")
			cmd.actor_handle = archer
			inputs.append(cmd)
		var step: Dictionary = mutual.step_field(tick,inputs,state,physics)
		if tick == 4:
			check.call(step.value.hits.size() == 2 and mutual.view(M).value.phase == "Downed" and mutual.view(A).value.mount_handle == null and mutual.view(B).value.hp == 84,"horse can collide on same tick it falls")
	return true


func initial_morale() -> bool:
	for value in [0,25,26]:
		var sim := Field.new()
		sim.enlist(A,{"team":1,"role":"infantry","morale":value})
		sim.enlist(B,{"team":1,"role":"infantry"})
		check.call(sim.view(A).value.routing == (value <= 25),"initial route threshold")
		var one: Dictionary = sim.step_field(1,[attack("start",0)],poses(0),physics)
		check.call(one.value.receipts[0].ok == (value > 25),"initially routed actor cannot attack")
		var routed: Array = one.value.events.filter(func(e): return e.type=="routed")
		check.call(routed.size() == (1 if value <= 25 else 0) and sim.view(B).value.morale == (64 if value <= 25 else 70),"initial route announced and propagated exactly once")
		if value <= 25:
			var two: Dictionary = sim.step_field(2,[],poses(0),physics,[{"actor_handle":A,"delta":54-value}])
			check.call(sim.view(A).value.routing and two.value.events.is_empty(),"54 retains routed state")
			var three: Dictionary = sim.step_field(3,[],poses(0),physics,[{"actor_handle":A,"delta":1}])
			check.call(not sim.view(A).value.routing and three.value.events[0].type == "regrouped","55 regroups")
	return true


func authority_replay(render_hz: int, from_ai: bool) -> String:
	var sim := field("crossbow",1)
	var history := []
	var tick := 0
	var accumulator := 0
	while tick < 12:
		accumulator += 60
		while accumulator >= render_hz and tick < 12:
			accumulator -= render_hz
			tick += 1
			var input := []
			if tick == 1 or tick == 4:
				var phase := "start" if tick == 1 else "release"
				# Both input producers only know the frozen intent and an optional hint.
				var intent := attack(phase)
				if from_ai:
					intent = {"target_hint":B, "weapon_slot":1,"direction":"up","input_phase":phase,"actor_handle":A}
				input.append(intent)
			var r: Dictionary = sim.step_field(tick,input,poses(0),physics)
			check.call(r.ok,"field replay tick")
			history.append([r.value,sim.view(A).value,sim.view(B).value])
	check.call(sim.view(B).value.hp == 80,"real crossbow replay damage")
	var digest := preload("res://contracts/canonical.gd").hash_value(history)
	check.call(digest.ok,"canonical field replay history")
	return digest.get("value","")


func authority() -> bool:
	var solo := field()
	var forged := {"actor_handle":A, "target":B, "damage":1000}
	var bad: Dictionary = solo.step_field(1,[attack("start"), forged],poses(0),physics)
	check.call(not bad.ok and solo.view(A).value.phase == "Ready" and solo.view(B).value.hp == 100,"direct hit injection rejected atomically")
	var one: Dictionary = solo.step_field(1,[attack("start"),attack("start")],poses(0),physics)
	check.call(one.value.receipts[0].ok and not one.value.receipts[1].ok,"duplicate action rejected")
	check.call(not solo.step_field(1,[attack("start")],poses(0),physics).ok,"duplicate tick rejected")
	var digest := authority_replay(30,false)
	var replay := authority_replay(144,true)
	check.call(digest.length() == 64 and digest == replay,"player and AI intent fixtures produce identical live physics trace")
	print("COM field 30/144 Hz replay_sha256=",digest)
	return true


func morale() -> bool:
	var sim := Field.new()
	var positions := {}
	for i in range(10):
		var h := {"index":i,"generation":1}
		sim.enlist(h,{"team":1 if i != 7 else 2,"role":"infantry","commander":i==0})
		positions[i] = {"position_mm":[25000 if i == 8 else i*100,0,0],"facing_ppm":[1000000,0,0]}
	var one: Dictionary = sim.step_field(1,[],positions,physics,[{"actor_handle":A,"delta":-60}])
	var spreads: Array = one.value.events.filter(func(e): return e.type == "morale_spread")
	check.call(sim.view(A).value.routing and one.value.events[0].type == "routed" and spreads.size() == 4 and sim.view(B).value.morale == 58,"commander route emits feedback and has bounded local spread")
	check.call(sim.view({"index":7,"generation":1}).value.morale == 70 and sim.view({"index":8,"generation":1}).value.morale == 70,"no cross-side or distant spread")
	var two: Dictionary = sim.step_field(2,[attack("start",0)],positions,physics,[{"actor_handle":{"index":5,"generation":1},"delta":-60}])
	check.call(not two.value.receipts[0].ok and sim.view(B).value.morale == 58, "routing forbids action and spread cooldown limits neighbors")
	var three: Dictionary = sim.step_field(3,[],positions,physics,[{"actor_handle":A,"delta":70}])
	check.call(not sim.view(A).value.routing and three.value.events.any(func(e): return e.type == "regrouped"),"rally and regroup feedback")
	var bad: Dictionary = sim.step_field(4,[],positions,physics,[{"actor_handle":{"index":0,"generation":2},"delta":-100}])
	check.call(not bad.ok and sim.step_field(4,[],positions,physics).ok,"stale morale source cannot change tick")
	return true


func crowd() -> bool:
	for size in [500,1000]:
		var sim := Field.new()
		var positions := {}
		var initial := []
		var releases := []
		for i in size:
			var h := {"index":i,"generation":1}
			sim.enlist(h,{"team":i%2,"role":"infantry"})
			positions[i] = {"position_mm":[i*5000,0,0], "facing_ppm":[1000000,0,0]}
			if i%10 == 0:
				var start := attack("start",0)
				start.actor_handle = h
				initial.append(start)
				var release := start.duplicate()
				release.input_phase = "release"
				releases.append(release)
		var samples := []
		var swept := [0]
		for tick in range(1,61):
			var inputs: Array = initial if tick == 1 else (releases if tick == 4 else [])
			var begin := Time.get_ticks_usec()
			var r: Dictionary = sim.step_field(tick,inputs,positions,func(q,_t):
				swept[0] += q.size()
				return R.ok([]))
			samples.append(Time.get_ticks_usec()-begin)
			check.call(r.ok, "crowd fixed tick")
		samples.sort()
		check.call(swept[0] == 2*initial.size(),"crowd batches cover every active swing")
		print("COM crowd actors=",size," ticks=60 synthetic_sweeps=",swept[0]," p95_us=",samples[56]," max_us=",samples[-1])
	return true


func run(tree: SceneTree, engine: RefCounted, assert_fn: Callable) -> bool:
	adapter = engine
	check = assert_fn
	var token: Dictionary = adapter.open_scope(SCOPE)
	check.call(token.ok and adapter.load_scene({"id":"test:scene/field", "simulation_scene":"res://tests/p2/combat/field.tscn"},token.value).ok,"load real field")
	await tree.physics_frame
	await tree.physics_frame
	for test: Callable in [missiles, protection, cavalry, mount_impact, initial_morale, authority, morale, crowd]:
		check.call(test.call() == true, "completed field case " + str(test.get_method()))
	adapter.release_scope(SCOPE)
	print("COM field physics batches=",batches," queries=",queries)
	return true
