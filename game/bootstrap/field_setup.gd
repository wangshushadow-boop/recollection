extends RefCounted
## Translate the compiled field package into a Mission launch, using its original markers and loadouts.
const R = preload("res://contracts/result.gd")
const C = preload("res://contracts/canonical.gd")
const V = preload("res://contracts/values.gd")
const Characters = preload("res://campaign/character/ports/characters.gd")
const ROOT := "res://content/base/field/"
const MIX := ["infantry","archer","cavalry","mounted_archer"]

static func _mix(count: int) -> Array:
	var quantities := [count/2, count*3/10, count/10, count/10]
	for i in count-quantities.reduce(func(a,b):return a+b,0):
		quantities[i] += 1
	return quantities

static func _point(center: Array, column: int, row: int, width: int, depth: int, spacing: int) -> Array:
	return [center[0]+roundi((row-0.5*(depth-1))*spacing),center[1],
		center[2]+roundi((column-0.5*(width-1))*spacing)]

static func build(content: Dictionary, mode: String, limit: int, total: int, seed_value: int) -> Dictionary:
	if not V.integer(limit,2,100000) or not V.integer(total,limit,100000) or mode not in ["custom","multiplayer"]:
		return R.fail("InvalidArgument","field.size")
	var scene_def: Dictionary = content.registry.get_definition("field:scene/river_plain","scene")
	var rule_def: Dictionary = content.registry.get_definition("field:ruleset/field_battle","ruleset")
	if not scene_def.ok: return scene_def
	if not rule_def.ok: return rule_def
	var scene: Dictionary = scene_def.value.duplicate(true)
	var rules: Dictionary = rule_def.value.duplicate(true)
	var file := FileAccess.open(ROOT.path_join(scene.asset_ref),FileAccess.READ)
	if file == null: return R.fail("NotFound","field.markers")
	var bytes := file.get_buffer(file.get_length())
	var hash_check := HashingContext.new()
	hash_check.start(HashingContext.HASH_SHA256)
	hash_check.update(bytes)
	if hash_check.finish().hex_encode()!=content.resources.get("field/"+scene.asset_ref):
		return R.fail("Conflict","field.markers")
	var parsed := C.decode_source(bytes)
	if not parsed.ok: return parsed
	var asset: Variant = parsed.value
	if not asset is Dictionary or not asset.get("markers") is Array: return R.fail("InvalidArgument","field.markers")
	var markers := {}
	for entry in asset.markers:
		markers[entry.id] = entry
	scene.simulation_scene = scene.metadata.simulation_scene
	scene.field_allow_jump = scene.metadata.get("allow_jump",false)
	scene.field_sites = []
	for objective in scene.objectives:
		var marker: Dictionary = markers.get(objective,{})
		if marker.get("kind")!="objective": return R.fail("InvalidArgument","field.objective")
		var mm: Array = marker.position_mm
		scene.field_sites.append({"id":marker.id,"position":Vector3(mm[0],mm[1],mm[2])*0.001,"objective":true})
	scene.field_zones = []
	scene.field_exit_zones = []
	scene.field_player = {"issuer_id":"player","team_key":0}
	var commander: Dictionary = {}
	if mode=="custom":
		# Only copy the drill commander's identity and level into the mission. The campaign save is never opened.
		var world := "world/river-practice-%016x"%seed_value
		var created := Characters.plan({},null,"create",{"name":"河原主将"},world,0,"drill/commander")
		if not created.ok: return created
		var read := Characters.view(created.value.repo,created.value.inventory,world,0)
		if not read.ok: return read
		commander = read.value.hero
		scene.field_player.commander_level = commander.level
	rules.battle_mode = rules.mode
	rules.merge(rules.parameters,true)
	var spec := {"schema_version":1,"encounter_id":"encounter/00000000-0000-4000-8000-000000000002",
		"reservation_revision":0,"mode":mode,"scene_def_id":scene.id,"ruleset_id":rules.id,
		"environment":{},"rng_seed":"%016x"%seed_value,"sides":[],"reserved_sources":[],
		"battle_limit":limit,"deployment_constraints":{},"siege_snapshot":null}
	var slot := 0
	for team in 2:
		var spawn: Dictionary = markers.get(scene.spawn_zones[team],{})
		var exit_marker: Dictionary = markers.get(scene.exit_zones[team],{})
		if spawn.get("kind")!="spawn" or exit_marker.get("kind")!="exit": return R.fail("InvalidArgument","field.zones")
		var center: Array = spawn.position_mm
		var edge: Array = exit_marker.position_mm
		var quota := limit/2+int(team==0 and limit%2==1)
		var count := total/2+int(team==0 and total%2==1)
		var width := mini(scene.metadata.spawn_columns,quota)
		var depth := ceili(float(quota)/width)
		var points := []
		for i in quota: points.append(_point(center,i%width,i/width,width,depth,scene.metadata.spacing_mm))
		scene.field_zones.append({"id":spawn.id,"team_key":team,"quota":quota,"rally_mm":center,"points_mm":points})
		scene.field_exit_zones.append({"id":exit_marker.id,"team_key":team,
			"min_mm":[edge[0]-4500,-2000,edge[2]-18000],"max_mm":[edge[0]+4500,5000,edge[2]+18000]})
		var commander_id: Variant = commander.get("id") if team==0 else null
		var side := {"team_key":team,"faction_id":["river-west","river-east"][team],"commander_hero_id":commander_id,
			"roster_allocations":[{"source_slot_range":[slot,slot+count]}]}
		spec.sides.append(side)
		for wave_count in [quota,count-quota]:
			var amounts := _mix(wave_count)
			for k in MIX.size():
				var amount: int = amounts[k]
				if amount==0: continue
				var troop: Dictionary = content.registry.get_definition("field:troop/"+MIX[k],"troop")
				if not troop.ok: return troop
				var source := {"source_party_id":"party/00000000-0000-4000-8000-%012d"%(team+1),
					"troop_def_id":troop.value.id,"hero_id":null,"count":amount,"source_slot_range":[slot,slot+amount],
					"loadout_snapshot_id":troop.value.equipment_set_ids[0]}
				if slot==0 and commander_id!=null:
					var captain := source.merged({"troop_def_id":null,"hero_id":commander_id,"count":1,"source_slot_range":[slot,slot+1]},true)
					spec.reserved_sources.append(captain)
					source.source_slot_range[0] += 1
					source.count -= 1
				if source.count>0: spec.reserved_sources.append(source)
				slot += amount
	return R.ok({"spec":spec,"scene":scene,"rules":rules})
