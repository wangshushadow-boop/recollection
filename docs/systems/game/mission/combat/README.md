# COM — 动作、装备、命中、伤害与士气执行

> 版本 0.1（设计内容未变；目录版 0.2） | 状态：详细设计提案，待评审与实现 | 所属工程：recollection（古代中国风原创沙盒）
> 实现目录：`game/mission/combat/` | 总体基线：[§10.4、§11、§12.7、§16.2](../../../../game_design.md) | [系统索引](../../../README.md)

本文在总体规格书约束内补充实现级设计。接口为语言无关伪代码，字段及新增参数为拟定契约；未标明已冻结的数值需经 ADR/测试确认。公共语义见[公共契约](../../../../architecture/common_contracts.md)。测试均为待执行规格，不代表功能已实现。

## 1. 职责与边界

战场动作执行权威模块：攻击/格挡/装填/换装、近远程命中、伤害、状态转换、骑乘挂接与个体战场士气。移动积分归 MOV；Formation 维护编队士气聚合；AI 不直接写生命。战役物品/伤病由 ENC 结算。

**协作边界：** CON/DEF/SHRULE、MIS-RT EntityStore 组件端口、MOV/INF-ENGINE 碰撞与位姿查询、RULES 规则。跨模块写入经 application 或权威运行时编排；不直接访问其他模块私有仓库。

## 2. 数据所有权与生命周期

拥有 Health、ActionState、Equipment、CombatStats、MountLink、IndividualMorale、Projectile 相关组件的唯一写入权。DamageCandidate 为同 tick 临时数据。

## 3. 代码组织

以下为建议的文件职责（按选定语言补扩展名；不是已有源码）：

```text
action/action_fsm / action_timeline / cancel_table
melee/sweep / attack_registry / guard_resolver
ranged/reload / projectile / trajectory
 damage/damage_rule / damage_resolver / hit_zone
mount/mount_link / charge / dismount
morale/morale_resolver / routing_state
combat_queries / combat_pipeline
```

## 4. 数据模型与约束

`ActionState{action_id,phase,start_tick,direction,charge,attack_id?,tags}`；`AttackInstance{id,attacker,action,hit_set,max_targets}`；`DamageCandidate{attack_id,source,target,hit_zone,point,relative_speed,contact_order}`；`DamageResult{blocked,raw,mitigation,actual,stagger,downed,breakdown}`；`MountLink{rider,mount,attach_slot}`；`MoraleState{value,routing,last_event_tick}`。伤病分类与战役医术只在 ENC 结算。

## 5. 公共接口

```text
submit_action_intents(tick, intents[]) -> IntentReceipt[]
advance_actions(tick, pose_view) -> ActiveAttack[]
collect_hit_candidates(active_attacks, collision_snapshot) -> DamageCandidate[]
resolve_damage_batch(tick, candidates, phase_start_view) -> CombatDelta
request_mount / request_dismount(actor,mount?) -> Receipt
apply_morale_events(events, snapshot) -> MoraleDelta
GetCombatReadView(agent,context) -> CombatView
```

所有修改型接口须在所属权威阶段提交；查询不推进时间。命令失败遵循公共错误码；空结果与非法输入分开。非幂等的外部请求须使用稳定请求 ID 或事务回执。

## 6. 核心算法与运行流程

**动作：** Ready→Windup→Hold→Active→Recovery→Ready，Guard/Stagger/Downed 为合法转换；移动/骑乘 FSM 与动作标签组合；取消按 ActionDef 表验证。权威时间窗基于 tick 而非动画回调。每次有效攻击产生唯一 AttackId，先扫掠武器轨迹或弹体连续路径，碰撞粗筛→身体区域/盾牌/障碍→按稳定 contact_order 排序；盾牌覆盖/方向/时机/友伤规则先于伤害。伤害 raw=weapon_base*action_modifier*charge_factor*speed_factor*skill_factor，zone=raw*hit_zone_multiplier，mitigation=armor/(armor+penetration_scale[type])，actual=max(0,round(zone*(1-mitigation)*difficulty))；分项记录，限幅相对速度，盾破/硬直/落马独立。伤害阶段以开始快照确定攻击资格，允许同 tick 相互命中；单攻击对同目标只结算一次，超过 max_targets 拒绝。弓/弩/投掷由权威装填扣弹药并生成弹体，重力和高速连续扫掠。骑手/马独立生命碰撞，坐骑失能立即解除 MountLink 并落马。士气按损失、近邻溃散、统帅击倒、增援等限频累计并衰减；阈值触发溃逃/重组，出口由 MOV/RULES 决定。

## 7. 配置、异常与安全边界

河原单机练兵主将使用长枪、圆盾和短弓。近战按住攻击键锁定起手方向，松键出手；起手或蓄势时可转入另一方向的格挡。有效命中与收势期间需等动作完成。持弓时按住拉弓，松键发箭，防御键收弓并保留弹药。准星以距箭起点 20 米处的初始方向作屏幕参考，弹体沿自己的发射点、俯仰与重力前进。画面读取已提交的动作阶段和战斗步数，决定武器和骨骼姿态；命中、盾耐久和扣箭归 COM。动作设计参考《骑马与砍杀 II：霸主》用清晰的起手区分方向、允许准备动作被防御打断，以及分段表现弓的准备与射击。时长由本项目按 60 Hz 调校。[官方动作设计访谈](https://www.taleworlds.com/en/Games/Bannerlord/Blog/86) · [官方远程动画说明](https://www.taleworlds.com/en/Games/Bannerlord/Blog/40)

配置动作时长/取消表、伤害类型穿透、格挡角度、体力（规则启用才生效）、多目标数、弹道、友伤、士气阈值和传播预算。攻击/格挡/换装需控制权、状态、武器合法性；视觉动画不得决定命中；客户端只能发意图。非致命竞技规则对 Downed 采用独立政策。

## 8. 表现及可观测性

HUD 显示方向、血量、弹药、盾耐久和状态；音效/动画从已确认表现事件消费，不能反向写伤害。

**性能与诊断：** 热点组件 SoA、攻击/弹体候选空间索引；禁止全员骨骼逐对检测；监控每 tick 碰撞候选、命中、分配、弹体数。

## 9. 验收用例

| 测试 ID | 需求 ID / 质量门禁 | Given（前置） | When（操作） | Then（判据） |
|---|---|---|---|---|
| T-COM-01 | COM-01 | 四向攻击、格挡、蓄力与取消窗口 | 逐 tick 输入 | 合法转换，超时取消拒绝，多骨骼接触一次伤害 |
| T-COM-02 | COM-02 | 高速弹体和障碍、空弹药 | 射击 | 不穿墙/跳过命中，空弹药拒绝 |
| T-COM-03 | COM-03 | 盾覆盖与不同护甲区域 | 同武器击中 | 正确格挡、盾破和伤害分项 |
| T-COM-04 | COM-04 | 骑手在马背且马失能 | 受击 | 马/骑手独立状态，合法落马 |
| T-COM-05 | COM-05 | 玩家和 AI 提交相同合法意图 | 不同渲染帧率重放纯逻辑 | 动作与伤害一致 |
| T-COM-06 | COM-06 | 重复网络输入/非法命中包 | 服务器处理 | 无重复伤害与越权 |
| T-COM-07 | BAI-05 | 单位士气越阈值且有出口 | 伤亡阶段 | 溃逃、传播限频、可见反馈正确 |

## 10. 完成条件与实施约束

- 公开接口与本模块数据所有权已落地；所有配置通过内容编译或启动校验。
- 本章测试及受影响跨模块验收通过，保留实际运行报告；没有已知的状态一致性/权限阻断缺陷。
- 接口或存档结构变化同步契约、迁移与 ADR；性能目标需在指定基准上测量，不以空场或 mock 数据代替。
- 实现和测试变更限于本模块及获准契约；不得把尚未实现的部分伪装成已完成。

## 文档导航（镜像目录）

- 主要实现目录：`game/mission/combat/`；权威设计：本文件。
- 上级入口：[上级模块 / 分组](../README.md)；[全部模块索引](../../../README.md)。
