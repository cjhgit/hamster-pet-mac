# Canvas 仓鼠 · macOS 原生版

参考 `../hamster-html/README.md` 与对应源码实现的 macOS 应用。界面由 **AppKit + Core Graphics / Core Text** 原生绘制，仓鼠几何、行为状态机和物理算法转换为本地编译的 C++。不使用 WebKit、JavaScriptCore、网页、Flash 或远程脚本。

## 运行

使用 Xcode 打开 `hamster-mac.xcodeproj`，选择 `hamster-mac` scheme 和 My Mac，运行即可。支持 macOS 14 及以上。

一键构建、结束旧进程并启动（构建失败时保留旧进程）：

```sh
./run.sh
# 可直接传递应用启动参数
./run.sh --hamster-query 'up_bodyColor=E6DEBE&up_wheelOuterColor=E33332'
```

构建并安装完整 `.app` 到 `/Applications/hamster-mac.app`：

```sh
./install.sh
```

安装会在构建、复制和签名验证通过后结束旧进程，再替换已有版本。安装后可从「应用程序」启动。也可使用 `INSTALL_DIR="$HOME/Applications" ./install.sh` 指定安装目录；安装目录需要当前账户可写。两个脚本均可从任意工作目录调用。

手动命令行构建：

```sh
xcodebuild -project hamster-mac.xcodeproj -scheme hamster-mac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build CODE_SIGN_IDENTITY=- build
open .build/Build/Products/Release/hamster-mac.app
```

## 交互与外观

- 移动鼠标：注意、追随鼠标，在高处站起；睡眠时唤醒。
- 点击空白处：投食；按住拖动，松开下落，移动后松开可抛出；最多同时 10 粒。
- 仓鼠自主寻食、嗅闻、抓取、啃食，并回收食物池。
- 点击黄色轮心：让仓鼠上跑轮；保留惯性、疲劳、休息和自主上下轮。
- 空闲时保留随机走动、转头、洗脸、眨眼、喝水和睡眠。
- 点击 aBowman 署名，在默认浏览器访问原作者页面；聚焦画布后按 Tab 可聚焦署名，回车或空格打开链接，也可通过辅助功能操作访问。
- 无边框窗口，去掉标题栏和投食帮助文字；拖动画面外沿可移动窗口。
- 右键（或 Control + 点击）打开菜单，支持置顶/取消置顶、选择小（50%）、中（75%）、大（100%）三档窗口大小，以及关闭窗口。
- 窗口大小（含手动拖动调整的尺寸）和置顶状态自动保存，重新启动后恢复。
- 保留原版的 280 × 210 舞台、外框、底色、字体和颜色，画面等比缩放。默认窗口为 742 × 550，也可拖动窗口边缘调整大小。

原来的 13 项颜色参数可用启动参数传入，取值仍为六位十六进制颜色：

```sh
open .build/Build/Products/Release/hamster-mac.app --args \
  --hamster-query 'up_bodyColor=E6DEBE&up_wheelOuterColor=E33332'
```

支持 `up_bgColor`、`up_bodyColor`、`up_earColor`、`up_snoutColor`、`up_eyeColor`、`up_feetColor`、`up_tailColor`、`up_waterColor`、`up_foodColor`、`up_wheelColor`、`up_wheelOuterColor`、`up_wheelCenterColor`、`up_wheelSpokeColor`。重新启动应用后生效。

## 实现与性能

- `hamster-mac/HamsterView.swift`：原生窗口画面、鼠标/键盘输入、舞台坐标映射、作者链接与 30 FPS 更新调度。
- `hamster-mac/Native/Original.hpp`：从参考版 `src/original.js` 机械转换的 C++，保留全部原始算法，文件头记录源文件 SHA-256。
- `hamster-mac/Native/HamsterEngine.cpp`：编译执行的值/场景模型、Core Graphics 二次贝塞尔路径、遮罩、深度交换、独立毫秒计时器及内存回收。属性使用整数 ID，字体排版结果缓存复用。
- `hamster-mac/Resources/`：原版署名字体。

应用没有浏览器进程或脚本解释器。物理以原始 30 FPS 固定时间步运行，卡顿时最多追赶 3 帧；窗口完全被遮挡、隐藏或最小化时停止更新和绘制，恢复显示时推进经过的计时器时间。使用主线程串行更新，避免引擎与绘制之间的锁竞争；本地对象按可达性定期回收，避免循环引用或临时点持续积累。

## 验证

运行原生交互/行为、颜色、Retina 位图性能及参考算法对照：

```sh
bash scripts/verify-native.sh
```

脚本对照默认读取相邻 `../hamster-html`；也可传入其他参考项目目录：

```sh
bash scripts/verify-native.sh /path/to/hamster-html
```

验证包括投食、拖拽、抛出、重力、地面反弹、全部行为状态、食物池回收、约 9 分钟模拟、13 项颜色、16,000 帧中抽样的状态数值，以及 4 个动画检查点的全部场景路径坐标和样式。性能测试使用优化编译的引擎，在 1484 × 1100 位图上测量模拟与绘制总耗时；结果取决于设备，不代表整个窗口进程的 CPU 占用。

实际 AppKit 视图的截图验证：

```sh
bash scripts/snapshot-native.sh
```

输出标准窗口与窄窗口截图至 `/private/tmp/hamster-native-window.png`、`/private/tmp/hamster-native-narrow.png`。开发用 `snapshot-reference.cjs` 可读取参考项目的 Playwright，在固定随机种子下截图本地 HTML；仅用于视觉核对，不参与应用构建。

如参考算法更新，重新生成本地 C++（需要 Node.js 和 TypeScript；本机全局 TypeScript 也可使用）：

```sh
node scripts/port-native.cjs ../hamster-html/src/original.js
```

绘图算法、路径和行为数值已对照验证；Core Graphics 与浏览器的字体、边缘抗锯齿仍可能存在少量栅格化差异，不将这些差异描述为逐像素完全一致。

## 署名与来源

原始仓鼠由 **aBowman** 创作；算法及署名字体来自参考项目对原始 SWF 的移植。本项目保留原作者署名，不将这些资源声明为原创，也不对其重新授予许可。源分析记录见参考项目的 `analysis/NOTES.md`。
