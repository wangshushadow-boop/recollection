extends RefCounted
## Local presentation preferences. The canonical codec rejects non-data values.
const R = preload("res://contracts/result.gd")
const C = preload("res://contracts/canonical.gd")
const V = preload("res://contracts/values.gd")
const DEFAULT_NAME := "field-input"
var _path: String
const OPTIONS := {"deadzone_percent":18, "mouse_sensitivity":2500, "stick_sensitivity":35000,
	"invert_y":false, "toggle_block":false, "toggle_attack":false}
const BATTLE := {
	"move_left":[KEY_A, "a/0/-"], "move_right":[KEY_D, "a/0/+"],
	"move_forward":[KEY_W, "a/1/-"], "move_back":[KEY_S, "a/1/+"],
	"look_left":[KEY_LEFT,"a/2/-"], "look_right":[KEY_RIGHT,"a/2/+"],
	"look_up":[KEY_UP,"a/3/-"], "look_down":[KEY_DOWN,"a/3/+"],
	"attack":["m/1/0","a/5/+"], "block":["m/2/0","a/4/+"],
	"cancel_attack":[KEY_X,"j/1"], "sprint":[KEY_SHIFT,"j/7"], "crouch":[KEY_C,"j/8"],
	"jump":[KEY_SPACE,"j/0"], "equip_melee":[KEY_1,"j/13"], "equip_ranged":[KEY_2,"j/14"],
	"interact":[KEY_E,"j/2"], "mount":[KEY_F,"j/3"], "dismount":[KEY_G,"j/12"]}
const COMMAND := {
	"select_all":[KEY_0,"j/2"], "select_prev":[KEY_BRACKETLEFT,"j/13"], "select_next":[KEY_BRACKETRIGHT,"j/14"],
	"order_move":["m/1/0","j/0"], "order_charge":[KEY_R,"j/3"], "order_hold":[KEY_H,"j/1"],
	"cycle_layout":[KEY_F,"j/10"], "delegate":[KEY_G,"j/9"], "order_cancel":[KEY_X,"j/12"]}
const GLOBAL := {"menu":[KEY_ESCAPE,"j/6"], "command_mode":[KEY_TAB,"j/4"]}
const FIELD_KEYS := {"view_toggle":KEY_R,"zoom":KEY_SHIFT,"free_look":KEY_QUOTELEFT,"scoreboard":KEY_TAB,
	"weapon_next":"m/4/0","walk_toggle":KEY_CAPSLOCK,"camera_nearer":KEY_KP_ADD,"camera_farther":KEY_KP_SUBTRACT}
var bindings: Dictionary
var options := OPTIONS.duplicate()

func _init(name: String = DEFAULT_NAME) -> void:
	_path = "user://"+name+".json" if name.is_valid_identifier() or name == DEFAULT_NAME else ""
	bindings = _defaults()

static func _defaults(legacy := false) -> Dictionary:
	var all := GLOBAL.duplicate()
	all.merge(BATTLE)
	all.merge(COMMAND)
	for i in range(1,10):
		all["select_" + str(i)] = [KEY_0+i]
	if not legacy:
		all.command_mode = [KEY_B,"j/4"]
		all.sprint = ["j/7"]
		all.crouch = [KEY_Z,"j/8"]
		all.interact = [KEY_F,"j/2"]
		all.mount = ["j/3"]
		all.dismount = ["j/12"]
		all.cancel_attack = ["j/1"]
		all.equip_melee = [KEY_KP_1,"j/13"]
		all.equip_ranged = [KEY_KP_2,"j/14"]
		for action in FIELD_KEYS: all[action] = [FIELD_KEYS[action]]
		all["inventory"] = [KEY_I]
		for i in range(1,10): all["order_key_"+str(i)] = [KEY_F1+i-1]
	var result := {}
	for action in all:
		var slots := {}
		for code in all[action]:
			var token := "k/%d/0" % code if typeof(code) == TYPE_INT else str(code)
			slots[family(token)] = token
		result[action] = slots
	return result

static func family(token: String) -> String:
	return "pad" if token.begins_with("a/") or token.begins_with("j/") else "desktop"

static func scope(action: String) -> String:
	if GLOBAL.has(action): return "global"
	if action.begins_with("order_key_") or action in ["scoreboard","inventory"]: return "field"
	if FIELD_KEYS.has(action): return "battle"
	return "battle" if BATTLE.has(action) else "command"

static func _overlap(a: String, b: String) -> bool:
	return scope(a) == scope(b) or scope(a) in ["global","field"] or scope(b) in ["global","field"]

static func _formation_key(action: String) -> bool:
	return action=="select_all" or (action.begins_with("select_") and action.trim_prefix("select_").is_valid_int())

static func token_for(event: InputEvent) -> String:
	var mods := 0
	if event is InputEventWithModifiers:
		mods = int(event.shift_pressed) + 2*int(event.ctrl_pressed) + 4*int(event.alt_pressed) + 8*int(event.meta_pressed)
	if event is InputEventKey:
		var code: int = event.physical_keycode if event.physical_keycode else event.keycode
		if code in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]: mods = 0
		return "k/%d/%d" % [code, mods] if code > 0 else ""
	if event is InputEventMouseButton:
		return "m/%d/%d" % [event.button_index, mods]
	if event is InputEventJoypadButton:
		return "j/%d" % event.button_index
	if event is InputEventJoypadMotion and absf(event.axis_value) >= 0.5:
		return "a/%d/%s" % [event.axis, "+" if event.axis_value > 0 else "-"]
	return ""

func action_for(token: String, mode: String) -> String:
	if mode=="inventory" and bindings.inventory.get(family(token))==token: return "inventory"
	for action in bindings:
		if scope(action) not in [mode,"global"] and not (scope(action)=="field" and mode in ["battle","command"]):
			continue
		if bindings[action].get(family(token)) == token:
			return action
	if mode=="command":
		for action in ["look_left","look_right","look_up","look_down"]:
			if bindings[action].get(family(token))==token: return action
	# In battle an existing explicit equipment binding takes precedence over the
	# optional formation shortcut. Legacy battle/command bindings can coexist.
	if mode=="battle" and family(token)=="desktop":
		for action in bindings:
			if _formation_key(action) and bindings[action].get("desktop")==token: return action
	return ""

func key_label(action: String) -> String:
	return desktop_key_name(bindings.get(action,{}).get("desktop",""))

static func desktop_key_name(token: String) -> String:
	if token.is_empty(): return "—"
	var parts := token.split("/")
	if parts.size()!=3: return token
	var flags := int(parts[2])
	var prefix := ""
	for bit in [[1,"Shift+"],[2,"Ctrl+"],[4,"Alt+"],[8,"Meta+"]]:
		if flags & bit[0]: prefix += bit[1]
	if parts[0]=="m":
		var buttons := {"1":"LMB","2":"RMB","3":"MMB","4":"Wheel ↑","5":"Wheel ↓"}
		return prefix+str(buttons.get(parts[1],"M"+parts[1]))
	var code := int(parts[1])
	if DisplayServer.get_name()!="headless": code = DisplayServer.keyboard_get_keycode_from_physical(code)
	return prefix+OS.get_keycode_string(code)

func _set_binding(table: Dictionary, action: String, token: String) -> Dictionary:
	if not table.has(action) or token.is_empty():
		return R.fail("InvalidArgument","binding")
	var parts := token.split("/")
	if parts.size() < 2 or not parts[1].is_valid_int():
		return R.fail("InvalidArgument","binding")
	var n := parts[1].to_int()
	match parts[0]:
		"k","m":
			if parts.size() != 3 or n <= 0 or not parts[2].is_valid_int() or not V.integer(parts[2].to_int(),0,15):
				return R.fail("InvalidArgument","binding")
		"j":
			if parts.size() != 2 or not V.integer(n,0,JOY_BUTTON_MAX-1): return R.fail("InvalidArgument","binding")
		"a":
			if parts.size() != 3 or not V.integer(n,0,JOY_AXIS_MAX-1) or parts[2] not in ["+","-"]: return R.fail("InvalidArgument","binding")
		_: return R.fail("InvalidArgument","binding")
	if action == "menu":
		return R.fail("Unauthorized","reserved_menu")
	for other in table:
		if other != action and _overlap(action,other) and table[other].get(family(token)) == token:
			return R.fail("Conflict","binding." + other)
	table[action][family(token)] = token
	return R.ok()

static func _settings(candidate: Dictionary) -> bool:
	if candidate.size() != OPTIONS.size():
		return false
	for key in OPTIONS:
		var value: Variant = candidate.get(key)
		if typeof(OPTIONS[key]) == TYPE_BOOL:
			if typeof(value) != TYPE_BOOL: return false
		elif key == "deadzone_percent":
			if not V.integer(value,0,95): return false
		elif not V.integer(value,1,1000000):
			return false
	return true

func _save(table: Dictionary, settings: Dictionary) -> Dictionary:
	if _path.is_empty(): return R.fail("InvalidArgument","input_profile")
	var bytes := C.encode({"bindings":table,"options":settings})
	if not bytes.ok: return bytes
	var temp := _path + "." + ResourceUID.id_to_text(ResourceUID.create_id()).trim_prefix("uid://") + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null: return R.fail("Unavailable","input_profile")
	file.store_buffer(bytes.value)
	file.flush()
	var success := file.get_error() == OK
	file.close()
	if not success or DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),ProjectSettings.globalize_path(_path)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp))
		return R.fail("Unavailable","input_profile")
	bindings = table
	options = settings
	return R.ok()

func rebind(action: String, event: InputEvent) -> Dictionary:
	var table := bindings.duplicate(true)
	var result := _set_binding(table,action,token_for(event))
	return _save(table,options) if result.ok else result

func set_options(changes: Dictionary) -> Dictionary:
	var candidate := options.duplicate()
	candidate.merge(changes,true)
	return _save(bindings,candidate) if _settings(candidate) else R.fail("InvalidArgument","input_options")

func load_saved() -> Dictionary:
	if _path.is_empty(): return R.fail("InvalidArgument","input_profile")
	if not FileAccess.file_exists(_path): return R.ok()
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null or file.get_length() > 32768: return R.fail("InvalidArgument","input_profile")
	var decoded := C.decode(file.get_buffer(file.get_length()))
	if not decoded.ok or typeof(decoded.value) != TYPE_DICTIONARY: return R.fail("InvalidArgument","input_profile")
	var data: Dictionary = decoded.value
	if typeof(data.get("options")) != TYPE_DICTIONARY or not _settings(data.options) or typeof(data.get("bindings")) != TYPE_DICTIONARY:
		return R.fail("InvalidArgument","input_profile")
	var legacy: bool = not data.bindings.has("view_toggle")
	var defaults := _defaults(legacy)
	var prior_field_layout: bool = not legacy and not data.bindings.has("inventory")
	if prior_field_layout: defaults.erase("inventory")
	if data.bindings.size()!=defaults.size(): return R.fail("InvalidArgument","input_profile")
	var table := defaults.duplicate(true)
	if typeof(data.bindings.get("menu")) != TYPE_DICTIONARY or data.bindings.menu != table.menu: return R.fail("InvalidArgument","reserved_menu")
	# Validate the finished map, allowing a pair of bindings that changed places.
	for action in table:
		if typeof(data.bindings.get(action)) != TYPE_DICTIONARY: return R.fail("InvalidArgument","binding")
		table[action] = {} if action != "menu" else table.menu
	for action in table:
		if action == "menu": continue
		var slots: Dictionary = data.bindings[action]
		if legacy and slots.is_empty(): return R.fail("InvalidArgument","binding")
		for slot in slots:
			var token: Variant = slots[slot]
			if typeof(token) != TYPE_STRING or family(token) != slot or not _set_binding(table,action,token).ok:
				return R.fail("InvalidArgument","binding")
	if legacy:
		# Keep player overrides first, then install only new defaults whose keys are free.
		var modern := _defaults()
		var migrated := {}
		for action in modern: migrated[action] = {} if action!="menu" else modern.menu
		for action in table:
			for slot in table[action]:
				if table[action][slot] != defaults[action].get(slot):
					var retained := _set_binding(migrated,action,table[action][slot])
					if not retained.ok: return retained
		for action in modern:
			for slot in modern[action]:
				if not migrated[action].has(slot): _set_binding(migrated,action,modern[action][slot])
		table = migrated
	elif prior_field_layout:
		# An existing custom binding keeps I. The pack is also reachable from the menu.
		table["inventory"] = {}
		_set_binding(table,"inventory","k/%d/0"%KEY_I)
	bindings = table
	options = data.options.duplicate()
	return R.ok()
