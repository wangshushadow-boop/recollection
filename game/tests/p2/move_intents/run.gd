extends SceneTree
const Field = preload("res://mission/movement/ports/field_movement.gd")
const Adapter = preload("res://infrastructure/engine/adapter.gd")
const SCOPE := "move-intent-field"
const DT := 1.0/60
const RIGHT := [1000000,0,0]
var failures := 0
var checks := 0
var player := RefCounted.new()
var ai := RefCounted.new()
var permitted := true
var player_index := -1
var engine: RefCounted
var meter: Meter

class Meter:
	var engine: RefCounted
	var queries := 0
	var sweeps := 0
	var on_sweep: Callable
	func sync_navigation(scope: String) -> Dictionary:
		return engine.sync_navigation(scope)
	func query_path_batch(rows: Array,revision: int,scope: String) -> Dictionary:
		queries += rows.size()
		return engine.query_path_batch(rows,revision,scope)
	func query_sweep_batch(rows: Array,stamp: Dictionary) -> Dictionary:
		sweeps += rows.size()
		if on_sweep.is_valid(): on_sweep.call()
		return engine.query_sweep_batch(rows,stamp)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL ",label)

func authorize(scope: String,actor: Dictionary,context: Variant,_tick: int) -> bool:
	return scope==SCOPE and permitted and (is_same(context,ai) or (is_same(context,player) and (player_index<0 or player_index==actor.index)))

func handle(i: int,generation:=1) -> Dictionary:
	return {"index":i,"generation":generation}

func move(i: int,fraction:=1.0,direction:=RIGHT,stance: Variant=null) -> Dictionary:
	return {"actor_handle":handle(i),"desired_direction":direction,"speed_fraction":fraction,"stance":stance}

func enqueue(field: Field,tick: int,input: Dictionary,owner: Variant) -> Dictionary:
	var opened := field.begin_step(tick)
	check(opened.ok,"open tick %d"%tick)
	if not opened.ok: return opened
	var accepted := field.apply_move_intent(opened.value,input,owner)
	if not accepted.ok:
		field.rollback_step(opened.value)
		return accepted
	return field.stage_step(tick,DT,opened.value)

func commit(field: Field,tick: int,input: Dictionary,owner: Variant) -> bool:
	var stage := enqueue(field,tick,input,owner)
	return stage.ok and field.commit_step(stage.value.stage_token).ok

func wait_nav() -> bool:
	for frame in 120:
		await physics_frame
		var sync: Dictionary = engine.sync_navigation(SCOPE)
		if sync.ok and sync.value.status=="applied":
			var probe: Dictionary = engine.query_path_batch([{"from":[-10000,0,0],"to":[-8000,0,0]}],sync.value.applied_revision,SCOPE)
			if probe.ok and probe.value[0].reachable: return true
	return false

func arena(scene: String) -> bool:
	var opened: Dictionary = engine.open_scope(SCOPE)
	return opened.ok and engine.load_scene({"id":"base:scene/move_intents","simulation_scene":scene},opened.value).ok and await wait_nav()

func transactions() -> void:
	var p := Field.new(meter,SCOPE,authorize)
	var n := Field.new(meter,SCOPE,authorize)
	var origin := Vector3(-25,0,8)
	for field in [p,n]: check(field.spawn(handle(0),origin).ok,"fresh actor")
	var roster := p.bind_roster([handle(0)]).value as RefCounted
	var input := move(0,.5)
	var before := meter.queries
	var proposed := enqueue(p,0,input,player)
	if not proposed.ok:
		check(false,"first accepted candidate "+str(proposed))
		return
	var token: RefCounted = proposed.value.stage_token
	var pose := p.read_poses(roster,token).value as Dictionary
	check(pose.positions[0].x>origin.x and absf(pose.velocities[0].length()-1.7)<.001 and p.read_positions(roster).value[0]==origin,"half speed in staged roster only")
	check(p.rollback_step(token).ok and p.read_positions(roster).value[0]==origin and not p.read_poses(roster,token).ok,"rollback discards movement and stage token")
	check(commit(p,0,input,player) and meter.queries==before+1,"same-tick retry reuses the native path")
	check(commit(n,0,input,ai) and n.view(handle(0))==p.view(handle(0)),"identical player / L3 authoritative pose")
	var cached := meter.queries
	for tick in range(1,12):
		check(p.step(tick,DT).ok and n.step(tick,DT).ok and p.view(handle(0))==n.view(handle(0)),"held command stays equivalent")
	check(meter.queries==cached,"steady heading reuses its certified segment")
	var prior: Vector3 = p.view(handle(0)).value.position
	check(commit(p,12,move(0,0,[0,0,0]),player) and p.view(handle(0)).value.position==prior and p.view(handle(0)).value.velocity==Vector3.ZERO,"explicit foot stop")
	var stage: RefCounted = p.begin_step(13).value
	var changed := move(0,1.0,[0,0,1000000],"crouch")
	check(not p.apply_move_intent(RefCounted.new(),changed,player).ok,"foreign stage")
	check(p.apply_move_intent(stage,changed,RefCounted.new()).error.code=="Unauthorized" and p.apply_move_intent(stage,changed,ai).ok,"credible control context")
	changed.desired_direction[2] = -1000000
	check(p.stage_step(13,DT,stage).ok and p.view(handle(0),stage).value.velocity.z>1,"new direction and gait; caller cannot mutate admitted intent")
	check(p.commit_step(stage).ok,"publish turn")
	before = meter.queries
	var turn := move(0,1.0,[-1000000,0,0])
	meter.on_sweep = func(): permitted=false
	check(commit(p,14,turn,ai) and p.view(handle(0)).value.velocity==Vector3.ZERO and p.view(handle(0)).value.blocked=="control_revoked","authority revoked during real physics")
	meter.on_sweep = Callable()
	permitted = true
	prior = p.view(handle(0)).value.position
	check(p.step(15,DT).ok and p.view(handle(0)).value.position==prior,"restored grant does not replay revoked command")
	for owner in [player,ai]:
		var s: RefCounted = p.begin_step(16).value
		check(p.apply_move_intent(s,move(0,1.2),owner).error.code=="InvalidArgument" and p.apply_move_intent(s,move(0,.9,[0,0,0]),owner).error.code=="InvalidArgument","same invalid input errors")
		for patch in [{"desired_direction":[0,true,0]},{"desired_direction":[1.0,0,0]},{"desired_direction":[2147483648,0,0]},{"speed_fraction":NAN},{"speed_fraction":true},{"extra":0},{"stance":&"walk"}]:
			var malformed := input.duplicate(true)
			malformed.merge(patch,true)
			check(p.apply_move_intent(s,malformed,owner).error.code=="InvalidArgument","reject non-v1 field")
		var missing := input.duplicate(true)
		missing.erase("stance")
		check(not p.apply_move_intent(s,missing,owner).ok,"required nullable v1 field")
		check(p.rollback_step(s).ok,"discard invalid input")
	player_index = 78
	check(enqueue(p,16,input,player).error.code=="Unauthorized","valid controller cannot steer a foreign actor")
	player_index = -1
	stage = p.begin_step(16).value
	check(p.despawn(handle(0),stage).ok and p.apply_move_intent(stage,input,ai).error.code=="NotFound","retired generation denied")
	check(p.spawn(handle(0,2),origin,"foot",Vector3.FORWARD,stage).ok and not p.read_poses(roster,stage).ok and p.apply_move_intent(stage,input,player).error.code=="NotFound","replacement cannot inherit retired drive")
	check(p.rollback_step(stage).ok and p.read_poses(roster).ok and p.view(handle(0)).value.position==prior,"abandoned despawn restores original birth")
	var closed := Field.new(meter,SCOPE)
	closed.spawn(handle(0),origin)
	stage = closed.begin_step(0).value
	check(closed.apply_move_intent(stage,input,ai).error.code=="Unauthorized","no resolver fails closed")
	closed.rollback_step(stage)

func commit_authority() -> void:
	var field := Field.new(meter,SCOPE,authorize)
	for i in 2: field.spawn(handle(i),Vector3(-26,0,4+i*2))
	var roster: RefCounted = field.bind_roster([handle(0),handle(1)]).value
	var before := field.read_poses(roster)
	var stage: RefCounted = field.begin_step(0).value
	check(field.apply_move_intent(stage,move(0),ai).ok and field.apply_move_intent(stage,move(1),player).ok,"two separately authorized drivers")
	check(field.stage_step(0,DT,stage).ok and field.read_poses(roster,stage)!=before,"both candidate poses advance")
	player_index = 0
	var rejected := field.commit_step(stage)
	check(not rejected.ok and rejected.error.code=="Unauthorized" and field.read_poses(roster)==before,"last driver revoked; whole committed roster is unchanged")
	check(not field.read_poses(roster,stage).ok and not field.commit_step(stage).ok,"denied publication discards the candidate")
	player_index = -1
	check(commit(field,0,move(1),player),"a fresh same-tick submission succeeds")

	var audit := {"checks":0,"reject":true}
	var resolver := func(_scope: String,_actor: Dictionary,_context: Variant,tick: int):
		if tick!=1: return true
		audit.checks+=1
		return not (audit.reject and audit.checks==2)
	var retained := Field.new(meter,SCOPE,resolver)
	retained.spawn(handle(0),Vector3(-28,0,8))
	check(commit(retained,0,move(0),player),"establish an authorized held input")
	var saved := retained.view(handle(0))
	var failed := retained.step(1,DT)
	check(not failed.ok and failed.error.code=="Unauthorized" and retained.view(handle(0))==saved,"step propagates the publication error and rolls back")
	audit.reject = false
	check(retained.step(1,DT).ok and retained.view(handle(0)).value.position.x>saved.value.position.x,"step can retry the rejected tick")

func actor_colliders() -> void:
	var field := Field.new(meter,SCOPE,authorize)
	var origin := Vector3(-20,0,-6)
	field.spawn(handle(0),origin)
	field.spawn(handle(1),origin+Vector3.RIGHT*2)
	var body := StaticBody3D.new()
	body.collision_layer = 2
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = .32
	shape.shape = capsule
	body.add_child(shape)
	body.position = origin+Vector3.UP*.9
	get_first_node_in_group("ai_test_wall").get_parent().add_child(body)
	await physics_frame
	await physics_frame
	check(commit(field,0,move(0),player),"real own hurtbox accepts movement")
	for tick in range(1,65): check(field.step(tick,DT).ok,"actor-space movement")
	var actor := field.view(handle(0)).value as Dictionary
	check(actor.position.x>origin.x+1 and actor.position.distance_to(field.view(handle(1)).value.position)>=.56 and actor.blocked=="yield","own capsule is ignored; a neighbouring actor still stops movement")
	body.free()

func wall_and_horse() -> void:
	var wall := Field.new(meter,SCOPE,authorize)
	wall.spawn(handle(0),Vector3(-3,0,0))
	check(commit(wall,0,move(0),player),"wall approach")
	for tick in range(1,120): check(wall.step(tick,DT).ok,"wall tick")
	var at: Vector3 = wall.view(handle(0)).value.position
	check(at.x> -1 and at.x<-.47 and wall.view(handle(0)).value.velocity==Vector3.ZERO,"solid Jolt wall blocks route on open navigation mesh")
	var body := get_first_node_in_group("ai_test_wall") as StaticBody3D
	var revision: int = engine.sync_navigation(SCOPE).value.applied_revision
	body.position.z = 18
	await physics_frame
	await physics_frame
	for tick in range(120,150): check(wall.step(tick,DT).ok,"wall opens")
	check(wall.view(handle(0)).value.position.x>1,"vacated path resumes without new intent")
	body.position = Vector3(2.2,1,0)
	await physics_frame
	await physics_frame
	for tick in range(150,190): check(wall.step(tick,DT).ok,"wall closes again")
	check(engine.sync_navigation(SCOPE).value.applied_revision==revision and wall.view(handle(0)).value.position.x<1.75 and wall.view(handle(0)).value.blocked=="scene","a new physical barrier invalidates clearance without nav revision")
	body.position = Vector3(0,1,0)
	await physics_frame
	await physics_frame
	var horse := Field.new(meter,SCOPE,authorize)
	horse.spawn(handle(0),Vector3(-30,0,8),"mounted",Vector3.RIGHT)
	check(commit(horse,0,move(0,.5,RIGHT,"sprint"),ai),"horse accepts same intent")
	for tick in range(1,95): check(horse.step(tick,DT).ok,"accelerate")
	var fast: float = horse.view(handle(0)).value.velocity.length()
	check(absf(fast-4.5)<.005,"horse half-speed cap")
	var turning := enqueue(horse,95,move(0,1,[-1000000,0,0]),ai)
	var turning_pose := horse.view(handle(0),turning.value.stage_token).value as Dictionary
	check(turning_pose.velocity.x>4 and turning_pose.velocity.x<fast and turning_pose.heading.dot(Vector3.RIGHT)>.99 and horse.rollback_step(turning.value.stage_token).ok,"reversing a moving rider brakes on the old certified strip")
	check(commit(horse,95,move(0,0,[0,0,0]),ai),"request stop")
	var brake: float = horse.view(handle(0)).value.velocity.length()
	check(brake>0 and brake<fast and absf(fast-brake-8*DT)<.005,"certified mounted braking distance")
	for tick in range(96,140): check(horse.step(tick,DT).ok,"brake to rest")
	check(horse.view(handle(0)).value.velocity==Vector3.ZERO,"mounted stop completed")
	check(commit(horse,140,move(0,1.0,[-1000000,0,0]),ai) and horse.view(handle(0)).value.heading.dot(Vector3.RIGHT)>.99,"horse cannot snap backwards")
	print("MOVE_JOLT wall_x=",at.x," rider_v=",fast," braking_v=",brake)

func riding_curve() -> void:
	var horse := Field.new(meter,SCOPE,authorize)
	horse.spawn(handle(0),Vector3(-30,0,8),"mounted",Vector3.RIGHT)
	check(commit(horse,0,move(0,.6),player),"start mounted gait")
	for tick in range(1,95): check(horse.step(tick,DT).ok,"reach cruising speed")
	var tick := 95
	for sign_value in [1.0,-1.0]:
		var start := horse.view(handle(0)).value as Dictionary
		var pose := start
		var min_speed := INF
		var queried := meter.queries
		var within_limit := true
		for frame in 60:
			var heading: Vector3 = pose.heading
			var speed: float = pose.velocity.length()
			var desired := heading.rotated(Vector3.UP,sign_value*deg_to_rad(2.5))
			if not commit(horse,tick,move(0,.6,[roundi(desired.x*1000000),0,roundi(desired.z*1000000)]),player):
				check(false,"steering intent accepted")
				return
			pose = horse.view(handle(0)).value
			min_speed = minf(min_speed,pose.velocity.length())
			within_limit = within_limit and heading.angle_to(pose.heading)<=3.0*DT/(1+.22*speed)+.0001
			tick += 1
		var yaw := rad_to_deg((start.heading as Vector3).signed_angle_to(pose.heading,Vector3.UP))
		var displacement: float = start.position.distance_to(pose.position)
		check(yaw*sign_value>55 and displacement>4.0 and min_speed>5.0,"held steering keeps gait through a moving arc in both directions")
		check(meter.queries>queried and within_limit,"moving curve uses verified strips and obeys its speed-dependent turn rate")
		print("MOVE_RIDING_CURVE yaw_deg=",yaw," displacement_m=",displacement," min_speed_mps=",min_speed)

func gated() -> void:
	var bridge := Field.new(meter,SCOPE,authorize)
	bridge.spawn(handle(0),Vector3(-8,0,0))
	check(commit(bridge,0,move(0),player),"open bridge admission")
	var previous: Vector3 = bridge.view(handle(0)).value.position
	check(engine.apply_nav_links([{"link_id":"bridge","enabled":false}],SCOPE).ok,"close bridge")
	var pending := bridge.step(1,DT)
	check(not pending.ok and pending.error.code=="Unavailable" and bridge.view(handle(0)).value.position==previous,"pending map cannot publish old strip")
	check(await wait_nav(),"closed bridge synchronized")
	for tick in range(1,250): check(bridge.step(tick,DT).ok,"closed bridge step")
	var blocked: Vector3 = bridge.view(handle(0)).value.position
	check(blocked.x<.01 and bridge.view(handle(0)).value.velocity==Vector3.ZERO,"cannot cross disconnected bank")
	check(engine.apply_nav_links([{"link_id":"bridge","enabled":true}],SCOPE).ok and await wait_nav(),"restore link")
	for tick in range(250,520): check(bridge.step(tick,DT).ok,"restored bridge step")
	check(bridge.view(handle(0)).value.position.x>3,"certified route crosses reopened bridge")
	var rider := Field.new(meter,SCOPE,authorize)
	rider.set_terrain([{"bounds":AABB(Vector3(-2,-1,-.7),Vector3(7,2,1.4)),"profiles":["foot"]}])
	rider.spawn(handle(0),Vector3(-8,0,0),"mounted",Vector3.RIGHT)
	check(commit(rider,0,move(0),ai),"mounted approach to restricted passage")
	for tick in range(1,190): check(rider.step(tick,DT).ok,"foot-only gate step")
	check(rider.view(handle(0)).value.position.x< -2 and rider.view(handle(0)).value.blocked=="yield","profile denies doorway")
	var narrow := Field.new(meter,SCOPE,authorize)
	narrow.set_terrain([{"bounds":AABB(Vector3(-7.95,-1,-.04),Vector3(.10,2,.08)),"profiles":["foot"]}])
	narrow.spawn(handle(0),Vector3(-8,0,0))
	var stage: RefCounted = narrow.begin_step(0).value
	check(narrow.apply_move_intent(stage,move(0),ai).ok and narrow.stage_step(0,.1,stage).ok and narrow.commit_step(stage).ok,"maximum dt approaches a thin authored pinch")
	check(narrow.view(handle(0)).value.position.x== -8 and narrow.view(handle(0)).value.blocked=="yield","a whole step cannot jump over a gate narrower than the moving body")
	print("MOVE_NAV closed_x=",blocked.x," restored_x=",bridge.view(handle(0)).value.position.x," restricted_rider_x=",rider.view(handle(0)).value.position.x)

func load_drives(n: int) -> void:
	var field := Field.new(meter,SCOPE,authorize)
	var handles := []
	var starts := PackedVector3Array()
	for i in n:
		var origin := Vector3(-58.8+i%36*2.0,0,-40+floori(i/36.0)*2.0)
		handles.append(handle(i))
		starts.append(origin)
		field.spawn(handle(i),origin,"mounted" if i%5==0 else "foot",Vector3.RIGHT)
	var roster: RefCounted = field.bind_roster(handles).value
	var stage: RefCounted = field.begin_step(0).value
	var begin := Time.get_ticks_usec()
	for i in n: check(field.apply_move_intent(stage,move(i,.5),ai).ok,"mixed drive admitted")
	var intake_usec := Time.get_ticks_usec()-begin
	var queries_before := meter.queries
	var first := field.stage_step(0,DT,stage)
	check(first.ok and first.value.total_queried==8 and field.rollback_step(stage).ok,"all intents and first eight routes rolled back")
	stage = field.begin_step(0).value
	for i in n: check(field.apply_move_intent(stage,move(i,.5),ai).ok,"mixed retry")
	var retry := field.stage_step(0,DT,stage)
	check(retry.ok and retry.value.total_queried==8 and meter.queries==queries_before+8 and field.commit_step(stage).ok,"physical nav budget conserved on retry")
	var peak := 8
	var costs := PackedInt64Array()
	for tick in range(1,ceili(n/8.0)+31):
		var t := Time.get_ticks_usec()
		var old := meter.queries
		var result := field.step(tick,DT)
		costs.append(Time.get_ticks_usec()-t)
		check(result.ok and meter.queries-old<=8,"bounded native navigation")
		if not result.ok: return
		peak = maxi(peak,result.value.total_queried)
	var samples: PackedVector3Array = field.read_positions(roster).value
	var moved := 0
	for i in n:
		if samples[i].distance_to(starts[i])>.005: moved+=1
		if starts[i].x<0 and absf(starts[i].z)<2.5:
			check(samples[i].x<-.45,"crowd broad phase retains exact foreground wall")
	costs.sort()
	check(peak==8 and moved==n and meter.queries-queries_before<=n+8,"bounded fair admission and route reuse")
	print("MOVE_INTENT_LOAD n=",n," moved=",moved," paths=",meter.queries-queries_before," peak=",peak," staged_intake_us=",intake_usec," simulate_p95_us=",costs[ceili(costs.size()*.95)-1])

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	engine = Adapter.new(root,true)
	meter = Meter.new()
	meter.engine = engine
	if await arena("res://tests/p2/ai/arena.tscn"):
		transactions()
		commit_authority()
		await actor_colliders()
		await wall_and_horse()
		riding_curve()
		for n in [500,1000]: load_drives(n)
		engine.release_scope(SCOPE)
	else: check(false,"opening real navigation and collision area")
	if await arena("res://tests/p2/movement/field.tscn"):
		await gated()
		engine.release_scope(SCOPE)
	else: check(false,"opening real bridge area")
	print("MOVE_INTENTS checks=",checks," failures=",failures)
	quit(int(failures>0))
