extends RefCounted

const R = preload("res://contracts/result.gd")
const Values = preload("res://contracts/values.gd")
var _revision_counter := 0

static func _vector(value: Variant) -> bool:
	return value is Array and value.size()==3 and (
		Values.integer(value[0],-2147483648,2147483647) and Values.integer(value[1],-2147483648,2147483647)
		and Values.integer(value[2],-2147483648,2147483647))

static func _meters(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2]) * 0.001

static func _quantized(value: Vector3, scale: int) -> Array:
	return [roundi(value.x*scale),roundi(value.y*scale),roundi(value.z*scale)]

func mark_pending(scope: Dictionary) -> void:
	_revision_counter += 1
	scope.requested = _revision_counter
	scope.iteration = NavigationServer3D.map_get_iteration_id(scope.view.world_3d.navigation_map)
	scope.pending = true

func sync(scope: Dictionary) -> Dictionary:
	var map: RID = scope.view.world_3d.navigation_map
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if iteration > 0 and iteration != scope.iteration:
		if not scope.pending:
			_revision_counter += 1
			scope.requested = _revision_counter
		scope.revision = scope.requested
		scope.pending = false
		scope.iteration = iteration
	return R.ok({"requested_revision":scope.requested,"applied_revision":scope.revision,
		"status":"pending" if scope.pending or iteration == 0 else "applied"})

func apply_links(scope: Dictionary, changes: Array) -> Dictionary:
	var receipt := sync(scope)
	if receipt.value.status != "applied":
		return R.fail("Unavailable","navigation_sync")
	var targets := {}
	for row in changes:
		if typeof(row) != TYPE_DICTIONARY or typeof(row.get("link_id")) != TYPE_STRING or typeof(row.get("enabled")) != TYPE_BOOL:
			return R.fail("InvalidArgument","link")
		if not scope.links.has(row.link_id):
			return R.fail("NotFound","link_id")
		if targets.has(row.link_id):
			return R.fail("Conflict","link_id")
		targets[row.link_id] = row.enabled
	var changed := false
	for key in targets:
		var link: NavigationLink3D = scope.links[key]
		if link.enabled != targets[key]:
			link.enabled = targets[key]
			changed = true
	if changed:
		mark_pending(scope)
	return R.ok({"requested_revision":scope.requested, "applied_revision":scope.revision,
		"status":"pending" if scope.pending else "applied"})

func paths(scope: Dictionary, requests: Array, revision: Variant) -> Dictionary:
	if not Values.integer(revision):
		return R.fail("InvalidArgument","nav_revision")
	var receipt := sync(scope)
	if revision != scope.revision or receipt.value.status != "applied":
		return R.fail("StaleVersion","nav_revision")
	var map: RID = scope.view.world_3d.navigation_map
	var results := []
	for request in requests:
		if typeof(request) != TYPE_DICTIONARY or not _vector(request.get("from")) or not _vector(request.get("to")):
			return R.fail("InvalidArgument","path")
		var to := _meters(request.to)
		var route := NavigationServer3D.map_get_path(map,_meters(request.from),to,false)
		var points := []
		for point in route:
			points.append(_quantized(point,1000))
		results.append({"nav_revision":revision,"points":points,
			"reachable":not route.is_empty() and route[-1].distance_to(to) < 0.01})
	return R.ok(results)

static func _ray_hit(space: PhysicsDirectSpaceState3D, origin: Vector3, target: Vector3,
		mask: int, excluded: Array[RID]) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(origin,target,mask,excluded)
	query.hit_from_inside = true
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		hit["fraction"] = origin.distance_to(hit.position) / origin.distance_to(target)
	return hit

static func _sphere_hit(space: PhysicsDirectSpaceState3D, origin: Vector3, target: Vector3,
		radius: float, mask: int, excluded: Array[RID], cached: Dictionary) -> Dictionary:
	var query: PhysicsShapeQueryParameters3D = cached.get(radius)
	if query==null:
		var sphere := SphereShape3D.new()
		sphere.radius=radius
		query=PhysicsShapeQueryParameters3D.new()
		query.shape=sphere
		if cached.size()<8:
			cached[radius]=query
	query.motion=Vector3.ZERO
	query.collision_mask = mask
	query.exclude = excluded
	# A shape cast ignores existing penetration. Query the starting sphere
	# separately; an interior point need not have a unique contact normal.
	query.transform = Transform3D(Basis.IDENTITY,origin)
	var initial := space.intersect_shape(query, 1)
	if not initial.is_empty():
		var hit: Dictionary = initial[0]
		var contact := space.get_rest_info(query)
		hit["position"] = contact.get("point",origin) if contact.get("rid") == hit.rid else origin
		hit["normal"] = contact.get("normal",Vector3.ZERO) if contact.get("rid") == hit.rid else Vector3.ZERO
		hit["fraction"] = 0.0
		return hit
	var length := origin.distance_to(target)
	var parts := maxi(1,ceili(length / 12.0))
	if parts > 4096:
		return {"error":"sweep_budget"}
	for part in parts:
		var start := origin.lerp(target,float(part)/parts)
		var end := origin.lerp(target,float(part+1)/parts)
		# The overlap check left the query at the first segment's start.
		if part > 0:
			query.transform = Transform3D(Basis.IDENTITY,start)
			query.motion = Vector3.ZERO
		var hit := space.get_rest_info(query)
		var contact := start
		if hit.is_empty():
			query.motion = end-start
			var limits := space.cast_motion(query)
			if limits.size() != 2 or limits[0] >= 1.0:
				continue
			# Jolt's unsafe fraction may already be past a thin body. Narrow
			# the continuous bracket before probing for the hit's collider.
			for attempt in 5:
				contact = start.lerp(end,limits[1])
				query.motion = Vector3.ZERO
				query.transform = Transform3D(Basis.IDENTITY,contact)
				hit = space.get_rest_info(query)
				if not hit.is_empty():
					break
				var pad := (end-start).normalized()*0.0005
				start = start.lerp(end,limits[0])-pad
				end = contact+pad
				query.transform = Transform3D(Basis.IDENTITY,start)
				query.motion = end-start
				limits = space.cast_motion(query)
				if limits.size() != 2 or limits[0] >= 1.0:
					break
			if hit.is_empty():
				return {"error":"sweep_contact"}
		hit["fraction"] = origin.distance_to(contact)/length
		hit["position"] = hit.point
		hit["collider"] = instance_from_id(hit.collider_id)
		return hit
	return {}

static func sweep(scope: Dictionary, queries: Array, field := false) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = scope.view.world_3d.direct_space_state
	var result := []
	var spheres:={}
	# The batch is synchronous; reuse scratch arrays and only sort actual contacts.
	var excluded: Array[RID] = []
	var hits := []
	for index in queries.size():
		var q: Variant = queries[index]
		if typeof(q) != TYPE_DICTIONARY or not _vector(q.get("from")) or not _vector(q.get("to")):
			return R.fail("InvalidArgument","sweep")
		var radius: Variant = q.get("radius_mm",0)
		var mask: Variant = q.get("mask",0xffffffff)
		var ignored: Variant = q.get("ignored_handles",[])
		if not Values.integer(radius,0,2147483647) or not Values.integer(mask,0,0xffffffff) or typeof(ignored) != TYPE_ARRAY:
			return R.fail("InvalidArgument","shape")
		var origin := _meters(q.from)
		var target := _meters(q.to)
		if origin == target:
			return R.fail("InvalidArgument","motion")
		excluded.clear()
		hits.clear()
		while true:
			var hit: Dictionary
			if radius == 0:
				hit = _ray_hit(space,origin,target,mask,excluded)
			else:
				hit = _sphere_hit(space,origin,target,float(radius)*0.001,mask,excluded,spheres)
			if hit.is_empty():
				break
			if hit.has("error"):
				return R.fail("Unavailable",hit.error)
			excluded.append(hit.rid)
			var object: Object = hit.collider
			if not object is CollisionObject3D:
				continue
			var handle := str(object.get_meta("entity_handle",str(scope.view.get_path_to(object))))
			if handle in ignored:
				continue
			var row := {"query_index":index,"entity_handle":handle,
				"fraction_ppm":roundi(clampf(hit.fraction,0,1)*1000000),
				"point_mm":_quantized(hit.position,1000),"normal_ppm":_quantized(hit.normal,1000000),
				"region":str(object.get_meta("region","body"))}
			if field:
				scope.field.tag_hit(object,hit.position,row)
			hits.append(row)
		if hits.size() == 1:
			result.append(hits[0])
		elif hits.size() > 1:
			hits.sort_custom(func(a,b):
				if a.fraction_ppm == b.fraction_ppm:
					return a.entity_handle < b.entity_handle
				return a.fraction_ppm < b.fraction_ppm)
			result.append_array(hits)
	return R.ok(result)
