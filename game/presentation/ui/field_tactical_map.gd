extends Control
## North-up local map in world metres. The presentation projection owns visibility.
const RANGE_M := 70.0
const ALLY := Color("#ef9b7b")
const ENEMY := Color("#7bc9df")
const BRONZE := Color("#ae9466")
var _allies := PackedVector2Array()
var _enemies := PackedVector2Array()
var _rallies := PackedVector2Array()
var _objectives := PackedVector2Array()
var _origin := Vector2.ZERO
var _heading := Vector2.UP
var _sample_origin := Vector2.ZERO
var _ally_marks := PackedVector2Array()
var _enemy_marks := PackedVector2Array()
var _marks_dirty := true
var _sample := -1
var _caption := ""
var _north := "N"

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()

func clear_contacts() -> void:
	if not visible and _sample==-1: return
	hide()
	_sample = -1
	_allies = PackedVector2Array()
	_enemies = PackedVector2Array()
	_rallies = PackedVector2Array()
	_objectives = PackedVector2Array()
	_ally_marks = PackedVector2Array()
	_enemy_marks = PackedVector2Array()
	_marks_dirty = true
	queue_redraw()

func show_contacts(data: Dictionary, caption: String, north: String) -> void:
	if not data.get("origin") is Vector3 or not data.get("heading") is Vector3:
		clear_contacts()
		return
	var p: Vector3 = data.origin
	var dir: Vector3 = data.heading
	var sample: int = data.get("sample_tick",-1)
	if visible and sample>=0 and _sample==sample and _caption==caption and _origin==Vector2(p.x,p.z) and _heading==Vector2(dir.x,dir.z): return
	_origin = Vector2(p.x,p.z)
	_heading = Vector2(dir.x,dir.z)
	if _sample!=sample or sample<0 or not visible:
		_sample_origin = _origin
		_allies = data.get("allies",PackedVector2Array())
		_enemies = data.get("enemies",PackedVector2Array())
		_rallies = data.get("rallies",PackedVector2Array())
		_objectives = data.get("objectives",PackedVector2Array())
		_marks_dirty = true
	_sample = sample
	_caption = caption
	_north = north
	show()
	queue_redraw()

func _draw() -> void:
	var center := Vector2(size.x*.5,(size.y-17)*.5)
	var edge := minf(center.x, center.y)-5
	if edge<=8: return
	draw_circle(center,edge+4,Color("#201e18eb"),true,-1,true)
	draw_circle(center,edge,Color("#30372cec"),true,-1,true)
	draw_arc(center,edge+3,0,TAU,96,BRONZE,1.5,true)
	draw_arc(center,edge-2,0,TAU,96,Color("#b8b08b80"),1,true)
	draw_arc(center,edge*.5,0,TAU,64,Color("#c3c0a545"),1,true)
	for axis in [Vector2.UP,Vector2.RIGHT]:
		draw_line(center-axis*(edge-3),center+axis*(edge-3),Color("#b8b08b48"),1,true)
	var inner := edge-5
	if _marks_dirty:
		_ally_marks = _force_marks(_allies,center,inner,false)
		_enemy_marks = _force_marks(_enemies,center,inner,true)
		_marks_dirty = false
	if not _ally_marks.is_empty(): draw_multiline(_ally_marks,ALLY,1.8,true)
	if not _enemy_marks.is_empty(): draw_multiline(_enemy_marks,ENEMY,1.8,true)
	var gold := Color("#f4ce79")
	for site in _objectives:
		var rel := site-_sample_origin
		if rel.length_squared()>RANGE_M*RANGE_M: continue
		var point := center+rel*inner/RANGE_M
		draw_polyline(PackedVector2Array([point+Vector2.UP*4,point+Vector2.RIGHT*4,point+Vector2.DOWN*4,point+Vector2.LEFT*4,point+Vector2.UP*4]),gold,1.6,true)
	for site in _rallies:
		var rel := site-_sample_origin
		if rel.length_squared()>RANGE_M*RANGE_M: continue
		var point := center+rel*inner/RANGE_M
		draw_line(point+Vector2.DOWN*3,point+Vector2.UP*5,gold,1.7,true)
		draw_colored_polygon(PackedVector2Array([point+Vector2.UP*5,point+Vector2(6,-3),point+Vector2(0,-.5)]),gold)
	var player := center+(_origin-_sample_origin).limit_length(RANGE_M)*inner/RANGE_M
	var f := _heading.normalized() if not _heading.is_zero_approx() else Vector2.UP
	var side := Vector2(-f.y,f.x)
	var arrow := PackedVector2Array([player+f*7,player-f*5+side*4,player-f*2,player-f*5-side*4])
	draw_colored_polygon(arrow,Color("#fff2b3"))
	arrow.append(arrow[0])
	draw_polyline(arrow,Color("#402f18"),1,true)
	var font := get_theme_default_font()
	draw_string(font,Vector2(0,center.y-edge+12),_north,HORIZONTAL_ALIGNMENT_CENTER,size.x,11,Color("#f7dfab"))
	draw_string_outline(font,Vector2(0,size.y-2),_caption,HORIZONTAL_ALIGNMENT_CENTER,size.x,12,3,Color("#251f18"))
	draw_string(font,Vector2(0,size.y-2),_caption,HORIZONTAL_ALIGNMENT_CENTER,size.x,12,Color("#f4e4bb"))

func _notification(what: int) -> void:
	if what==NOTIFICATION_RESIZED: _marks_dirty = true

func _force_marks(points: PackedVector2Array, center: Vector2, radius: float, hostile: bool) -> PackedVector2Array:
	var marks := PackedVector2Array()
	for point in points:
		var rel := point-_sample_origin
		if rel.length_squared()>RANGE_M*RANGE_M: continue
		var pixel := center+rel*(radius/RANGE_M)
		var stroke := Vector2(1.15,-1.15) if hostile else Vector2(0,1.3)
		marks.append(pixel-stroke)
		marks.append(pixel+stroke)
	return marks
