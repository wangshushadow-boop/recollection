extends SceneTree

const Queries = preload("res://infrastructure/engine/queries.gd")
const Canon = preload("res://contracts/canonical.gd")
const PLAIN = preload("res://content/base/field/river_plain.tscn")
var scope := {}
var checks := 0
var failures := 0
var transcript := HashingContext.new()

func check(good: bool, label: String) -> void:
	checks+=1
	if not good:
		failures+=1
		printerr("FAIL ",label)

func fixture(count: int) -> Array:
	var rows := []
	for i in count:
		var radius:=470 if i%5==0 else 280
		var x: int=(i%32-16)*1000
		var z: int=(floori(float(i)/32)-12)*1000
		rows.append({"from":[x,radius+40,z],"to":[x+80,radius+40,z],"radius_mm":radius,"mask":1})
	return rows

func individually(rows: Array) -> Dictionary:
	var all := []
	for index in rows.size():
		var reply:=Queries.sweep(scope,[rows[index]])
		if not reply.ok:
			return reply
		for hit in reply.value:
			hit.query_index=index
			all.append(hit)
	return {"ok":true,"value":all}

func compare(rows: Array, label: String) -> Dictionary:
	var exact:=individually(rows)
	var fast:=Queries.sweep(scope,rows)
	check(fast==exact,label+" same results/errors")
	transcript.update(Canon.encode(fast).value)
	return fast

func box(size: Vector3, at: Vector3, id: String) -> StaticBody3D:
	var shape:=BoxShape3D.new()
	shape.size=size
	return collider(shape,at,id)

func collider(shape: Shape3D,at: Vector3,id: String) -> StaticBody3D:
	var body:=StaticBody3D.new()
	body.set_meta("entity_handle",id)
	var area:=CollisionShape3D.new()
	area.shape=shape
	body.add_child(area)
	body.position=at
	scope.view.add_child(body)
	body.force_update_transform()
	return body

func performance(rows: Array,label: String) -> void:
	var samples:=PackedInt64Array()
	var hits:=0
	for repeat in 46:
		var t:=Time.get_ticks_usec()
		var result:=Queries.sweep(scope,rows)
		var elapsed:=Time.get_ticks_usec()-t
		if not result.ok:
			check(false,"benchmark failed "+label)
			return
		hits=result.value.size()
		if repeat>=6:
			samples.append(elapsed)
	samples.sort()
	print("SWEEP_TIMES ",label," requests=",rows.size()," hits=",hits," samples=",samples.size(),
		" median_us=",samples[19]," p95_us=",samples[37])

func thin_faces() -> void:
	var positions:=PackedVector3Array([Vector3(0,-1,-2),Vector3(0,3,-2),Vector3(0,1,2)])
	var front_hits:=0
	for face in 2:
		var mesh:=ConcavePolygonShape3D.new()
		mesh.set_faces(positions)
		var plate:=collider(mesh,Vector3(65,0,50),"triangle")
		for side in [-1,1]:
			var rows: Array=[]
			for i in 64:
				var x: int=65000 + side*(200 if i%32==0 else 5000)
				rows.append({"from":[x,700,50000],"to":[x+side*55,700,50000],"radius_mm":280,"mask":1})
			for i in [0,32]:
				rows[i].from[0]=65000-side*200
				rows[i].to[0]=65000-side*150
			var rep:=compare(rows,"wide bounds around single-sided face "+str(face)+"/"+str(side))
			if rep.ok and rep.value.any(func(h):return h.entity_handle=="triangle"):
				front_hits+=1
		positions.reverse()
		plate.free()
	check(front_hits==2,"both winding directions hit on front and skip on back")

func grazing_projectile() -> void:
	# A 15 mm projectile grazing the rounded bottom of a mounted fighter at river
	# tick 1885: cast_motion's unsafe sample was already beyond the capsule.
	var shape := CapsuleShape3D.new()
	shape.radius = 0.30
	shape.height = 1.80
	var rider := collider(shape,Vector3(40.7816276550293,1.85,7.64076328277588),"rider")
	rider.rotation.y = -0.596333005039446
	rider.collision_layer = 2
	rider.force_update_transform()
	var row := {"from":[38988,1000,9353],"to":[41153,997,7577],"radius_mm":15,"mask":2}
	var result := Queries.sweep(scope,[row])
	check(result.ok and result.value.size()==1 and result.value[0].entity_handle=="rider" and
		result.value[0].fraction_ppm>850000 and result.value[0].fraction_ppm<910000,"grazing arrow strikes rounded rider with correct fraction")
	var clear := row.duplicate(true)
	clear.from[1]-=5
	clear.to[1]-=5
	check(Queries.sweep(scope,[clear]).get("value")==[],"lower arrow misses the rider")
	var shield := box(Vector3(.012,.4,.4),Vector3(40.07,1.0,8.46),"shield")
	shield.collision_layer = 2
	var blocked := Queries.sweep(scope,[row])
	check(blocked.ok and blocked.value.map(func(h):return h.entity_handle)==["shield","rider"],"thin blocker precedes grazing body")
	row.ignored_handles=["shield"]
	var ignored := Queries.sweep(scope,[row])
	check(ignored.ok and ignored.value.size()==1 and ignored.value[0].entity_handle=="rider","excluded blocker preserves later physical grazing hit")
	shield.free()
	rider.free()

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	transcript.start(HashingContext.HASH_SHA256)
	var world:=SubViewport.new()
	world.world_3d=World3D.new()
	root.add_child(world)
	scope={"view":world}
	world.add_child(PLAIN.instantiate())
	var plate := box(Vector3(4,0.02,4),Vector3.ZERO,"grazing_plate")
	await physics_frame
	await physics_frame
	var grazing := Queries.sweep(scope,[{"from":[0,290,0],"to":[8,292,1],"radius_mm":280,"mask":1}])
	check(grazing.ok and grazing.value.any(func(h):return h.entity_handle=="grazing_plate" and h.fraction_ppm==0),
		"sphere touching a 20 mm plate reports contact at its starting position")
	plate.free()
	grazing_projectile()
	for count in [16,64,500,1000]:
		var rows:=fixture(count)
		var response:=compare(rows,"clear actual terrain "+str(count))
		check(response.ok and response.value.is_empty(),"40 mm floor clearance")
		performance(rows,"clear")
	var dense:=fixture(1000)
	var door:=box(Vector3(.035,2,9),Vector3(.35,.9,-5),"door")
	var bridge:=box(Vector3(3,.05,12),Vector3(6,.58,-5),"deck")
	var slope:=box(Vector3(1,.2,5),Vector3(-3,.35,-9),"slope")
	slope.rotation.z=.35
	slope.force_update_transform()
	var high:=box(Vector3(2,1,3),Vector3(4,.5,-6),"other_layer")
	high.collision_layer=2
	var mesh:=ConcavePolygonShape3D.new()
	mesh.set_faces(PackedVector3Array([Vector3(-2,.6,-1),Vector3(2,0,-1),Vector3(2,.3,1)]))
	collider(mesh,Vector3(-8,.1,-4),"one_sided")
	var initial:=compare(dense,"door deck slope and one-sided triangle")
	check(initial.ok and initial.value.any(func(h):return h.entity_handle=="slope") and initial.value.any(func(h):return h.entity_handle=="deck"),"verified solid slope and bridge")
	check(initial.ok and initial.value.any(func(h):return h.entity_handle=="door") and not initial.value.any(func(h):return h.entity_handle=="other_layer"),"thin door and collision mask")
	performance(dense,"obstacles")
	var old:=door.position
	door.position+=Vector3.UP*5
	door.force_update_transform()
	var opened:=compare(dense,"door opened this step")
	check(opened.ok and not opened.value.any(func(h):return h.entity_handle=="door"),"open door")
	door.position=old
	door.force_update_transform()
	check(compare(dense,"rollback door").value==initial.value,"same-step rollback")
	var mixed:=fixture(96)
	for i in mixed.size():
		mixed[i].from[1]-=70
		mixed[i].to[1]-=70
	var contact:=compare(mixed,"starts inside true floor")
	check(contact.ok and contact.value.size()>=mixed.size() and contact.value.any(func(h):return h.fraction_ppm==0),"real initial contacts")
	mixed=fixture(96)
	mixed[3].to[1]+=120
	mixed[4].radius_mm=0
	mixed[5].mask=2
	mixed[31].to[0]+=4000
	mixed[77].ignored_handles=["door"]
	compare(mixed,"mixed exact fallbacks")
	for item in [null,{"from":[0,0,"bad"],"to":[0,0,0]},
			{"from":[0,0,0],"to":[1,0,0],"radius_mm":false},{"from":[0,0,0],"to":[1,0,0],"mask":-1},
			{"from":[0,0,0],"to":[1,0,0],"ignored_handles":null},{"from":[1,1,1],"to":[1,1,1]}]:
		mixed=fixture(100)
		mixed[79]=item
		check(not compare(mixed,"invalid row 79").ok,"invalid does not get culled")
	var radii:=fixture(100)
	for i in radii.size():
		radii[i].radius_mm = 200+(i%12)*21
		radii[i].mask = 1 if i%2==0 else 3
	compare(radii,"varied shape budgets and masks")
	thin_faces()
	bridge.free()
	world.free()
	print("FIELD_SWEEP_BATCH checks=",checks," failures=",failures," replay_sha256=",transcript.finish().hex_encode())
	quit(0 if failures==0 else 1)
