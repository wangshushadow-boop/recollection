# recollection 项目状态

## P2 野战画面刷新体验版

从仓库根目录双击「启动游戏.cmd」，选择「进入河原野战」。客户端按战斗步接收输入、命中和倒地事件，每个显示帧使用最新已提交的战场状态更新模型、相机和 HUD。按负责人要求，本次体验版的启动、功能回归及 500/1000 人性能复测均为 NOT_RUN，实际帧率待测。

**P5 柳溪庄人物委托已交付。** 在沙盒「人物 → 领地治理 → 拜访庄署」选择在任总督，可交谈、核账、交差和领取管理经验。生产提交 `4cfca39`。独立 QA 在正式 PCK 通过 404 项、冷源码通过 550 项。P5 整体为 PARTIAL，P4 总督和 P3 人物可继续游玩，P2 性能延期。[阶段验收](development/reports/stages/P5-estate-visit.md) · [任务记录](development/reports/tasks/P5-estate-visit.md) · [实际会面截图](development/reports/tests/P5/estate-visit/estate-audience.png)

## P4 治理基线

**P4 家族总督已交付。** 在沙盒「人物 → 领地治理」接管柳溪庄，可任免家人、预览次日变化并休养查看实际账簿。生产版本 `0ca0100`。独立 QA 在打包客户端验证 158 项，含旧档和实机操作。P4 整体为 PARTIAL，P3 人物已验收，P2 性能延期。[验收报告](development/reports/stages/P4-governor.md) · [实机界面](development/reports/tests/P4/governor/governor.png) · [测试与证据](development/reports/tests/P4/governor/acceptance.json)

## P3 人物基线

**P3 人物已交付并通过验收。** 在主菜单“新建沙盒”或“读取存档”后选择“人物”，即可创建、培养、换装和安排继承。P3 的其余 8 个工作包尚未启动。

```powershell
& "D:/Program/Godot/Standard/Godot_v4.7.2-stable_win64_console.exe" --path game
```

P3 人物生产源码 `53cde6d`。四个人物验收用例全部通过，正式客户端包独立验证 119 项；真实旧沙盒可读、可建角，存档故障具备原子回滚。P0/P1 已验收。P2 整场性能按负责人要求延期，GATE-P2 仍为 BLOCKED。[人物验收与未测项](development/reports/stages/P3-character.md) · [构建清单](development/reports/tests/P3/character/manifest.json) · [人物截图](development/reports/tests/P3/character/character.png)

## P2 野战基线

**当前 P2 阶段阻塞在整场性能。** 15/16 个工作包验收，P0 和 P1 已通过。负责人已批准延期优化。

| 实际规模 | 平均 FPS | 帧 P95（ms） | 权威步 P95（ms） | FPS 下限 / 帧 P95 上限（ms） |
|---|---:|---:|---:|---:|
| 500 人＋100 匹马 | 2.33–2.36 | 450.92–468.88 | 43.76–44.82 | 60 / 20 |
| 1000 人＋200 匹马 | 1.07–1.24 | 889.22–1027.83 | 92.39–105.09 | 30 / 40 |

正式河原野战以 250 名步兵、150 名弓手、50 名骑兵、50 名骑射手和 100 匹马开场，双方合计预留 1000 个兵员槽。已修复失马后编队修订倒退以及同一步中路径结果被逐出造成的两处中断。玩家行军、改盾墙、切换敌方编队、交还指挥和撤退后，第 3503 步完成对账，11071 项全部通过。另一条冲锋轨迹第 5503 步正常结算，15091 项中有 1 项失败。该轨迹要求胜方俘获至少一名敌方伤员，但倒地的 17 人都属于最终胜方，实际俘获为零。

补充场景将双方改为相距 6.5 米、每方 80 列，仍使用同一正式专服、兵种、三层 AI 和物理。第 2040 步真实补员，第 2041 步西军撤退，东军俘获西军伤员 73。1000 槽中 250 人生还、250 人撤退、1 人负伤、499 人未入场。修订版 7112 项全部通过。独立的三人自然胜利场另通过 594 项。

从仓库根目录运行下列命令，在主菜单选择“进入河原野战”。

```powershell
& "D:/Program/Godot/Standard/Godot_v4.7.2-stable_win64_console.exe" --path game
```

正式生产提交为 `31eca5d`。客户端 PCK、专服 PCK 和基础内容 ZIP 均由干净的 Git 源码构建，15 套 P1 域回归通过。桌面客户端实际点击部署、发布命令、撤退和查看战果，成品专服亦完成千槽结算。

[阶段报告与复验条件](development/reports/stages/P2.md) · [P2 阶段计划](development/planning/P2.md) · [任务状态](development/state/tasks.json) · [P1 验收](development/reports/stages/P1.md)
