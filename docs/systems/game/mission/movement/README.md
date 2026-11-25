# MOV — 战场路径、避障、运动与动态导航

> 版本 0.1（设计内容未变；目录版 0.2） | 状态：详细设计提案，待评审与实现 | 所属工程：recollection（古代中国风原创沙盒）
> 实现目录：`game/mission/movement/` | 总体基线：[§11.5、§12.6、§13.1、§19](../../../../game_design.md) | [系统索引](../../../README.md)

本文在总体规格书约束内补充实现级设计。接口为语言无关伪代码，字段及新增参数为拟定契约；未标明已冻结的数值需经 ADR/测试确认。公共语义见[公共契约](../../../../architecture/common_contracts.md)。测试均为待执行规格，不代表功能已实现。

## 1. 职责与边界

权威战场运动系统，执行 Move/LookIntent、中心路径、槽位跟随、局部避障、步/骑运动和动态通行。战略地图导航独立 WORLD。引擎适配层提供导航/物理查询，不成为第二套权威状态。

**协作边界：** CON/DEF、MIS-RT 组件访问、FORM 槽位、COM 动作/骑乘约束、INF-ENGINE。跨模块写入经 application 或权威运行时编排；不直接访问其他模块私有仓库。

## 2. 数据所有权与生命周期

Transform/Kinematics/MovementMode、路径队列/缓存、NavLinkRevision、拥堵检测由 MOV 写；MountLink 归 COM，移动只遵循其约束。

## 3. 代码组织

以下为建议的文件职责（按选定语言补扩展名；不是已有源码）：

```text
navigation/nav_query / path_queue / shared_corridor
navigation/nav_link / revision_cache / region_projection
locomotion/infantry / mounted / movement_integrator
crowd/spatial_hash / local_avoidance / congestion
 slot_follow / movement_constraint / recovery
```

## 4. 数据模型与约束

野战移动可从已注入的场景适配器读取局部查询 `field_scenery_top(scope_id, mask)`。有限返回值是本次同步查询中该遮罩下所有场景碰撞体的世界高度上界，单位为米。适配器仅在能从当前物理形状证明上界时提供该值。缺少该能力或返回无穷大时，移动沿用原有格子粗筛和球扫。移动只对整段球扫的最低点高于上界且留有接触余量的水平移动使用此信息。跳跃和落地独立查询。

`PathRequest{id,requester,origin,goal,agent_profile,priority,nav_revision,deadline}`；`PathResult{status,corridor,waypoints,nav_revision}`；`NavLink{id,from,to,allowed_profiles,enabled,revision}`；`Kinematics{position,velocity,heading,desired_velocity,mode}`。坐标米、速度 m/s、弧度；船上局部坐标由扩展适配。

## 5. 公共接口

```text
RequestPath(request) -> RequestId
PollPath(id) -> PathResult
ProjectToNav(point,profile,max_radius) -> Result<Vec3>
SetNavLink(link,enabled,source_event) -> Receipt
build_shared_corridor(formation,goal) -> PathRequest
step_motion(tick,intents,pose_snapshot) -> MotionDelta
GetMovementView(agent) -> MovementView
```

所有修改型接口须在所属权威阶段提交；查询不推进时间。命令失败遵循公共错误码；空结果与非法输入分开。非幂等的外部请求须使用稳定请求 ID 或事务回执。

## 6. 核心算法与运行流程

优先队列处理批量路径请求，按区域/导航版本/能力缓存；编队共享走廊，个体只在必要时补路径。槽位偏差与中心方向算期望速度，空间网格查询有限邻居，使用速度障碍或受控软约束避碰，积分位姿并验证地形/坡度/身体碰撞。骑马考虑速度依赖转向和制动；楼梯、门洞和器械通行按 profile 过滤。动态门/梯/缺口事件开启/关闭局部 link，等待适配器同步确认后更新 nav_revision，仅使相关走廊失效。堵塞检测按进展/密度/超时→让行/分流→局部重规划→报告失败或退回合法位置，不传送掩盖问题。

## 7. 配置、异常与安全边界

初始配置请求预算、近邻上限、最大坡度、速度/转向、拥堵时间和重试冷却。过期路径不得使用；无可达点返回 NotFound/Unavailable；尸体/落马不永久阻路。物理/导航同步遵守引擎版本线程约束。

## 8. 表现及可观测性

路径、槽位、动态 Link 和拥堵可在调试层显示；玩家目标不可达给明确反馈。

**性能与诊断：** 记录路径 P95、等待/失效、共享率、拥堵热区、邻居数和 motion tick；预算不足按优先级排队。

## 9. 验收用例

| 测试 ID | 需求 ID / 质量门禁 | Given（前置） | When（操作） | Then（判据） |
|---|---|---|---|---|
| T-MOV-01 | NAV-01 | 门关闭后破坏、梯启用、缺口产生 | 查询路径 | 正确等待版本并使用新可达链接 |
| T-MOV-02 | BAI-02 / NAV-01 | 大量士兵通过窄门 | 运行编队 | 有分流/回退，无永久停滞或瞬移 |
| T-MOV-03 | COM-04 | 高速骑兵转向进入窄梯 | 运动 | 合法转向限制，禁止进入不适用 profile |
| T-MOV-04 | BAI-06 | 500/1000 混合路径 | 压力 | 请求队列有界，不每帧全图寻路 |

## 10. 完成条件与实施约束

- 公开接口与本模块数据所有权已落地；所有配置通过内容编译或启动校验。
- 本章测试及受影响跨模块验收通过，保留实际运行报告；没有已知的状态一致性/权限阻断缺陷。
- 接口或存档结构变化同步契约、迁移与 ADR；性能目标需在指定基准上测量，不以空场或 mock 数据代替。
- 实现和测试变更限于本模块及获准契约；不得把尚未实现的部分伪装成已完成。

## 文档导航（镜像目录）

- 主要实现目录：`game/mission/movement/`；权威设计：本文件。
- 上级入口：[上级模块 / 分组](../README.md)；[全部模块索引](../../../README.md)。
