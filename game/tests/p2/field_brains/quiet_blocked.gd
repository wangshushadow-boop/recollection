extends "res://tests/p2/individual/run.gd"
const FieldBrains = preload("res://mission/runtime/field_brains.gd")

class NavReply:
	var allow := true
	var queries := 0
	func query_path_batch(requests: Array, _nav: int, _scope: String) -> Dictionary:
		queries += requests.size()
		return R.ok([{"reachable":allow}])

func run() -> void:
	var reply := NavReply.new()
	var dispatcher := FieldBrains.new(SCOPE,reply,null,[])
	var ai := AI.new(SCOPE,func(_a,_b):return true)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	dispatcher._ai=ai
	dispatcher._draft=brain
	var soldier := unit(A,Vector3.ZERO,0,"infantry")
	dispatcher._units[A.index]=soldier
	var combat := Combat.new(SCOPE)
	combat.enlist(A,{"team":0,"role":"infantry"})
	for tick in range(1,4):
		var job := job_for(ai,tick,[soldier])
		if job.is_empty():check(false,"scheduled individual");break
		var observed: Dictionary=ai.sense(A).value
		var state: Dictionary=combat.view(A).value.duplicate()
		state.phase="Ready" if tick==1 else "Guard"
		reply.allow=tick==1
		var local:=context(Vector3.RIGHT*4)
		local.can_travel=func(_from,_to,_rev):return reply.allow
		var expected: Dictionary=brain.decide(job,observed,state,ORDERS,local)
		if not expected.ok:check(false,"inline decision");break
		var member:=FieldBrains.MemberWork.new()
		member.job=job
		member.combat=state
		member.rules=ORDERS
		member.observed=observed
		member.local=local.duplicate()
		member.local.can_travel=member.record_move
		var members:Array[FieldBrains.MemberWork]=[member]
		var plans:={}
		var admitted: Dictionary=dispatcher._flush_quiet(members,plans,{"individual":0,"modes":{},"role_modes":{}})
		if not admitted.ok:check(false,"deferred admission");break
		var actual: Dictionary=plans[job.id]
		check(actual==expected.value and actual.mode=="MoveToSlot","all intents and proposal state match inline decision")
		var moves:Array=actual.intents.filter(func(v):return v.has("desired_direction"))
		if tick==1:
			check(moves.size()==1 and moves[0].speed_fraction>0,"first move seeds moving state")
		elif tick==2:
			check(moves.size()==1 and moves[0].desired_direction==[0,0,0],"denial emits one stop")
		else:
			check(moves.is_empty(),"second denial emits no redundant stop")
		if tick>1:
			check(actual.intents.back().get("held")==false,"guard release survives discarded movement")
		var drained: Dictionary=ai.drain()
		if not drained.ok or drained.value.size()!=1:check(false,"drain admitted plan");break
		check(brain.accept(drained.value[0],actual,R.ok(),R.ok()).ok,"accept into memory")
	check(reply.queries==3,"one real path request per move")
	print("QUIET_BLOCKED checks=",checks," failures=",errors)
	quit(int(errors>0))
