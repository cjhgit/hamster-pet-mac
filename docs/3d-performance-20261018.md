# 3D 性能实测（2026-10-18）

后续开发的排查流程、实现边界、诊断开关和回归命令见 [性能优化与回归指南](performance-guide.md)。本文保留当次测试条件与结果。

设备：Apple M4 Pro，macOS 27.0.1，Retina 2×、120 Hz 显示器，Release 构建。CPU 以单个核心为 100%，包含进程全部线程，不含 WindowServer；这些结果不能外推为低配设备的固定占用。

## 最终应用

直接采样已经运行的 `Hamster Pet` 进程，371 × 278 可见窗口，截图时仓鼠正在跑轮；每 5 秒记录一次，持续一分钟：平均 CPU **13.41%**，区间 **12.35%～13.95%**。RSS 78.16～78.20 MiB；macOS sample 的 physical footprint 约 284 MiB，RSS 不代表全部图形资源占用。

真实应用自由活动与受控场景的负载不同，不能将二者直接计算为优化比例。用户此前观察到的 30%～40% 也不是同动作、同时间的配对基线。

## 受控场景

742 × 558 可见窗口，种子 11042，每项预热 3 秒、采样 12 秒。行走期间每 0.1 秒核查位移或转身，120 次检查全部在活动。

| 场景 | CPU | 仿真 FPS | Metal 提交 FPS |
| --- | ---: | ---: | ---: |
| 静止 | 2.62% | 29.99 | 10.41 |
| 持续行走与转身 | 10.89% | 30.00 | 30.00 |
| 白天全速跑轮 | 10.22% | 30.00 | 30.00 |
| 夜间全速跑轮 | 11.17% | 30.00 | 30.00 |
| 跑轮后转入睡眠 | 4.69% | 29.99 | 26.99 |
| 暂停 | 0.16% | 0 | 0 |
| 隐藏（播放状态） | 0.27% | 0 | 0 |
| 屏幕休眠 | 0.06% | 0 | 0 |
| 会话不活跃 | 0.03% | 0 | 0 |

静止和睡眠的未变姿态按需跳过呈现；仿真仍运行 30 FPS。独立睡眠场景延长采样至 20 秒测得 2.03%，与跑轮后的动作过渡不能混为同一负载。

额外配对测试只切换四肢上传方式，其余源码、动作、种子、窗口、20 秒采样和实际 30 FPS 相同：原先 `Data` 交给 SceneKit 上传为 **9.93%**，直接共享 Metal 顶点缓冲为 **8.65%**，降低 **1.27 个百分点**。诊断开关为 `--hamster-batch-data`。

## 实现与验证

- 身体曲面的场采样、求交、三角化、平滑和法线计算在 GPU 完成，SceneKit 直接读取 Metal 输出；每帧输出保持独立且不可变。
- 四肢按材质合并，并直接共享 Metal 顶点缓冲；缓存索引、圆周、截面和材质，耳缘与眼睛使用头部局部控制点。
- `SCNRenderer` 在暂停自动刷新的 `MTKView` 中显式提交；避免系统刷新调度少画或重复画。只设置 `SCNView.preferredFramesPerSecond` 不能替代实际提交帧率验证。
- 隐藏、屏幕休眠和会话不活跃时停止仿真并释放绘制表面，恢复时重新计时。
- 13 种动作、1,560 帧、52 个环绕视角通过。230 张动作图与 19 张场景图对照通过，最坏平均 RGB 差约 0.0011/255。
- 实际窗口的暂停、逐帧、旋转、主题、缩放、隐藏和休眠恢复检查通过；CPU 曲面和禁用 Metal 堆的兼容路径通过。

最终真实进程采样中，剩余开销仍涉及 SceneKit 场景编码、几何资源生命周期和 Metal 驱动。GPU 完成等待中的线程休眠不能当作 CPU 忙计算。

## 复测

保持电脑解锁、窗口可见，单独运行以下测试，避免同时编译或运行其他图形测试：

```bash
./run.sh
python3 scripts/profile-running-app.py --interval 5 --count 12 --sample
bash scripts/verify-3d-performance.sh current 12
bash scripts/verify-3d-performance.sh limb-metal 20 --scenario wheel-day
bash scripts/verify-3d-performance.sh limb-data 20 --scenario wheel-day --hamster-batch-data
```

本次原始记录位于 `/private/tmp/hamster-app-profile/final/` 和 `/private/tmp/hamster-3d-performance/`，受控完整结果文件为 `final-visible.json`。
