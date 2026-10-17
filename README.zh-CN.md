# Hamster Pet

[English](README.md) | **简体中文**

<img src="assets/branding/hamster-logo.png" alt="Hamster Pet 图标" width="112">

住在 Mac 上的小仓鼠。投喂、看它跑轮，让它陪在身边，不占用 Dock。

**[下载最新版本](https://github.com/cjhgit/hamster-pet-mac/releases/latest)** · macOS 14 及以上 · 支持 Apple 芯片和 Intel

没有 Mac，或想在安装前先试玩？可以直接在浏览器中打开 **[网页版试玩](https://cjhgit.github.io/hamster-html/)**，源码见 **[hamster-html 仓库](https://github.com/cjhgit/hamster-html)**。

## 3D 分支

本分支默认使用 SceneKit / Metal 绘制真实三维场景：由原版控制点驱动的可变形仓鼠、带深色耳缘的立体耳朵、四肢和尾巴，以及有跑道宽度的跑轮、完整水瓶和夜间吊灯。水印保留为屏幕文字。

- 拖动旋转视角，滚轮或触控板捏合缩放，Shift + 拖动平移。
- 点击投食；Command + 按住拖动食物。点击黄色轮心让仓鼠上跑轮。
- 数字键 **0–6**：正面、立体、右侧、背面、俯视、左侧、跟随仓鼠的特写。**0** 同时复位缩放和平移。
- 点击左下角的**暂停 / 继续**或按**空格**切换播放；暂停后点击**下一帧**，或按 **→ / .** 每次前进一帧（1/30 秒）。暂停时仍可旋转、缩放和平移视角，便于检查身体形态；点击场景不会投食或触发动作。
- 按住顶部空白处移动窗口，右键菜单仍提供置顶、大小、水印和深色模式。

仓鼠使用原版的头部转动、四肢步序、手腕和脚尖轨迹。头身通过连续体积融合生成闭合曲面，腿部皮肤和脚掌随关节弯曲伸缩；跑轮接触点约束在真实轮面内。没有额外编排一套与原版脱节的摆动节奏。

运行 `bash scripts/verify-hamster-motion.sh` 可复现 13 个动作与转场场景（站立、左右行走、转身、双向跑轮、吃东西、洗脸、喝水和睡觉），模拟 1,560 帧，生成同一时刻的原版／3D 对照、多角度截图和连续步态 GIF。检查关节对照、轮壁穿透、轮廓重合度与更新耗时。结果位于 `/private/tmp/hamster-motion/`，其中 `overview.png` 为总览，行走、转身和跑轮目录中的 `comparison.gif` 为连续对照。

构建运行：`./run.sh`。专门验证三维网格、视角、投影和输入：`bash scripts/verify-3d.sh`，截图位于 `/private/tmp/hamster-3d/`。原有二维绘制器作为独立回归路径保留。

`bash scripts/verify-playback.sh` 验证实际窗口中的播放按钮、快捷键、逐帧、暂停时的姿态和输入冻结，以及切换主题、调整窗口、隐藏再显示和恢复计时。

## 安装

1. 前往 [Releases](https://github.com/cjhgit/hamster-pet-mac/releases/latest)，下载 **DMG**。
2. 打开 DMG，将 **Hamster Pet.app** 拖入 **Applications（应用程序）**。
3. 启动 **Hamster Pet**，即可看到仓鼠窗口和菜单栏中的爪印图标。

也提供 ZIP 和 SHA-256 校验文件。使用发布版无需安装 Xcode 或编译工具。

### 首次打开

当前版本使用临时签名，尚未经过 Apple Developer ID 签名和公证。若 macOS 阻止首次打开，请先尝试打开应用，再前往 **系统设置 → 隐私与安全性 → 仍要打开**，按提示确认。无需关闭系统安全保护。

## 功能

- **可以互动的宠物：**投喂、拖动和抛出食物，看仓鼠吃东西、喝水、洗脸、睡觉和跑轮。
- **常驻菜单栏：**通过爪印图标显示或隐藏窗口。关闭窗口后应用仍在运行，选择 **退出 Hamster Pet** 才会退出。
- **灵活的窗口：**圆角外观、顶部拖拽、置顶开关、小中大三档尺寸，也支持手动缩放。
- **适合日常使用的深色模式：**深蓝灰背景，仓鼠和食物清晰可见，水瓶适当调暗，右上角有一盏暖色小灯点缀。
- **自动记住设置：**窗口大小、置顶、水印显示和深色模式会在重启后恢复。
- **GPU 原生绘制：**默认使用 Metal 绘制矢量场景和夜间光照，保持 30 FPS；无可用 GPU 时自动回退到 Core Graphics。窗口隐藏、最小化或完全被遮挡时暂停动画并释放绘制表面，无内嵌浏览器。

## 效果预览

![仓鼠四宫格：正面站立、转头看你、抱着食物吃、抬头张望](assets/screenshots/overview.png)

## 怎么玩

| 操作 | 效果 |
| --- | --- |
| 在画面内移动鼠标 | 吸引仓鼠注意，或将它唤醒。 |
| 点击空白处 | 投喂食物，最多同时 10 粒。 |
| 按住食物拖动，再松开 | 移动或抛出食物。 |
| 点击黄色轮心 | 让仓鼠上跑轮。 |
| 按住窗口顶部拖动 | 移动窗口。 |
| 右键或 Control + 点击 | 设置置顶、窗口大小、水印和深色模式。 |
| 点击菜单栏爪印图标 | 调整相同设置、显示／隐藏仓鼠，或退出应用。 |

## 开发

克隆仓库，用 Xcode 打开 `hamster-mac.xcodeproj`，选择 `hamster-mac` scheme 和 **My Mac**，也可以使用以下脚本。

### 构建与运行

```sh
./run.sh
```

脚本构建 Release，构建成功后才结束旧进程并启动新版。从源码构建并安装：

```sh
./install.sh
# 可选：安装到当前用户目录
INSTALL_DIR="$HOME/Applications" ./install.sh
```

默认安装到 `/Applications/Hamster Pet.app`。两个脚本均可从任意工作目录调用。

### 自定义颜色

通过启动参数传入六位十六进制颜色，重启应用后生效：

```sh
./run.sh --hamster-query 'up_bodyColor=E6DEBE&up_wheelOuterColor=E33332'
```

支持参数：`up_bgColor`、`up_bodyColor`、`up_earColor`、`up_snoutColor`、`up_eyeColor`、`up_feetColor`、`up_tailColor`、`up_waterColor`、`up_foodColor`、`up_wheelColor`、`up_wheelOuterColor`、`up_wheelCenterColor`、`up_wheelSpokeColor`。深色模式会另外应用背景和光照效果。

### 验证

```sh
# AppKit 输入、缩放、设置、托盘交互与截图
bash scripts/snapshot-native.sh

# 引擎行为、颜色、绘制性能与参考算法对照
bash scripts/verify-native.sh /path/to/hamster-html

# Metal 与 Core Graphics 图像对照（需要可用的 Metal GPU）
bash scripts/verify-metal.sh

# 实际窗口的应用进程 CPU 占用对照：深浅色、30 FPS、隐藏状态
bash scripts/verify-metal.sh --benchmark
```

第二条命令需要单独的参考项目；省略路径时默认读取相邻的 `../hamster-html`。发布工作流会独立运行原生引擎检查，无需参考项目。

AppKit 验证输出截图至 `/private/tmp/hamster-native-*.png`。引擎检查覆盖投食、物理、行为状态、食物回收、约九分钟模拟和 13 项颜色设置；参考对照进一步比较抽样状态与场景几何。绘制检查还覆盖三档分辨率、深浅色切换、缓存释放和内存上限，并对照缓存与原始矢量绘制的逐像素结果和耗时。单帧绘制性能取决于设备，不代表整个应用的 CPU 占用。`verify-metal.sh` 在多个动画时刻对照实际 GPU 回读图像；`--benchmark` 使用同种子、置顶的大尺寸窗口和真实应用事件循环，每种渲染方式及主题预热一秒、测量八秒，并检查模拟和实际绘制帧数。CPU 百分比按进程全部线程的用户态及内核态 CPU 时间计算，100% 代表一个 CPU 核心；不含 WindowServer，也不代表 GPU 耗电。

### 发布

推送 `v1.0.2` 这类语义化版本标签即可触发 [GitHub Actions](.github/workflows/release.yml)。工作流执行测试、构建 `arm64` + `x86_64` 通用版本、生成 DMG／ZIP 和校验文件、验证打包后的应用能够启动，最后发布 GitHub Release。

在 Actions 中对分支手动运行工作流，可获取测试产物。本地打包：

```sh
bash scripts/package-release.sh 1.0.2
```

产物位于 `dist/`。当前流水线使用临时签名，无需配置签名密钥；Developer ID 签名与 Apple 公证需要另行配置凭据和流程。

### 实现

- [`HamsterView.swift`](hamster-mac/HamsterView.swift)：输入、舞台坐标、偏好设置、30 FPS 调度与兼容绘制。
- [`HamsterMetalRenderer.swift`](hamster-mac/HamsterMetalRenderer.swift)：按需提交 Metal 帧，使用模板缓冲处理填充、描边与水瓶遮罩，GPU 计算夜间光照。
- [`MetalGeometry.hpp`](hamster-mac/Native/MetalGeometry.hpp)：场景路径三角形展开、静态网格缓存和绘制命令导出。
- [`AppDelegate.swift`](hamster-mac/AppDelegate.swift)：应用生命周期与菜单栏控制。
- [`HamsterEngine.cpp`](hamster-mac/Native/HamsterEngine.cpp)：原生场景模型、Core Graphics 绘制、计时器与对象回收。
- [`Original.hpp`](hamster-mac/Native/Original.hpp)：参考算法的 C++ 转换结果，文件头保留源文件 SHA-256。

物理使用固定 30 FPS 时间步，卡顿时最多追赶三帧；更新在主线程串行运行，引擎定期回收不可达对象。Metal 默认使用四重多重采样抗锯齿（设备不支持时使用单采样），最多三个帧在途；没有独立的无限刷新循环，隐藏时停止提交并释放绘制表面。交互渲染不做像素回读或同步等待 GPU。可通过 `./run.sh --hamster-cpu-renderer` 强制使用 Core Graphics 诊断兼容问题。Core Graphics 回退路径中的静态背景和跑轮外框按实际像素尺寸缓存，缩放或切换主题时重建；两个缓存各限制为约 16 MiB，超大窗口回退到矢量绘制。节点绘制顺序仅在增删或交换层级时重新排序。窗口恢复显示时重新计时，不追赶隐藏期间的时间。Core Graphics 与浏览器在字体和抗锯齿上可能存在栅格化差异。

参考算法更新后，可使用 Node.js 和 TypeScript 重新生成移植代码：

```sh
node scripts/port-native.cjs /path/to/hamster-html/src/original.js
```

## 署名与来源

原始仓鼠由 **[aBowman](http://abowman.com/google-modules/hamster)** 创作；算法及署名字体来自参考项目对原始 SWF 的移植。本项目不将这些资源声明为原创，也不对其重新授予许可。参考项目的 `analysis/NOTES.md` 记录了源分析过程。
