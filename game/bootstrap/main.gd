extends Node
const Composition = preload("res://bootstrap/composition_root.gd")
const Config = preload("res://bootstrap/boot_config.gd")
const Canon = preload("res://contracts/canonical.gd")
const Protocol = preload("res://contracts/ports/network_port.gd")

var _root: RefCounted
var _profile := ""
var _content_hash := ""
var _desktop: Control
var _profile_smoke := false
var _last_tick := 0
var _running := false
var _field_scene: Node3D
var _retiring_audio: Array[WeakRef] = []
var _finishing := false

func _ready() -> void:
	get_tree().auto_accept_quit=false
	set_physics_process(false)
	_start.call_deferred()

func _start() -> void:
	var args := OS.get_cmdline_user_args()
	_profile_smoke="--p1-smoke" in args
	var environment := {}
	for name in ["RECOLLECTION_PROFILE","RECOLLECTION_LOG_LEVEL"]:
		environment[name]=OS.get_environment(name)
	var config:=Config.resolve(args,DisplayServer.get_name(),environment)
	if not config.ok:
		_failure(config)
		return
	_profile=config.value.profile
	_root=Composition.new(self)
	var started: Dictionary=_root.boot(config.value)
	if not started.ok:
		_failure(started)
		return
	_content_hash=started.value.content_hash
	if _profile=="tool":
		_finish("",0)
		return
	_running=true
	if _profile=="client":
		# Loading this resource is the desktop profile's responsibility only.
		_desktop=load("res://bootstrap/desktop.gd").new()
		add_child(_desktop)
		_desktop.mount(_root)
		_desktop.field_requested.connect(_enter_field)
	if _profile_smoke:
		await get_tree().process_frame
		var session_started: Dictionary=_root.start_training()
		if not session_started.ok:
			_failure(session_started)
			return
		var step: Dictionary
		for _i in 3:
			step=_root.training_step()
			if not step.ok:
				_failure(step)
				return
		_last_tick=step.value.tick
		var digest:=Canon.hash_value(step.value)
		if not digest.ok:
			_failure(digest)
			return
		_finish(digest.value,0)
		return
	if _profile=="headless":
		var server: Dictionary=_root.start_field()
		if not server.ok:
			_failure(server)
			return
	Engine.physics_ticks_per_second=60
	set_physics_process(true)
	_log("ready","",0)

func _enter_field() -> void:
	var started: Dictionary = _root.start_field()
	if not started.ok:
		_desktop.field_closed(started)
		return
	_field_scene=load("res://bootstrap/field_desktop.gd").new()
	add_child(_field_scene)
	_field_scene.leave_requested.connect(_leave_field)
	var opened: Dictionary = _field_scene.mount(_root,started.value)
	if not opened.ok:
		_leave_field(opened)
		return
	_desktop.hide()

func _release_field_scene() -> void:
	if _field_scene==null: return
	_retiring_audio = _retiring_audio.filter(func(ref): return ref.get_ref()!=null)
	_retiring_audio.append_array(_field_scene.active_playbacks())
	_field_scene.release()
	remove_child(_field_scene)
	_field_scene.queue_free()
	_field_scene=null

func _leave_field(reply: Dictionary = {"ok":true}) -> void:
	_release_field_scene()
	var end: Dictionary = _root.leave_field()
	_desktop.field_closed(end if reply.ok else reply)

func _physics_process(_delta: float) -> void:
	if not _running:
		return
	var app: RefCounted=_root.session()
	var view: Dictionary=app.query()
	if view.ok and view.value.state=="Mission" and not view.value.paused:
		if _field_scene!=null and not _field_scene.running: return
		var step: Dictionary
		if _root.has_field():
			var sampled: Dictionary = {"ok":true}
			if _field_scene!=null:
				sampled = _field_scene.before_step(app.query("mission").value.tick+1)
			if not sampled.ok:
				if sampled.error.code in ["StaleVersion","Unauthorized","Conflict"]: return
				_failure(sampled)
				return
			step = _root.field_step()
			if not step.ok and step.error.code in ["Unavailable","StaleVersion"] and step.error.field in ["navigation_sync","nav_revision","deployment.spawn_site"]:
				return
			if step.ok and _field_scene!=null:
				var refreshed: Dictionary = _field_scene.after_step()
				if not refreshed.ok:
					_failure(refreshed)
					return
		else:
			step = _root.training_step()
		if not step.ok:
			_failure(step)
			return
		_last_tick=step.value.tick

func _process(delta: float) -> void:
	if _running and _field_scene!=null:
		var updated: Dictionary = _field_scene.present_frame(delta)
		if not updated.ok: _failure(updated)

func _log(event: String, state_hash: String, code: int, error: Dictionary = {}) -> void:
	var detail: Dictionary=_root.report() if _root!=null else {}
	var record := {"event":event,"profile":_profile,"protocol_version":Protocol.VERSION,
		"content_hash":_content_hash,"mission_tick":_last_tick,"state_hash":state_hash,"exit_code":code,
		"audio_pending":_retiring_audio.size(),"display":DisplayServer.get_name(),"presentation_loaded":_desktop!=null,
		"failed_module":detail.get("failed_module",""),"release_order":detail.get("release_order",[])}
	if not error.is_empty():
		record["error"]=error
	print("P1_BOOT ",JSON.stringify(record))

func _failure(reply: Dictionary) -> void:
	_running=false
	set_physics_process(false)
	_release_field_scene()
	if _root!=null:
		_root.shutdown()
	_log("failed","",1,reply.error)
	if _profile_smoke or DisplayServer.get_name()=="headless":
		get_tree().quit(1)
	else:
		if _desktop==null:
			_desktop=load("res://bootstrap/desktop.gd").new()
			add_child(_desktop)
		_desktop.show_failure(reply.error,func(): get_tree().reload_current_scene())

func _finish(state_hash: String, code: int) -> void:
	if _finishing: return
	_finishing=true
	_running=false
	set_physics_process(false)
	_release_field_scene()
	if _root!=null:
		var closed: Dictionary=_root.shutdown()
		if not closed.ok:
			_finishing=false
			_failure(closed)
			return
	# After stop(), the mixer still owns streams until a later audio callback.
	# Only the process exit waits; returning to the launcher stays immediate.
	var deadline := Time.get_ticks_msec()+250
	while not _retiring_audio.is_empty():
		_retiring_audio = _retiring_audio.filter(func(ref): return ref.get_ref()!=null)
		if _retiring_audio.is_empty() or Time.get_ticks_msec()>=deadline: break
		await get_tree().process_frame
	_log("stopped",state_hash,code)
	get_tree().quit(code)

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:
		_finish("",0)

func _exit_tree() -> void:
	_running=false
	if _root!=null:
		_root.shutdown()
