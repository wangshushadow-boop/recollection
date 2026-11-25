# 河原野战行为与碰撞独立复验

A 为 0e7fef8 冷提取的 game。B 是最终 queries.gd（a05e79b963d5bc296844f80b80feec28b40db770bec9eacc9e18eb679d2e315f）；C 是已弃用的首段省略 get_rest_info 实验（32df7a9719390a5611e494e033fb3a9fc5da4be01076aa3abe3111e1f938a90f）。包中 variants 保存两种引擎适配脚本，均可叠加到基线重放。诊断目录名 baseline=A、candidate=B、final=C，以此处映射为准。

## 实测

- 两版均通过 40 人、8 马混合场 2100 个固定步和 500 人、100 马的 1260 步逐步精确对照。GameSession 使用 60Hz、种子 241124。界面计时使用站立操作，行为复验另向四支编队下达固定侧翼行军并允许接战。每步观测可见士兵/坐骑完整位姿、弹药、生命、士气、武器状态、可见弹体以及权威 COM 的命中和事件，用 Godot var_to_bytes 逐步编码比对 SHA-256。命令和序号、各兵种位移、发射和敌对命中另做精确比对。
- 500 人在第 986 步首次命中敌军，发射 88，61 次造成实际伤害共 2112（这段战役均为西军命中）。四兵种最大移动 67.37–88.21 米。40 人在第 919 步首次命中，78 次发射，双方分别有效命中 80、1 次，实际伤害 2004。
- 最终版三人自然胜利/俘获 594 项，场景引擎 70 项、运动批次回滚 3359 项全部通过；MOV 导航与队列用例报告 0 错误。球扫批处理新回归 37/37，旧 36/36 亦附原始结果。
- 20 mm 薄板中心 y=0，半径 280 mm 的球从 [0,290,0] 扫到 [8,292,1]。基线与 B 均命中起点，C 漏碰。四种表面、六种半径、正反面和 15 个微米偏移共 720 项（量化后有重复）。基线和 B 的正式查询逐项相等，C 有 154 行不同，涉及 15 个不同毫米查询。同时直接在本机 Godot 4.7.2 空间查询看到 93 次 intersect_shape 返回空而 get_rest_info 给出命中。该额外探针最初尝试一次性检查，包含一处 GDScript 类型推断错误，修正后保留了每行回执（包括引擎原本返回的错误）和失败版结果。运行时单例类型 PhysicsServer3D，工程配置 DEFAULT；当前日志无更具体的后端名称。

## 复跑

将 variants 中相应的引擎脚本复制到对应的 0e7fef8/game/infrastructure/engine/queries.gd 中，执行以下命令。用于比较的两个项目路径均指向含有 project.godot 的目录。

```powershell
python run.py baseline40 D:/checks/baseline/game --suites
python run.py candidate40 D:/checks/candidate/game --suites --against baseline40
python run.py baseline500 D:/checks/baseline/game --count 500
python run.py candidate500 D:/checks/candidate/game --count 500 --against baseline500
```

--engine 可指定 Godot 4.7.2 控制台路径。grazing-comparison.json 保存明确反例及 A/B/C 三方返回。regression.gd 是新增正式回归；以 --headless --fixed-fps 60 --path <game> --script <regression.gd> 单独在三版本运行。regression-baseline、regression-final、regression-candidate 日志分别对应 A、C、B，退出码分别 0、1、0。相同常规实战足以核验给定输入，C 的额外边缘覆盖失败，因此仅 B 通过完整独立验证。
