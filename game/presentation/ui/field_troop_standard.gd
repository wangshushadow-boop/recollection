extends Control
## Original cloth standard carrying the troop arm's symbol.
var role := ""
var selected := false

func set_arm(arm: String, marked: bool) -> void:
	if role==arm and selected==marked: return
	role = arm
	selected = marked
	queue_redraw()

func _draw() -> void:
	var ink := Color("#fae4b2") if selected else Color("#dbceb4")
	var cloth := Color("#7e3d31") if selected else Color("#3f4a44")
	var flag := PackedVector2Array([Vector2(0,0),Vector2(26,0),Vector2(26,31),Vector2(13,39),Vector2(0,31)])
	draw_colored_polygon(flag,cloth)
	flag.append(flag[0])
	draw_polyline(flag,Color("#ba9c6c"),1,true)
	match role:
		"archer","mounted_archer":
			draw_polyline(PackedVector2Array([Vector2(8,7),Vector2(15,12),Vector2(18,17),Vector2(15,23),Vector2(8,27),Vector2(8,7)]),ink,1.6,true)
			draw_line(Vector2(4,17),Vector2(21,17),ink,1.5,true)
			draw_polyline(PackedVector2Array([Vector2(18,14),Vector2(21,17),Vector2(18,20)]),ink,1.3,true)
			if role=="mounted_archer": draw_arc(Vector2(13,30),3,0,PI,9,ink,1.5,true)
		"cavalry":
			draw_polyline(PackedVector2Array([Vector2(5,10),Vector2(5,20),Vector2(8,25),Vector2(13,27),Vector2(18,25),Vector2(21,20),Vector2(21,10)]),ink,3,true)
			draw_line(Vector2(3,10),Vector2(8,10),ink,2)
			draw_line(Vector2(18,10),Vector2(23,10),ink,2)
		_:
			draw_colored_polygon(PackedVector2Array([Vector2(13,5),Vector2(16,13),Vector2(14,21),Vector2(12,21),Vector2(10,13)]),ink)
			draw_line(Vector2(8,22),Vector2(18,22),ink,1.8)
			draw_line(Vector2(13,22),Vector2(13,29),ink,2)
