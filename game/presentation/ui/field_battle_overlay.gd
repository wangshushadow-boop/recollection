extends Control
## Read-only HUD for the player camera. Never takes input away from the battlefield.
const TacticalMap = preload("res://presentation/ui/field_tactical_map.gd")
const Ink := Color("#221f1ce8")
const Brass := Color("#ad8a51")
const Parchment := Color("#f2e7cd")
const Own := Color("#ad5344")
const Enemy := Color("#438194")

var balance := HBoxContainer.new()
var ally := Label.new()
var enemy := Label.new()
var meter := ProgressBar.new()
var equipment := VBoxContainer.new()
var weapon := Label.new()
var identity := Label.new()
var stamina := Label.new()
var morale := Label.new()
var mount_state := Label.new()
var tactical := TacticalMap.new()
var health := Label.new()
var health_bar := ProgressBar.new()
var formations := HFlowContainer.new()
var orders := HFlowContainer.new()
var order_box := VBoxContainer.new()
var board := PanelContainer.new()
var board_title := Label.new()
var board_body := Label.new()
var ledger := GridContainer.new()
var hints := Label.new()
var notice := Label.new()

static func frame(fill: Color, border: Color, margin := 6) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	for side in [SIDE_LEFT,SIDE_TOP,SIDE_RIGHT,SIDE_BOTTOM]: box.set_content_margin(side,margin)
	return box

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := _plate("Balance",balance)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.offset_top = 12
	ally.modulate = Color("#ffc4af")
	enemy.modulate = Color("#bfe1ea")
	balance.add_child(ally)
	balance.add_child(meter)
	balance.add_child(enemy)
	balance.add_theme_constant_override("separation",8)
	meter.custom_minimum_size = Vector2(144,7)
	meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	meter.show_percentage = false
	meter.add_theme_stylebox_override("background",frame(Enemy,Enemy,0))
	meter.add_theme_stylebox_override("fill",frame(Own,Own,0))
	var gear := _plate("Equipment",equipment)
	gear.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	gear.offset_right = -16
	gear.offset_bottom = -15
	gear.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	gear.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var heading := HBoxContainer.new()
	equipment.add_child(heading)
	heading.add_child(identity)
	heading.add_child(mount_state)
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.name = "PlayerIdentity"
	identity.modulate = Color("#f5d593")
	mount_state.name = "PlayerMount"
	mount_state.modulate = Color("#d1c6af")
	equipment.add_child(HSeparator.new())
	var vitality := HBoxContainer.new()
	equipment.add_child(vitality)
	vitality.add_child(health_bar)
	vitality.add_child(health)
	vitality.add_theme_constant_override("separation",8)
	health_bar.name = "HealthBar"
	health_bar.custom_minimum_size = Vector2(95,8)
	health_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	health_bar.show_percentage = false
	health_bar.add_theme_stylebox_override("background",frame(Color("#382922"),Brass,0))
	health_bar.add_theme_stylebox_override("fill",frame(Color("#bf5943"),Color("#d28c65"),0))
	weapon.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	health.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	health.name = "PlayerHealth"
	health.modulate = Color("#ffd7a4")
	morale.name = "PlayerMorale"
	morale.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var condition := HBoxContainer.new()
	equipment.add_child(condition)
	condition.add_theme_constant_override("separation",14)
	stamina.name = "PlayerStamina"
	stamina.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stamina.modulate = Color("#d9d6a5")
	condition.add_child(stamina)
	condition.add_child(morale)
	weapon.name = "PlayerWeapon"
	equipment.add_child(weapon)
	tactical.name = "TacticalMap"
	add_child(tactical)
	tactical.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	board.name = "ScorePanel"
	add_child(board)
	board.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	board.grow_vertical = Control.GROW_DIRECTION_BOTH
	board.add_theme_stylebox_override("panel",frame(Ink,Brass,16))
	var tally := VBoxContainer.new()
	board.add_child(tally)
	tally.add_child(board_title)
	board_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	board_title.modulate = Color("#edc67f")
	tally.add_child(HSeparator.new())
	tally.add_child(ledger)
	ledger.name = "ScoreTable"
	ledger.add_theme_constant_override("h_separation",6)
	tally.add_child(HSeparator.new())
	tally.add_child(board_body)
	board_body.name = "FieldInfo"
	board_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_body.add_theme_constant_override("line_spacing",7)
	board.hide()
	add_child(order_box)
	order_box.offset_left = 16
	order_box.offset_top = 66
	order_box.anchor_right = 1
	order_box.offset_right = -16
	order_box.add_theme_constant_override("separation",6)
	order_box.add_child(formations)
	formations.name = "FormationCards"
	order_box.add_child(orders)
	orders.name = "OrderCards"
	for pair in [[hints,"FieldHints"],[notice,"FieldNotice"]]:
		var label: Label = pair[0]
		label.name = pair[1]
		add_child(label)
		label.anchor_top = 1
		label.anchor_bottom = 1
		label.offset_left = 16
		label.grow_vertical = Control.GROW_DIRECTION_BEGIN
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_outline_color",Color("#1a1513"))
		label.add_theme_constant_override("outline_size",5)
	hints.offset_bottom = -15
	notice.offset_bottom = -72
	notice.modulate = Color("#ffe3ac")
	for child in find_children("*","Control",true,false):
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_resize)
	_resize()

func _plate(id: String, content: Container) -> PanelContainer:
	var plate := PanelContainer.new()
	plate.name = id
	add_child(plate)
	plate.add_theme_stylebox_override("panel",frame(Ink,Brass))
	plate.add_child(content)
	return plate

func _resize() -> void:
	var half := minf(size.x*.46,260)
	var diameter := clampf(minf(size.x*.17,size.y*.24),100,150)
	tactical.offset_left = 14
	tactical.offset_right = 14+diameter
	tactical.offset_bottom = -48
	tactical.offset_top = -65-diameter
	board.offset_left = -half
	board.offset_right = half
	hints.offset_right = maxf(70,size.x*.52)
	notice.offset_left = tactical.offset_right+10
	notice.offset_right = maxf(notice.offset_left+70,size.x*.70)

func set_strength(own_count: int, enemy_count: int, own_label: String, enemy_label: String) -> void:
	balance.get_parent().visible = own_count>=0
	ally.text = "%s  %d" % [own_label,own_count]
	enemy.text = "%d  %s" % [enemy_count,enemy_label]
	meter.max_value = maxi(1,own_count+enemy_count)
	meter.value = own_count

func set_cards(row: HFlowContainer, entries: Array) -> void:
	# Reuse labels between ticks, including while troop counts change.
	for i in entries.size():
		var item: Label
		if i>=row.get_child_count():
			item = Label.new()
			item.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item.add_theme_color_override("font_color",Parchment)
			row.add_child(item)
		else: item = row.get_child(i)
		var entry: Array = entries[i]
		item.text = entry[0]
		var marked: bool = entry[1]
		if not item.has_meta("marked") or item.get_meta("marked")!=marked:
			item.add_theme_stylebox_override("normal",frame(Color("#5a4729f0") if marked else Ink,Color("#ebc784") if marked else Brass))
			item.set_meta("marked",marked)
		item.show()
	for i in range(entries.size(),row.get_child_count()): row.get_child(i).hide()

func set_score(rows: Array) -> void:
	ledger.columns = rows[0].size()
	var index := 0
	for row_index in rows.size():
		for col in ledger.columns:
			var cell: Label
			if index>=ledger.get_child_count():
				cell = Label.new()
				cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				cell.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				ledger.add_child(cell)
			else: cell = ledger.get_child(index)
			cell.text = str(rows[row_index][col])
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if col==0 else HORIZONTAL_ALIGNMENT_CENTER
			cell.modulate = Color("#e2c994") if row_index==0 else Parchment
			cell.show()
			index += 1
	for i in range(index,ledger.get_child_count()): ledger.get_child(i).hide()
