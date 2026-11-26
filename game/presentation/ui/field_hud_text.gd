extends RefCounted

# Battle terminology shared by the controls and their command receipts.
const WORDS := {
	"deployment":["野战布阵","Order of battle"], "battle":["野战 · 指挥","Field command"],
	"commander":["主将","Commander"],"on_foot":["步战","On foot"],"on_horse":["骑乘","Mounted"],
	"map_range":["战图  ·  半径 70 米","Battle map  ·  70 m radius"],"north":["北","N"],
	"formation_card":["编队","Formation"],
	"ended":["战果","Battle result"], "select":["选择编队","Formations"],
	"layout":["阵型","Formation"], "zone":["部署区","Deployment zone"], "target":["目标","Target"],
	"pick":["选择…","Choose…"], "mark":["预览部署","Place units"], "reset":["重置部署","Reset plan"],
	"deploy":["开始野战","Begin battle"], "hold":["坚守","Hold"], "charge":["冲锋","Charge"],
	"battle_menu":["战斗菜单","Battle menu"], "command_book":["部队指挥","Army orders"],
	"back_menu":["返回","Back"],"delegated":["已委派军官","Officer in command"],
	"choose_target":["请选择有效目标","Choose a valid target"],"binding_taken":["按键已占用","Binding already in use"],
	"melee":["近战兵器","Melee weapon"],"bow":["弓","Bow"],"crossbow":["弩","Crossbow"],"throw":["投掷兵器","Throwing weapon"],
	"infantry":["步兵","Infantry"],"archer":["弓手","Archers"],"cavalry":["骑兵","Cavalry"],
	"mounted_archer":["弓骑兵","Horse archers"],"mixed":["混编","Mixed troops"],"await_deploy":["待部署","Awaiting deployment"],
	"side":["阵营","Side"],"free_attack":["冲锋","Charge"],"thrust":["刺","Thrust"],
	"move":["移动","Move"], "set_layout":["变阵","Apply layout"], "delegate":["委派","Delegate"],
	"withdraw":["本方撤退","Withdraw our side"], "confirm":["确认撤退","Confirm withdrawal"],
	"cancel":["取消","Cancel"], "spectate":["观战","Spectate"], "leave":["返回","Return"],
	"line":["横列","Line"], "shield_wall":["盾墙","Shield wall"], "loose":["散阵","Loose"],
	"square":["方阵","Square"], "circle":["圆阵","Circle"], "wedge":["楔形","Wedge"], "column":["纵队","Column"],
	"ready":["在场","Ready"], "reserve":["预备","Reserve"], "routed":["溃逃","Routed"],
	"own":["本方","Own"], "other":["对方","Opposing"], "withdrawn":["已撤退","Withdrawn"],
	"hp":["生命","Health"], "ammo":["弹药","Ammo"], "morale":["士气","Morale"],
	"direction":["攻向","Direction"], "up":["上","Up"], "right":["右","Right"],
	"left":["左","Left"], "down":["下","Down"], "downed":["主将倒地","Commander down"],
	"settings":["显示设置","Display settings"], "large":["大字号","Larger type"],
	"contrast":["高对比","High contrast"], "captions":["字幕","Captions"], "rebind":["更改绑定","Change binding"],
	"binding":["动作","Action"], "command_mode":["指挥模式","Command mode"], "attack":["攻击","Attack"],
	"block":["格挡","Block"], "cancel_attack":["取消攻击","Cancel attack"], "sprint":["疾跑","Sprint"],
	"crouch":["蹲伏","Crouch"], "jump":["跳跃","Jump"], "move_left":["左移","Move left"],
	"move_right":["右移","Move right"], "move_forward":["前进","Move forward"], "move_back":["后退","Move back"],
	"look_left":["左看","Look left"], "look_right":["右看","Look right"], "look_up":["上看","Look up"],
	"look_down":["下看","Look down"], "equip_melee":["装备近战武器","Equip melee weapon"],
	"equip_ranged":["装备远程武器","Equip ranged weapon"], "interact":["互动","Interact"],
	"mount":["上马","Mount"], "dismount":["下马","Dismount"], "select_all":["选中全部","Select all"],
	"select_prev":["上一编队","Previous formation"], "select_next":["下一编队","Next formation"],
	"order_move":["命令移动","Order move"], "order_charge":["命令冲锋","Order charge"],
	"order_hold":["命令坚守","Order hold"], "cycle_layout":["切换阵型","Cycle layout"],
	"order_cancel":["取消命令","Cancel order"],
	"key":["请按新按键（Esc 取消）","Press a new key (Esc cancels)"], "language":["English","中文"],
	"controller":["返回战场控制","Resume field controls"], "accepted":["已提交","Submitted"],
	"movement":["移动命令","Movement orders"], "formation":["阵型命令","Formation orders"], "toggle":["战术命令","Tactical orders"],
	"follow":["跟随","Follow"], "advance":["推进","Advance"], "retreat":["撤退","Retreat"],
	"face":["朝向指定方向","Face direction"], "face_enemy":["面向敌人","Face enemy"],
	"toggle_fire":["切换射击","Toggle fire"], "toggle_mount":["切换骑乘","Mount / dismount"],
	"toggle_delegate":["切换委派","Toggle delegation"], "menu":["菜单","Menu"],
	"view_toggle":["切换视角","Switch view"], "zoom":["拉近视野","Zoom"], "free_look":["自由环视","Free look"],
	"scoreboard":["战况","Battle status"], "weapon_next":["下一件武器","Next weapon"], "walk_toggle":["步行／跑步","Walk / run"],
	"camera_nearer":["拉近第三人称镜头","Closer chase camera"], "camera_farther":["拉远第三人称镜头","Farther chase camera"],
	"queued":["已排队","Queued"], "active":["执行中","Active"], "completed":["完成","Complete"],
	"denied":["拒绝","Denied"], "failed":["失败","Failed"], "cancelled":["已取消","Cancelled"],
	"victory":["获胜","Victory"], "defeat":["失利","Defeat"], "draw":["平局","Draw"],
	"winners":["胜方","Winners"], "slots":["兵员结局","Roster outcomes"],
	"fallen":["阵亡","Fallen"], "wounded":["负伤","Wounded"], "survived":["存活","Survived"],
	"killed":["阵亡","Killed"], "captured":["被俘","Captured"], "survivor":["生还","Survivor"],
	"authority":["可指挥","Controllable"], "readonly":["仅查看","View only"], "objective":["目标","Objective"],
	"point":["目标点（米）","Target point (m)"], "preview":["部署预览","Deployment preview"],
	"Unavailable":["暂时不可用","Unavailable"], "Unauthorized":["无指挥权限","Unauthorized"],
	"StaleVersion":["画面已过期","View expired"], "Conflict":["命令冲突","Conflict"],
	"InvalidArgument":["参数无效","Invalid argument"], "InvalidState":["当前不可操作","Unavailable in this state"],
	"NotFound":["找不到目标","Target missing"], "NoRoute":["无法到达","Unreachable"],
	"confirm_hint":["撤出本方所有剩余兵力？","Withdraw all remaining troops on your side?"],
	"orders":["命令","Orders"], "casualties":["伤亡","Casualties"],
	"Pending":["待处理","Pending"], "Accepted":["已受理","Accepted"], "Executing":["执行中","Executing"],
	"Completed":["完成","Complete"], "Failed":["失败","Failed"], "Active":["执行中","Active"],
	"Replaced":["已替换","Replaced"], "player_priority":["主将命令优先","Commander takes priority"],
	"control_revoked":["权限已变更","Control revoked"], "superseded":["命令已替换","Order replaced"],
	"expired":["已过期","Expired"], "unreachable":["无法到达","Unreachable"], "invalid_target":["目标无效","Invalid target"],
	"not_spawned":["未上场","Not deployed"], "alive":["生还","Alive"], "dead":["阵亡","Dead"], "escaped":["脱离","Escaped"],
	"direct":["直接控制","Direct control"]
}

static func word(key: Variant, language: String) -> String:
	var name := str(key)
	return WORDS[name][int(language == "en")] if WORDS.has(name) else name

static func action_name(action: String, language: String) -> String:
	if action.begins_with("order_key_"):
		return ("兵令键 " if language=="zh" else "Order key ")+action.trim_prefix("order_key_")
	var slot := action.trim_prefix("select_")
	if action.begins_with("select_") and slot.is_valid_int():
		return ("选择编队 " if language=="zh" else "Select formation ")+slot
	return word(action,language)
