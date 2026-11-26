extends RefCounted
## Local desktop geometry, independent of campaign saves and the canvas resolution.
var _window: Window
var _normal_size := Vector2i.ZERO
var _maximized := false
var _path := "user://window.cfg"

func restore(window: Window) -> void:
	_window = window
	_normal_size = window.size
	# The native preview uses its own game saves, but both launchers share desktop geometry.
	var shared_dir := OS.get_environment("RECOLLECTION_WINDOW_DIR")
	if shared_dir.is_absolute_path() and DirAccess.make_dir_recursive_absolute(shared_dir)==OK:
		_path = shared_dir.path_join("window.cfg")
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(_path) and cfg.load(_path)==OK:
		var saved: Variant = cfg.get_value("window","size",_normal_size)
		if saved is Vector2i and saved.x>0 and saved.y>0:
			var work_area := DisplayServer.screen_get_usable_rect(window.current_screen)
			var decorations := (window.get_size_with_decorations()-window.size).max(Vector2i.ZERO)
			var inset := window.position-window.get_position_with_decorations()
			var available := (work_area.size-decorations).max(Vector2i.ONE)
			_normal_size = saved.min(available)
			window.size = _normal_size
			window.position = work_area.position+(available-_normal_size)/2+inset
		_maximized = cfg.get_value("window","maximized",false)==true
		if _maximized: window.mode=Window.MODE_MAXIMIZED
	window.size_changed.connect(_remember)

func _remember() -> void:
	match _window.mode:
		Window.MODE_WINDOWED:
			if _window.size.x>0 and _window.size.y>0:
				_normal_size = _window.size
				_maximized = false
		Window.MODE_MAXIMIZED:
			_maximized = true

func save() -> void:
	_remember()
	var cfg := ConfigFile.new()
	cfg.set_value("window","size",_normal_size)
	cfg.set_value("window","maximized",_maximized)
	var temp := _path+".%d.tmp"%OS.get_process_id()
	if cfg.save(temp)!=OK or DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),ProjectSettings.globalize_path(_path))!=OK:
		push_warning("无法保存窗口大小。")
