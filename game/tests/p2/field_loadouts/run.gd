extends SceneTree
const Compiler = preload("res://infrastructure/content/compiler.gd")
const FIELD := "res://content/base/field"
var errors := 0

func check(ok: bool, msg: String) -> void:
	if not ok:
		errors += 1
		printerr("FAIL ", msg)

func _initialize() -> void:
	var service := Compiler.new()
	var compiled := service.compile(service.scan_packages([Compiler.BASE_PACKAGE,FIELD]),{})
	if not compiled.ok:
		printerr("FAIL field content ", compiled)
		quit(1)
		return
	var defs: RefCounted = compiled.value.registry
	check(defs.get_definition("field:scene/river_plain","scene").value.metadata.allow_jump,"River Plain allows jumping")
	for role in ["infantry","archer","cavalry","mounted_archer"]:
		var troop: Dictionary = defs.get_definition("field:troop/"+role,"troop").value
		check(troop.role==role and troop.equipment_set_ids.size()==1,"troop equipment "+role)
		var kit: Dictionary = defs.get_definition(troop.equipment_set_ids[0],"equipment").value
		check(kit.slots.has("melee") and kit.slots.has("mount")==(role in ["cavalry","mounted_archer"]),"mount and melee "+role)
		check(kit.slots.has("ranged")==(role in ["archer","mounted_archer"]),"ranged "+role)
		for slot in kit.slots:
			var item: Dictionary = defs.get_definition(kit.slots[slot],"item").value
			check(slot in item.slot_tags and FileAccess.file_exists(FIELD.path_join(item.asset_ref)),"asset "+slot)
			if slot=="melee": check(item.category=={"archer":"blade","cavalry":"halberd","mounted_archer":"halberd","infantry":"spear"}[role],"melee equipment")
			if slot=="ranged": check(item.category==("bow" if role=="mounted_archer" else "crossbow"),"bow or crossbow")
	var prop := load(FIELD+"/short_bow.tscn") as PackedScene
	var figure: Node = prop.instantiate()
	check(figure.has_node("Segment6") and figure.has_node("UpperString") and figure.has_node("LowerString") and figure.has_node("NockedArrow/Shaft"),"short bow limbs, drawstring and arrow")
	figure.free()
	print("Field troop loadouts ", "PASS" if errors==0 else "FAIL", " digest=",compiled.value.hash)
	quit(1 if errors else 0)
