# VIS — 地图与战场视觉代理、动画、LOD

> 版本 0.1（设计内容未变；目录版 0.2） | 状态：详细设计提案，待评审与实现 | 所属工程：recollection（古代中国风原创沙盒）
> 实现目录：`game/presentation/visuals/` | 总体基线：[§11.1–11.4、§15.2、§19、§21](../../../../game_design.md) | [系统索引](../../../README.md)

本文在总体规格书约束内补充实现级设计。接口为语言无关伪代码，字段及新增参数为拟定契约；未标明已冻结的数值需经 ADR/测试确认。公共语义见[公共契约](../../../../architecture/common_contracts.md)。测试均为待执行规格，不代表功能已实现。

## 1. 职责与边界

将只读权威快照映射为地图图标、角色/马匹、装备、场景、动画、粒子与尸体视觉代理；渲染插值、骨骼与 LOD；不决定命中或持久身份。

**协作边界：** CON/DEF、INF-ENGINE 资源/渲染端口、COM/MIS-RT/WORLD 只读视图与 ViewEvents。跨模块写入经 application 或权威运行时编排；不直接访问其他模块私有仓库。

## 2. 数据所有权与生命周期

VisualProxy、动画播放状态、资源租约、特效池与 LOD 是可重建表现；AgentHandle+MissionId 为映射键，绝不以 NodePath 作为身份。

## 3. 代码组织

以下为建议的文件职责（按选定语言补扩展名；不是已有源码）：

```text
proxy_registry / map_markers / agent_proxy
 equipment_attachment / mount_visual
animation/locomotion / action_blend / ik / event_sync
lod/skeletal_lod / culling / batching / material_variants
vfx/projectile / impact / ragdoll / weather / terrain
```

## 4. 数据模型与约束

`VisualProxy{scope,handle,resource_refs,representation,lod,prev_pose,curr_pose}`；`ViewEvent{event_id,tick,kind,position,material,attack_id?,confirmed}`；`RigBinding{rig_id,slot_map,animation_set,scale}`。权威动作起止 tick 与 active window 源于 ActionDef。

## 5. 公共接口

```text
bind_visual(handle,definition) -> Result<ProxyId>
apply_snapshot(snapshot) -> Unit
consume_view_events(events) -> Unit
render_interpolated(alpha,quality) -> RenderReport
release_scope(scope) -> ResourceReport
```

所有修改型接口须在所属权威阶段提交；查询不推进时间。命令失败遵循公共错误码；空结果与非法输入分开。非幂等的外部请求须使用稳定请求 ID 或事务回执。

## 6. 核心算法与运行流程

按 stable handle 建立/回收代理，角色模型、武器、马匹按骨骼/挂点装配。渲染使用前后快照插值，动画混合基础移动、上身攻击/防御、骑乘、受击、死亡和交互；权威时间轴映射动作播放，视觉标记仅用于校验。预测特效可撤销，已确认事件去重。LOD 根据距离/重要性调整蒙皮/阴影/动画刷新；重复静态网格可实例化，独立骨骼需实测。尸体、特效预算裁剪不改变结果。

## 7. 配置、异常与安全边界

河原单机野战用战场确认的主将身份选择将军外形和阵营色。双方首领都可步战，手中的长枪、圆盾和短弓随实际装备切换。将军外形与兵种、是否骑马分别决定。持弓行走或奔跑时，头、颈和胸甲随同一副骨架运动；拉弓可增加上身侧转，松弦或收弓后回到当前步态。画面验收同时检查固定镜头按 S 跑近时的正面、拉满弓的侧面，以及远处敌方将领的轮廓。

配置材质/LOD/骨骼/纹理/粒子/尸体预算；资源缺失开发态醒目占位并报错，发布阻断。不能依靠动画结束回调造成伤害。古代中国风资产采用统一原创文化风格及授权记录。

## 8. 表现及可观测性

阵营色、旗帜、受击、装备、天气及目标可读性；血腥开关只改变表现。

**性能与诊断：** 记录 draw calls、蒙皮数、动画 CPU/GPU、显存、资源池和特效峰值；使用同镜头基准。

## 9. 验收用例

| 测试 ID | 需求 ID / 质量门禁 | Given（前置） | When（操作） | Then（判据） |
|---|---|---|---|---|
| T-VIS-01 | VIS-01 | 不同兵种装备、骑乘和方向攻击 | 播放并验证挂点/窗口 | 视觉与权威动作一致，无穿戴错位 |
| T-VIS-02 | COM-05 | 切换动画 LOD/帧率 | 同输入战斗 | 权威伤害/伤亡不变 |
| T-VIS-03 | BAI-06 / §19.4 | 500/1000 真实动画混合单位 | 压力 | 测量 FPS/显存/蒙皮，不以静止实例替代 |

## 10. 完成条件与实施约束

- 公开接口与本模块数据所有权已落地；所有配置通过内容编译或启动校验。
- 本章测试及受影响跨模块验收通过，保留实际运行报告；没有已知的状态一致性/权限阻断缺陷。
- 接口或存档结构变化同步契约、迁移与 ADR；性能目标需在指定基准上测量，不以空场或 mock 数据代替。
- 实现和测试变更限于本模块及获准契约；不得把尚未实现的部分伪装成已完成。

## 文档导航（镜像目录）

- 主要实现目录：`game/presentation/visuals/`；权威设计：本文件。
- 上级入口：[上级模块 / 分组](../README.md)；[全部模块索引](../../../README.md)。
