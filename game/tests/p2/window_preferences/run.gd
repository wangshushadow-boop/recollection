extends SceneTree
## Each case runs the desktop composition in a fresh native window.
var main: Node
var failures := 0
const NORMAL := Vector2i(1112,704)

func _initialize() -> void:
	run.call_deferred()

func frames() -> void:
	for i in 5: await process_frame

func check(condition: bool, label: String) -> void:
	if not condition:
		failures+=1
		printerr("FAIL ",label," actual_size=",root.size," actual_mode=",root.mode)

func run() -> void:
	main=load("res://bootstrap/main.tscn").instantiate()
	root.add_child(main)
	await frames()
	var sample := OS.get_environment("RECOLLECTION_WINDOW_CASE")
	var restored := root.size
	var restored_mode := root.mode
	match sample:
		"resize":
			check(root.size==Vector2i(960,600),"first launch")
			root.size=NORMAL
			await frames()
		"maximize":
			check(root.size==NORMAL and root.mode==Window.MODE_WINDOWED,"window size restored")
			root.mode=Window.MODE_MAXIMIZED
			await frames()
			check(root.mode==Window.MODE_MAXIMIZED,"maximized")
		"minimize":
			check(root.mode==Window.MODE_MAXIMIZED,"maximized after relaunch")
			root.mode=Window.MODE_MINIMIZED
			await frames()
			check(root.mode==Window.MODE_MINIMIZED,"minimized")
		"unmaximize":
			check(root.mode==Window.MODE_MAXIMIZED,"minimized close retained prior maximize")
			root.mode=Window.MODE_WINDOWED
			await frames()
			check(root.size==NORMAL,"maximized retained prior normal geometry")
		"override":
			check(root.mode==Window.MODE_WINDOWED and root.size==Vector2i(980,620),"explicit test resolution wins")
		"read":
			check(root.mode==Window.MODE_WINDOWED and root.size==NORMAL,"CLI test left saved size intact")
		"clamp":
			var work := DisplayServer.screen_get_usable_rect(root.current_screen)
			check(work.encloses(Rect2i(root.get_position_with_decorations(),root.get_size_with_decorations())),"oversized saved window fits current monitor")
		_: check(false,"unknown test case")
	print("WINDOW_PREF ",sample," start=",restored," mode=",restored_mode," end=",root.size," mode=",root.mode," failures=",failures)
	if failures:
		quit(1)
	else:
		main.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
