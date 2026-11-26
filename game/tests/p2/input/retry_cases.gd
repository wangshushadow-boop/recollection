extends "res://tests/p2/input/run.gd"
## Timing and transport regressions. Keep the original full-device scenario intact.
var batch_replies := []
var order_replies := {}
var received_batches := []
var order_attempts := []
var order_revisions := []

func batch_port(batch: Dictionary) -> Dictionary:
	received_batches.append(batch)
	return batch_replies.pop_front() if not batch_replies.is_empty() else R.ok()

func order_port(order: Dictionary, revisions: Dictionary) -> Dictionary:
	order_attempts.append(order)
	order_revisions.append(revisions)
	var replies: Array = order_replies.get(order.client_sequence,[])
	return replies.pop_front() if not replies.is_empty() else R.ok(order.order_id)

func router() -> Field:
	var player := Field.new(profile_name)
	root.add_child(player)
	check(player.configure("input","actor",H,4,batch_port,order_port).ok,"retry router")
	received_batches.clear()
	order_attempts.clear()
	order_revisions.clear()
	batch_replies.clear()
	order_replies.clear()
	return player

func edges(field: Field, tick: int) -> Array:
	return field.step(tick).value.batch.inputs.filter(func(i): return i.has("input_phase")).map(func(i): return i.input_phase)

func retry_streams() -> bool:
	var player := router()
	var busy := R.fail("Unavailable","field")
	batch_replies = [busy,R.ok()]
	order_replies[2] = [busy,busy,R.ok()]
	order_replies[3] = [R.fail("Unauthorized","formation_ids")]
	player.set_context("command")
	player.set_formations([3],{3:4})
	player.select_formations([3])
	for kind in ["hold","advance","hold_fire","cancel"]:
		check(player.queue_order(kind).ok,"queue "+kind)
	var first := player.step(1)
	check(first.ok and first.value.batch_receipt == busy and first.value.orders[0].receipt.ok and first.value.orders[1].receipt == busy,"initial independent receipts")
	check(order_attempts.size() == 2 and received_batches.size() == 1,"order sequence waits for unconfirmed predecessor")
	player.set_formations([3],{3:9})
	var second := player.step(1)
	check(second.value.batch_receipt.ok and second.value.orders[0].receipt.ok and second.value.orders[1].receipt == busy,"same tick retries pending ports independently")
	check(received_batches.size()==2 and received_batches[0]==received_batches[1] and order_attempts.size()==3 and order_attempts[1]==order_attempts[2],"immutable retry payloads")
	var third := player.step(1)
	var sequences := order_attempts.map(func(o): return o.client_sequence)
	check(sequences==[1,2,2,2,3,4] and third.value.orders[2].receipt.error.code=="Unauthorized" and third.value.orders[3].receipt.ok,"complete accepted and refused orders in original sequence")
	check(order_revisions.all(func(r):return r=={3:4}) and order_attempts.all(func(o):return o.issued_tick==1),"retry uses original tick and control versions")
	check(player.step(1)==third and received_batches.size()==2 and order_attempts.size()==6,"terminal success and nonretryable rejection never resent")
	check(player.queue_order("advance").ok and player.step(2).value.orders.size()==1 and order_revisions.back()=={3:9},"fresh commands use current revision")
	player.free()
	return true

func retry_ticks() -> bool:
	var player := router()
	var busy := R.fail("Unavailable","simulation")
	batch_replies = [busy,busy,R.ok(),R.ok()]
	player.handle_event(mouse(1))
	var first := player.step(1)
	player.handle_event(mouse(1,false))
	check(first.value.batch_receipt == busy and player.step(2).error.field=="previous_input_tick","later tick cannot drop an unresolved start")
	var next := player.step(2)
	check(next.value.batch_receipt.ok and received_batches.map(func(b):return b.source_tick)==[1,1,1,2],"recover original before sampling later tick")
	check(received_batches.slice(0,3).all(func(b):return b==first.value.batch) and next.value.batch.inputs.any(func(i):return i.get("input_phase")=="release"),"later release kept separate from the retry")
	batch_replies = [busy,R.fail("Unauthorized","grant")]
	player.handle_event(mouse(1))
	check(player.step(3).value.batch_receipt==busy and player.step(3).value.batch_receipt.error.code=="Unauthorized","retry stops on terminal error")
	var attempts := received_batches.size()
	player.step(3)
	check(received_batches.size()==attempts and edges(player,4).is_empty(),"denied start does not become hold")
	player.handle_event(mouse(1,false))
	batch_replies = [busy]
	player.handle_event(mouse(1))
	check(player.step(5).value.batch_receipt==busy,"pending at handoff")
	attempts = received_batches.size()
	player.set_control({"index":7,"generation":2},8)
	check(player.step(5).value.batch_receipt.error.code=="StaleVersion" and received_batches.size()==attempts,"old authority never reissued across handoff")
	player.free()
	return true

func menu_and_cancel() -> bool:
	combat = Combat.new()
	check(combat.enlist(H,{"team":0,"role":"infantry"}).ok,"combat fixture")
	var player := fresh_field()
	player.bind_combat_view(combat.view)
	player.handle_event(mouse(1))
	player.handle_event(mouse(1,false))
	check(edges(player,1)==["start"] and combat.view(H).value.phase=="Windup","quick tap buffered")
	player.handle_event(mouse(MOUSE_BUTTON_RIGHT))
	player.handle_event(mouse(MOUSE_BUTTON_RIGHT,false))
	check(edges(player,2)==["cancel"] and combat.view(H).value.phase=="Ready","explicit cancel acts on pending release")
	for tick in range(3,8):
		check(edges(player,tick).is_empty(),"cancelled attack cannot fire later")
	var focus := Button.new()
	root.add_child(focus)
	for event in [key(KEY_ESCAPE),joy(JOY_BUTTON_START)]:
		player.set_context("ui")
		focus.grab_focus()
		await process_frame
		Input.parse_input_event(key(KEY_W))
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await process_frame
		check(player.view().mode=="battle" and root.gui_get_focus_owner()==null,"focused widget admits only reserved menu escape")
		event.pressed = false
		Input.parse_input_event(event)
		Input.parse_input_event(key(KEY_W,false))
		Input.flush_buffered_events()
		await process_frame
	player.free()
	focus.free()
	combat = null
	return true

func run() -> void:
	check(retry_streams(),"ordered retries complete")
	check(retry_ticks(),"source tick retries complete")
	check(await menu_and_cancel(),"cancel and reserved menu scenarios complete")
	print("P2-INPUT-001-RETRY ", "PASS" if failures==0 else "FAIL"," checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
