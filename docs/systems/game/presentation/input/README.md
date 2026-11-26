# INPUT — 输入设备、控制映射与玩家命令

> 版本 0.3 | 状态：详细设计，河原单机野战操控见 §6.1 | 所属工程：recollection（古代中国风原创沙盒）
> 实现目录：`game/presentation/input/` | 总体基线：[§1.4、§11.2、§12.2、§15、§16.2](../../../../game_design.md) | [系统索引](../../../README.md)

本文在总体规格书约束内补充实现级设计。接口为语言无关伪代码，字段及新增参数为拟定契约；未标明已冻结的数值需经 ADR/测试确认。公共语义见[公共契约](../../../../architecture/common_contracts.md)。测试均为待执行规格，不代表功能已实现。

## 1. 职责与边界

键鼠、手柄和可访问性映射转换为标准移动、视角、攻击、格挡、装备、交互与编队命令；场景/界面上下文切换和设备焦点处理。输入不直接改权威姿态、伤害或编队状态。

**协作边界：** CON、APP/MP 命令端口、COM/FORM 控制上下文只读、UI/CAMERA。跨模块写入经 application 或权威运行时编排；不直接访问其他模块私有仓库。

## 2. 数据所有权与生命周期

设备状态、InputProfile、按键绑定、输入采样序号和本地预测缓冲归 INPUT；控制权由 RULES/FORM/NET 决定。

## 3. 代码组织

以下为建议的文件职责（按选定语言补扩展名；不是已有源码）：

```text
device_adapter / action_map / rebinding
input_context / focus_router / deadzone
character_intent_builder / direction_selector
formation_order_builder / sequence_buffer
accessibility_input
```

## 4. 数据模型与约束

`InputBinding{action,device,key_or_axis,modifiers,context}`；`InputFrame{client_sequence,client_tick,move_axes,look_delta,action_edges,held_actions}`；`ControlContext{mission_id,controlled_agent?,formation_permissions,mode,ui_focus}`。动作边沿与持续输入区分。

## 5. 公共接口

```text
sample_devices() -> InputFrame
translate(frame,context) -> IntentSet | Commands
rebind(profile,action,binding) -> Result<Unit>
build_order(selection,target,order_type) -> FormationOrder
flush_on_context_change(context) -> Unit
```

所有修改型接口须在所属权威阶段提交；查询不推进时间。命令失败遵循公共错误码；空结果与非法输入分开。非幂等的外部请求须使用稳定请求 ID 或事务回执。

## 6. 核心算法与运行流程

设备采样→死区/灵敏度/反转→按 UI/地图/战斗/指挥上下文过滤→转换为规范意图（方向攻击四向、蓄力释放、格挡、弓弩装填、骑乘、切武器）→按序提交。UI 获焦、失焦、设备断开时清除粘滞输入；编队选择和位置预览最终生成 FormationOrder。多人输入按 tick/sequence 去重、发送受限冗余；服务器重验权限和动作状态。

### 6.1 河原野战玩家操控

《骑马与砍杀 II：霸主》的公开接口分别暴露移动输入、行进角、注视方向与坐骑。战场画面单独提供角色观察状态，主角控制器单独提供瞄准状态。官方动画开发访谈还说明，玩家在攻击过程中可以朝其他方向移动。河原据此分别处理移动、身体转向和镜头；下表中按 S 转身面对镜头的规则依据本项目试玩反馈确定，步态档位、转速和转身时间按本项目角色标定。[Agent API 1.3.4](https://apidoc.bannerlord.com/v/1.3.4/class_tale_worlds_1_1_mount_and_blade_1_1_agent.html) · [MissionScreen](https://apidoc.bannerlord.com/v/1.3.4/class_tale_worlds_1_1_mount_and_blade_1_1_view_1_1_screens_1_1_mission_screen.html) · [MissionMainAgentController](https://apidoc.bannerlord.com/v/1.3.4/class_tale_worlds_1_1_mount_and_blade_1_1_view_1_1_mission_views_1_1_mission_main_agent_controller.html) · [角色动画开发访谈](https://www.taleworlds.com/en/Games/Bannerlord/Blog/86)

| 玩家状态 | 移动和身体朝向 | 鼠标与镜头 |
|---|---|---|
| 第三人称步战，站定 | 保留最后的身体朝向 | 可环绕看到正面、侧面和背面 |
| 第三人称步战，自由行走或奔跑 | 用观察基准的水平前方、右方换算移动轴，斜向合成为一个方向。身体沿最短弧逐步转向该方向。固定镜头时，A 向左并露出侧面，D 向右并露出另一侧，S 朝镜头走来并露出正面 | 镜头跟随位置，身体转身本身不会带动镜头旋转 |
| 步战攻击、瞄准或格挡 | 在动作输入生效的战斗步对准瞄准方位。保留移动轴，可面向目标横移或倒退；出手、取消、恢复及命中服从 COM 的合法窗口 | 正常视角提供瞄准方向；挥击或格挡的方向选择继续使用已有输入映射 |
| 第一人称步战 | 保持面向瞄准方位，A/D 横移、S 倒退。R 切换视角 | 使用相同的基础瞄准方向 |
| 骑乘 | W/S 调整目标步速，A/D 控制马匹左转、右转；由 MOV 决定实际速度、制动和转弯。马身采用实际行进朝向，骑手可朝另一方向观察或攻防 | 转动鼠标改变骑手视线，马头仍由行进控制。骑乘加减速有独立动态响应，也是原作公开说明的要点。[官方骑乘操控说明](https://www.taleworlds.com/en/News/478) |
| 按住自由观察键 | 延用步战或骑乘的行进基准和瞄准方向 | 反引号键按住期间叠加本地观察角，松开回到当前基础视角 |
| 部署、菜单、背包、失去控制权 | 清除持续移动与攻防输入。重新获得控制时从获准角色及其当前骑乘状态初始化，避免继承上一角色的行进指令 | UI 接收点击。I 或 Esc 关闭行装时返回进入前的上下文 |

键鼠和手柄先汇成同一对移动轴。INPUT 在固定战斗步用上下文选取上表规则，输出已有的 `MoveIntent`、`LookIntent` 和动作意图。身体的目标朝向由移动指令和瞄准状态决定，实际位移与碰撞由 MOV 裁决。CAM 读取本地观察角和角色位置，VIS 按已提交的人马位姿绘制。自由观察角仅供本地镜头使用。该分工沿用 [MOV](../../mission/movement/README.md)、[CAM](../camera/README.md) 和 [VIS](../visuals/README.md) 的所有权。

验收时固定镜头，记录移动前后的角色位置、身体正面和镜头水平朝向，同时查看真实模型。至少覆盖前、后、左右、斜向，以及横移中格挡和松开格挡后的转向。另验站定环视、行进中自由观察、第一人称、骑乘转弯中侧向观察和上下马切换。验收报告分别注明桌面实测、输入或物理模块测试和未测项。

## 7. 配置、异常与安全边界

绑定冲突提示；核心退出/菜单保留替代操作。无障碍选项仅改变合法输入映射，不提高多人权威能力。屏幕坐标和世界目标由 CAMERA/查询适配转换；服务器不信任客户端命中。

## 8. 表现及可观测性

绑定编辑、手柄图标、方向反馈、指挥快捷键和冲突提示。

**性能与诊断：** 固定输入采样和去抖；记录输入到提交延迟、序列缺失、上下文冲突。

## 9. 验收用例

| 测试 ID | 需求 ID / 质量门禁 | Given（前置） | When（操作） | Then（判据） |
|---|---|---|---|---|
| T-INPUT-01 | ACC-01 / UX-01 | 键鼠与手柄重映射、断开设备 | 操作并切换上下文 | 无卡键，设置持久化 |
| T-INPUT-02 | COM-05 | 相同方向动作来自不同设备 | 转换 | 规范意图一致 |
| T-INPUT-03 | NET-04 / BAI-01 | 试图选择无权限单位 | 发送订单 | 权威拒绝且 UI 有反馈 |

## 10. 完成条件与实施约束

- 公开接口与本模块数据所有权已落地；所有配置通过内容编译或启动校验。
- 本章测试及受影响跨模块验收通过，保留实际运行报告；没有已知的状态一致性/权限阻断缺陷。
- 接口或存档结构变化同步契约、迁移与 ADR；性能目标需在指定基准上测量，不以空场或 mock 数据代替。
- 实现和测试变更限于本模块及获准契约；不得把尚未实现的部分伪装成已完成。

## 文档导航（镜像目录）

- 主要实现目录：`game/presentation/input/`；权威设计：本文件。
- 上级入口：[上级模块 / 分组](../README.md)；[全部模块索引](../../../README.md)。
