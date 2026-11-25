extends RefCounted
## Composition owns the adapter and releases each Mission scope at its exit barrier.
const R = preload("res://contracts/result.gd")
const Values = preload("res://contracts/values.gd")
const Queries = preload("res://infrastructure/engine/queries.gd")
const FieldBodies = preload("res://infrastructure/engine/field_bodies.gd")
const DEFAULT_SCENE := "res://infrastructure/engine/simulation_root.tscn"

var _host: Node
var _headless: bool
var _thread: int
var _serial := 0
var _scopes := {}
var _requests := {}
var _nav := Queries.new()

func _init(host_node: Node, headless_profile: bool = true) -> void:
	_host = host_node
	_headless = headless_profile
	_thread = OS.get_main_thread_id()

func _on_owner() -> bool:
	return OS.get_thread_caller_id() == _thread

func open_scope(scope: String) -> Dictionary:
	if not _on_owner() or not is_instance_valid(_host) or not _host.is_inside_tree():
		return R.fail("InvalidState","host")
	if scope.is_empty() or _scopes.has(scope):
		return R.fail("Conflict","scope_id")
	_serial += 1
	var token := {"scope_id":scope,"generation":_serial}
	token.make_read_only()
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_host.add_child(viewport)
	_scopes[scope] = {"token":token,"view":viewport,"leases":{},"links":{},"revision":0,
		"pending":false,"iteration":0,"requested":0,"claims":{},"presentation":null,"field":FieldBodies.new(viewport)}
	return R.ok(token)

func _authorized(token: Dictionary) -> bool:
	var scope: Variant = token.get("scope_id")
	return _scopes.has(scope) and is_same(_scopes[scope].token,token)

func begin_scene_load(definition: Dictionary, token: Dictionary) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	if not _authorized(token):
		return R.fail("StaleVersion","generation")
	var path: Variant = definition.get("simulation_scene")
	if not Values.def_id(definition.get("id")) or typeof(path) != TYPE_STRING or not path.begins_with("res://") or not ResourceLoader.exists(path,"PackedScene"):
		return R.fail("NotFound","simulation_scene")
	if ResourceLoader.load_threaded_request(path,"PackedScene") != OK:
		return R.fail("Unavailable","scene")
	_serial += 1
	var request := {"request_id":_serial,"scope_id":token.scope_id,"generation":token.generation}
	request.make_read_only()
	_requests[_serial] = {"request":request,"path":path,"id":definition.id}
	return R.ok(request)

func finish_scene_load(request: Dictionary, wait: bool = false) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	var row: Dictionary = _requests.get(request.get("request_id"),{})
	if row.is_empty() or not is_same(request,row.request):
		return R.fail("StaleVersion","request")
	if not wait and ResourceLoader.load_threaded_get_status(row.path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return R.fail("Unavailable","pending")
	_requests.erase(request.request_id)
	var scene := ResourceLoader.load_threaded_get(row.path) as PackedScene
	if scene == null:
		return R.fail("Unavailable","scene")
	var scope: Dictionary = _scopes[request.scope_id]
	if scope.leases.has(row.id):
		var lease: Dictionary = scope.leases[row.id]
		if lease.path != row.path:
			return R.fail("Conflict","resource_id")
		return _claim(scope,request,row.id)
	var instance := scene.instantiate()
	if instance == null:
		return R.fail("Unavailable","instantiate")
	var links := {}
	var changes_nav := false
	for node in [instance] + instance.find_children("*","",true,false):
		if node is NavigationRegion3D or node is NavigationLink3D:
			changes_nav = true
		if node is VisualInstance3D or node is Camera3D or node is AudioStreamPlayer or node is AudioStreamPlayer3D or node is AudioStreamPlayer2D:
			instance.free()
			return R.fail("InvalidArgument","simulation_scene.presentation")
		if node is NavigationLink3D and node.has_meta("link_id"):
			var key := str(node.get_meta("link_id"))
			if key.is_empty() or links.has(key) or scope.links.has(key):
				instance.free()
				return R.fail("Conflict","link_id")
			links[key] = node
	if changes_nav:
		_nav.mark_pending(scope)
	scope.view.add_child(instance)
	scope.leases[row.id] = {"path":row.path,"instance":instance,"refs":0,"link_ids":links.keys(),"changes_nav":changes_nav}
	scope.links.merge(links)
	return _claim(scope,request,row.id)

func _claim(scope: Dictionary, request: Dictionary, resource_id: String) -> Dictionary:
	var descriptor := {"scope_id":request.scope_id,"generation":request.generation,
		"resource_id":resource_id,"lease_id":request.request_id}
	descriptor.make_read_only()
	scope.claims[descriptor.lease_id] = descriptor
	scope.leases[resource_id].refs += 1
	return R.ok(descriptor)

func load_scene(definition: Dictionary, token: Dictionary) -> Dictionary:
	var started := begin_scene_load(definition,token)
	if not started.ok:
		return started
	return finish_scene_load(started.value,true)

func release_lease(descriptor: Dictionary) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	var scope: Dictionary = _scopes.get(descriptor.get("scope_id"),{})
	if scope.is_empty():
		return R.fail("NotFound","scope_id")
	var row: Dictionary = scope.leases.get(descriptor.get("resource_id"),{})
	if row.is_empty() or not is_same(scope.claims.get(descriptor.get("lease_id")),descriptor):
		return R.fail("StaleVersion","lease_id")
	scope.claims.erase(descriptor.lease_id)
	row.refs -= 1
	if row.refs == 0:
		if row.changes_nav:
			_nav.mark_pending(scope)
		for key in row.link_ids:
			scope.links.erase(key)
		row.instance.free()
		scope.leases.erase(descriptor.resource_id)
	return R.ok()

func instantiate_visual(definition: Dictionary, scope_id: String) -> Dictionary:
	if not _on_owner() or _headless:
		return R.fail("InvalidState","profile")
	if not _scopes.has(scope_id):
		return R.fail("NotFound","scope_id")
	var path: Variant = definition.get("visual_scene")
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or not ResourceLoader.exists(path,"PackedScene"):
		return R.fail("NotFound","visual_scene")
	var packed := ResourceLoader.load(path,"PackedScene") as PackedScene
	if packed == null:
		return R.fail("Unavailable","visual_scene")
	var instance := packed.instantiate()
	if instance == null:
		return R.fail("Unavailable","visual_scene")
	var scope: Dictionary = _scopes[scope_id]
	# Presentation resources may contain colliders or navigation meshes. Their
	# world stays separate even when children are added after instantiation.
	if scope.presentation == null:
		var presentation := SubViewport.new()
		presentation.world_3d = World3D.new()
		scope.view.add_child(presentation)
		scope.presentation = presentation
	scope.presentation.add_child(instance)
	_serial += 1
	return R.ok({"scope_id":scope_id,"visual_id":_serial})

func apply_nav_links(changes: Array, scope_id: String) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	if not _scopes.has(scope_id):
		return R.fail("NotFound","scope_id")
	return _nav.apply_links(_scopes[scope_id],changes)

func sync_navigation(scope_id: String) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	if not _scopes.has(scope_id):
		return R.fail("NotFound","scope_id")
	return _nav.sync(_scopes[scope_id])

func query_path_batch(requests: Array, nav_revision: Variant, scope_id: String) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	if not _scopes.has(scope_id):
		return R.fail("NotFound","scope_id")
	return _nav.paths(_scopes[scope_id],requests,nav_revision)

func field_stage_bodies(scope: String, rows: Array) -> Dictionary:
	if not _on_owner() or not _scopes.has(scope):
		return R.fail("InvalidState","field.scope")
	return _scopes[scope].field.stage(rows)

func field_commit_bodies(scope: String) -> Dictionary:
	if not _on_owner() or not _scopes.has(scope):
		return R.fail("InvalidState","field.scope")
	return _scopes[scope].field.commit()

func field_rollback_bodies(scope: String) -> Dictionary:
	if not _on_owner() or not _scopes.has(scope):
		return R.fail("InvalidState","field.scope")
	return _scopes[scope].field.rollback()

func field_clearance(scope: String, sites: Array) -> Dictionary:
	if not _on_owner() or not _scopes.has(scope):
		return R.fail("InvalidState","field.scope")
	return _scopes[scope].field.clearance(sites)

func field_los(scope: String, from_m: Vector3, to_m: Vector3) -> bool:
	return _on_owner() and _scopes.has(scope) and _scopes[scope].field.los(from_m,to_m)

func field_sweep(scope: String, queries: Array, tick: int) -> Dictionary:
	return _sweep(queries,{"scope_id":scope,"tick":tick},true)

func query_sweep_batch(queries: Array, stamp: Dictionary) -> Dictionary:
	return _sweep(queries,stamp,false)

# MOV may skip sweeps wholly above a single static slab. Recheck the live
# simulation scope: doors, other shapes and procedural colliders disable this proof.
func field_scenery_top(scope_id: String, mask: int) -> float:
	if not _on_owner() or not _scopes.has(scope_id): return INF
	var view: SubViewport = _scopes[scope_id].view
	var floor_body: StaticBody3D
	for node in view.find_children("*","",true,false):
		if node.get_script()!=null: return INF
		match node.get_class():
			"StaticBody3D":
				if (node.collision_layer & mask)==0: continue
				if floor_body!=null: return INF
				floor_body = node
			"Node3D", "CollisionShape3D", "NavigationRegion3D": pass
			_: return INF
	if floor_body==null or floor_body.global_basis!=Basis.IDENTITY: return INF
	var rid := floor_body.get_rid()
	if PhysicsServer3D.body_get_shape_count(rid)!=1: return INF
	var shape := PhysicsServer3D.body_get_shape(rid,0)
	if PhysicsServer3D.shape_get_type(shape)!=PhysicsServer3D.SHAPE_BOX: return INF
	var pose: Transform3D = PhysicsServer3D.body_get_state(rid,PhysicsServer3D.BODY_STATE_TRANSFORM)
	pose = pose * PhysicsServer3D.body_get_shape_transform(rid,0)
	if pose.basis!=Basis.IDENTITY: return INF
	var half_size: Vector3 = PhysicsServer3D.shape_get_data(shape)
	return pose.origin.y+half_size.y

func _sweep(queries: Array, stamp: Dictionary, field: bool) -> Dictionary:
	if not _on_owner():
		return R.fail("InvalidState","thread")
	if not _scopes.has(stamp.get("scope_id")):
		return R.fail("NotFound","scope_id")
	if not Values.integer(stamp.get("tick")):
		return R.fail("InvalidArgument","tick")
	if stamp.has("generation") and stamp.generation != _scopes[stamp.scope_id].token.generation:
		return R.fail("StaleVersion","generation")
	return Queries.sweep(_scopes[stamp.scope_id],queries,field)

func release_scope(scope_id: String) -> Dictionary:
	if not _on_owner():
		return {"released":0,"cancelled":0,"error":"InvalidState"}
	if not _scopes.has(scope_id):
		return {"released":0,"cancelled":0}
	var scope: Dictionary = _scopes[scope_id]
	_scopes.erase(scope_id)
	var cancelled := 0
	for id in _requests.keys():
		var row: Dictionary = _requests[id]
		if row.request.scope_id == scope_id:
			ResourceLoader.load_threaded_get(row.path)
			_requests.erase(id)
			cancelled += 1
	scope.view.free()
	return {"released":scope.leases.size(),"cancelled":cancelled}

func counts() -> Dictionary:
	var leases := 0
	for scope in _scopes.values():
		leases += scope.leases.size()
	return {"scopes":_scopes.size(),"leases":leases,"requests":_requests.size()}
