# 河原野战界面与窗口验收

2026-11-26。基线 `6eab6fc`，游戏提交 `256c03d`。同一游戏源版本通过普通客户端与 C++ 移动常驻客户端验收。运行环境为 Windows、Godot 4.7.2 Standard。本批工作对应 P2-FIELD-INTEGRATION-039 至 042、P2-UI-BATTLE-004。

| 实际画面 | 玩法与读法 |
|---|---|
| [主菜单](menu.jpg) | 河原野战位于首位。新建沙盒、读取存档、存档槽和训练仍在首屏，可继续进入已有战役。 |
| [河原部署](deployment.jpg) | 底部按步兵、弓手、骑兵和弓骑兵显示首波人数与阵型，支持选择、部署、重置和直接开战。标准场景己方四队分别为 125、75、25、25。 |
| [开战后](battle.jpg) | 顶部为双方在场兵力；右下为主将生命、士气、武器类型、弹药和步战或骑乘状态；左下为北向上的局部战图。 |

战图覆盖玩家周围 70 米。浅金箭头表示玩家与朝向，暖红表示本方，蓝色表示可见敌兵，旗形为己方集结地，菱形为公开目标。每 6 个战斗步最多采集一次已有的可见兵员快照，玩家方向随显示更新。未投影的敌兵与敌方营地不会通过地图泄露。部署人数取首波实际兵源，超出本次配额的预备队另计。

## 运行与实机结果

从仓库根目录双击「启动游戏.cmd」，选择「进入河原野战」和「开始野战」。C++ 版本仍用[常驻试玩入口](../field-resident/试玩常驻版野战.cmd)。两者将窗口设置写入原 Windows 用户目录下的 `%APPDATA%\Godot\app_userdata\recollection\window.cfg`，普通与常驻版各自沿用原存档路径。首次启动默认为 960×600。

| 验证 | 实测结果 |
|---|---|
| 正式桌面流程 | 普通版 52/52，常驻版 53/53，均退出 0。500 兵、100 马；点击部署设置并返回、开战、移动、转向、显示人物状态、Esc 菜单以及撤退返回。原生版另验内核有实际调用。 |
| 两种窗口比例 | 在 960×600 和 1800×1350 实际开窗。主按钮金边像素高 46 → 86，逻辑缩放 1.875 倍。两版均实测部署按钮、状态栏、小地图有相应缩放。 |
| 两个实际 cmd 交叉重开 | 隔离用户目录：普通版首次 960×600，调整为 1272×792 后关闭，常驻版重开为 1272×792。常驻版最大化至 3840×2054 后关闭，普通版重开仍为最大化，还原到 1272×792。 |
| 窗口边界情况 | 9 次独立 Windows 进程验证首次启动、大小、最大化、最小化退出、恢复、显式测试分辨率、超屏尺寸和跨用户数据目录读取。 |
| HUD 无头回归 | 640×360、960×600、1920×1080 每档 185/185，覆盖中英文及放大字体、设置点击与返回、部署、转向与地标清理。 |
| 带预备队的部署与旧菜单入口 | 20 人入场、40 个兵源槽，己方首波 5/3/1/1，FIELD_BOOT errors=0。原 P1 桌面按钮回归 errors=0，P3 人物桌面回归 84/84。 |

独立截图审查发现部署设置按钮在中文下折成一条窄线，修正后重跑全部最终桌面检查。没有采集本版 FPS 或测量千人对战。P2 性能验收继续按原计划记录。

## 复核材料

[运行记录与探针](evidence.zip)含两个客户端的断言与尺寸、像素读数、引擎日志、启动脚本的跨进程实测，以及无头 UI、P1、P3 和窗口边界回归。解压后可用 `python run.py <游戏目录> normal` 或 `python run.py <常驻游戏目录> native --native` 复跑桌面场景；像素高度使用 `python pixels.py normal` 复核。画面使用游戏内真实截图，报告图片经 JPEG 压缩。

主菜单插画使用 ImageGen 为本项目生成，源文件为 `game/presentation/ui/art/river_campaign.webp`。构图参考中国北方河原、甲骑与军旗，菜单文本由 Godot 单独绘制。生成提示词如下。

> Wide 16:9 cinematic title-screen painting for an original Chinese historical cavalry RPG. Dawn over a wide northern river plain. A single mounted Chinese lamellar-armored commander in weathered iron and a restrained cinnabar cloak, seen from behind in three-quarter silhouette, dominates the RIGHT third, with a long vertical crimson battle standard near him. He looks at a column of distant horses and small human figures crossing a silvery river between mountains. Ink wash atmosphere layered with fine realistic painterly details on the horse tack and armor, natural overcast light breaking through ochre clouds, elegant charcoal and muted bronze palette. Strong landscape scale and textured traditional paper grain. Leave LEFT 40 percent dark and calm, misty ridge in shade for ivory menu lettering to be added by engine. Original illustration, no text, lettering, UI, border, logos, or watermarks.
