# Hamster Pet

[English](README.md) | **简体中文**

<img src="assets/branding/hamster-logo.png" alt="Hamster Pet 图标" width="112">

住在 Mac 上的小仓鼠。投喂、看它跑轮，让它陪在身边，不占用 Dock。

**[下载最新版本](https://github.com/cjhgit/hamster-pet-mac/releases/latest)** · macOS 14 及以上 · 支持 Apple 芯片和 Intel

没有 Mac，或想在安装前先试玩？可以直接在浏览器中打开 **[网页版试玩](https://cjhgit.github.io/hamster-html/)**，源码见 **[hamster-html 仓库](https://github.com/cjhgit/hamster-html)**。

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
- **原生绘制：**使用 AppKit 和 Core Graphics，无内嵌浏览器；窗口隐藏、最小化或完全被遮挡时暂停动画。

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
```

第二条命令需要单独的参考项目；省略路径时默认读取相邻的 `../hamster-html`。发布工作流会独立运行原生引擎检查，无需参考项目。

AppKit 验证输出截图至 `/private/tmp/hamster-native-*.png`。引擎检查覆盖投食、物理、行为状态、食物回收、约九分钟模拟和 13 项颜色设置；参考对照进一步比较抽样状态与场景几何。绘制性能取决于设备，不代表整个应用的 CPU 占用。

### 发布

推送 `v1.0.2` 这类语义化版本标签即可触发 [GitHub Actions](.github/workflows/release.yml)。工作流执行测试、构建 `arm64` + `x86_64` 通用版本、生成 DMG／ZIP 和校验文件、验证打包后的应用能够启动，最后发布 GitHub Release。

在 Actions 中对分支手动运行工作流，可获取测试产物。本地打包：

```sh
bash scripts/package-release.sh 1.0.2
```

产物位于 `dist/`。当前流水线使用临时签名，无需配置签名密钥；Developer ID 签名与 Apple 公证需要另行配置凭据和流程。

### 实现

- [`HamsterView.swift`](hamster-mac/HamsterView.swift)：绘制、输入、舞台坐标、偏好设置与 30 FPS 调度。
- [`AppDelegate.swift`](hamster-mac/AppDelegate.swift)：应用生命周期与菜单栏控制。
- [`HamsterEngine.cpp`](hamster-mac/Native/HamsterEngine.cpp)：原生场景模型、Core Graphics 绘制、计时器与对象回收。
- [`Original.hpp`](hamster-mac/Native/Original.hpp)：参考算法的 C++ 转换结果，文件头保留源文件 SHA-256。

物理使用固定 30 FPS 时间步，卡顿时最多追赶三帧；更新在主线程串行运行，引擎定期回收不可达对象。Core Graphics 与浏览器在字体和抗锯齿上可能存在栅格化差异。

参考算法更新后，可使用 Node.js 和 TypeScript 重新生成移植代码：

```sh
node scripts/port-native.cjs /path/to/hamster-html/src/original.js
```

## 署名与来源

原始仓鼠由 **[aBowman](http://abowman.com/google-modules/hamster)** 创作；算法及署名字体来自参考项目对原始 SWF 的移植。本项目不将这些资源声明为原创，也不对其重新授予许可。参考项目的 `analysis/NOTES.md` 记录了源分析过程。
