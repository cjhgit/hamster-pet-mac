# Hamster Pet

**English** | [简体中文](README.zh-CN.md)

<img src="assets/branding/hamster-logo.png" alt="Hamster Pet logo" width="112">

A little hamster for your Mac. Feed it, watch it run on its wheel, and keep it nearby without cluttering your Dock.

**[Download the latest release](https://github.com/cjhgit/hamster-pet-mac/releases/latest)** · macOS 14+ · Apple silicon & Intel

Want to try it before installing, or don't have a Mac? **[Play the web version](https://cjhgit.github.io/hamster-html/)** in your browser. Its source is available in the **[hamster-html repository](https://github.com/cjhgit/hamster-html)**.

## 3D branch

This branch uses actual, deformable SceneKit / Metal meshes for the hamster, bottle, night lamp, and a barrel-plank running wheel that keeps its red rims. The hamster retains its beige body, dark contours, cream muzzle, and outlined ears.

Drag to orbit, scroll or pinch to zoom, Shift-drag to pan, click to feed, and Command-drag food. Keys **0–6** select front/reset, three-quarter, right, rear, top, left, and hamster close-up.

Press **Space** (or the right-click menu's **暂停播放**) to freeze playback. While paused, **→** or **.** advances exactly 1/30 second; camera controls remain available and scene clicks no longer feed. Enable **调试工具** (debug tools) in the right-click menu to show the bottom-left Pause/Resume, Next-frame, and frame-counter controls. The menu's **帮助** (Help) item opens a full guide covering interactions, camera keys, menu options, and the hamster's daily routines. `bash scripts/verify-playback.sh` checks playback controls, pose freezing, visibility changes, and resume timing in a real window.

Body and limbs follow the original simulation’s articulated control points, wrist/toe trajectories, and gait phases. A smooth volume union keeps the head and torso connected as they bend; the legs and paws deform and wheel contacts stay inside the running surface.

`bash scripts/verify-hamster-motion.sh` exercises 13 behavior/transition scenarios over 1,560 frames and writes synchronized reference images, orbit views, gait GIFs, silhouette comparisons, and timing data to `/private/tmp/hamster-motion/`.

The 3D body field sampling, shared-edge intersections, triangulation, smoothing, normals, and coat coordinates run in Metal compute shaders. The CPU provides compact pose/profile parameters; SceneKit consumes the generated Metal vertex/index buffers directly. Each output remains immutable once handed to SceneKit. Playback waits for compute completion and reads only counters, without reading back vertices or pixels. GPU outlines share skin geometry; unchanged surfaces are reused. Simulation remains at 30 FPS with the same resolution, smoothing, body profiles, and foot trajectories. Unsupported devices or compute failures fall back to the CPU reference; `./run.sh --hamster-cpu-body` forces that path. Motion tests assert the backend so silent fallback cannot hide a failure.

Limbs, paws, tail, and mouth strokes share material batches while retaining independent deformation, normals, and outline widths. Batched vertices go directly into a shared Metal buffer; all attributes and outlines share one immutable output, avoiding SceneKit uploads for each attribute. Fixed topology, circle samples, leg blend weights, and head profiles are cached. Eyes and ear rims use native head-local controls and node translation, retaining blink deformation. Ordinary static geometry is flattened; inverted-hull outlines keep their original hierarchy and occlusion. Apple GPUs use a fixed-capacity Metal output heap with independent immutable frame resources, falling back to standalone allocations when necessary. `SCNRenderer` encodes the real 3D scene into an on-demand `MTKView`; scene changes explicitly submit frames, without a separate `SCNView` refresh loop or duplicate rendering at the display refresh rate. Overlay layout updates only when its inputs change. Screen sleep, inactive sessions, and app hiding stop simulation and visibility polling; hidden-window fallback checks run twice per second. Resume resets timing without catching up.

Use `python3 scripts/profile-running-app.py --sample` to measure the **already-running application**, saving interval CPU time differences, resident memory, and a stack sample to `/private/tmp/hamster-app-profile/`. Keep its window visible and record the behavior, size, and theme. Random behavior changes the workload between samples. CPU percentages include all process threads, with 100% = one core; they exclude WindowServer and GPU power. Options include `--interval 10 --count 6` and `--pid`.

`bash scripts/verify-3d-performance.sh` is a separate controlled test window: 742 × 558, idle, continuous walking/turning, full-speed wheel, night, sleep, pause, hidden windows, display sleep, and inactive sessions. It verifies movement throughout the walking sample, checks simulation FPS, actual Metal presentation submissions, and the meshing backend, records visible geometry elements, saving CPU results to `/private/tmp/hamster-3d-performance/current.json` and reporting simulation/scene CPU time and GPU meshing time separately. Use `--scenario sleep` to isolate a scenario. Its numbers do not replace measurements of the actual running app.

Run `./run.sh` to build and launch. `bash scripts/verify-3d.sh` validates meshes, camera projection, and input, with screenshots in `/private/tmp/hamster-3d/`.

Before adding features, read the [performance optimization and regression guide](docs/performance-guide.md) for profiling, implementation constraints, known pitfalls, diagnostic switches, and verification commands. See [3D performance measurements](docs/3d-performance-20261018.md) for test conditions and separate real-app and controlled-scene results. Both documents are in Chinese.

## Install

1. Download the **DMG** from [Releases](https://github.com/cjhgit/hamster-pet-mac/releases/latest).
2. Open it and drag **Hamster Pet.app** into **Applications**.
3. Launch **Hamster Pet**. The hamster window and a paw icon in the menu bar will appear.

A ZIP download and SHA-256 checksums are also available. No Xcode or build tools are needed to use a release.

### First launch

The current releases are ad hoc signed and have not been signed with an Apple Developer ID or notarized. If macOS blocks the first launch, attempt to open the app, then go to **System Settings → Privacy & Security → Open Anyway** and follow the confirmation prompts. You do not need to disable system security protections.

## Features

- **An interactive pet:** feed, drag, and toss food; watch your hamster eat, drink, groom, sleep, and run on its wheel.
- **Menu bar companion:** show or hide the window from the paw icon. Closing the window keeps the app running; choose **退出 Hamster Pet** to quit.
- **A flexible window:** rounded corners, a draggable top area, always-on-top mode, three size presets, and manual resizing.
- **Comfortable dark mode:** a blue-gray background, clear pet and food colors, a dimmer water bottle, and a small decorative warm lamp.
- **Remembered preferences:** window size, always-on-top mode, watermark visibility, and dark mode survive restarts.
- **Native GPU rendering:** Metal draws the vector scene and night lighting at 30 FPS, with an automatic Core Graphics fallback when a GPU is unavailable. Animation pauses and rendering surfaces are released while hidden, minimized, or fully covered. No embedded browser.

## Take a look

![Hamster Pet: standing, looking around, enjoying a snack, and looking up](assets/screenshots/overview.png)

## How to play

| Action | What happens |
| --- | --- |
| Move the pointer in the scene | Attract the hamster's attention or wake it up. |
| Click empty space | Drop food, up to 10 pieces at a time. |
| Hold and drag food, then release | Move it around or toss it. |
| Click the yellow wheel center | Invite the hamster onto the wheel. |
| Click the bottle bottom or drinking nozzle | Guide the hamster to drink water. |
| Click the hamster | Pet it: it slows down and finishes its steps, then squints and relaxes for 3 seconds. The wheel keeps its inertia. Click again to extend. |
| Drag the top of the window | Move the window. |
| Right-click or Control-click | Change always-on-top, size, watermark, and dark mode settings, toggle debug tools, or open help. |
| Click the paw icon in the menu bar | Access the same settings, show/hide the hamster, or quit. |

The current app menus use Simplified Chinese: **置顶 / 取消置顶** means always on top / turn off always on top, **窗口大小** means window size, **显示水印** means show watermark, **深色模式** means dark mode, **调试工具** means debug tools, and **帮助** means help.

## Development

Clone the repository and open `hamster-mac.xcodeproj` in Xcode. Select the `hamster-mac` scheme and **My Mac**, or use the scripts below.

### Build and run

```sh
./run.sh
```

This builds Release, stops the previous app only after a successful build, and launches the new app. To build and install from source:

```sh
./install.sh
# Optional: install for the current user
INSTALL_DIR="$HOME/Applications" ./install.sh
```

The default installation is `/Applications/Hamster Pet.app`. Both scripts can be called from any working directory.

### Custom colors

Pass six-digit hexadecimal colors at launch; changes take effect after restarting the app:

```sh
./run.sh --hamster-query 'up_bodyColor=E6DEBE&up_wheelOuterColor=E33332'
```

Supported parameters: `up_bgColor`, `up_bodyColor`, `up_earColor`, `up_snoutColor`, `up_eyeColor`, `up_feetColor`, `up_tailColor`, `up_waterColor`, `up_foodColor`, `up_wheelColor`, `up_wheelOuterColor`, `up_wheelCenterColor`, and `up_wheelSpokeColor`. Dark mode applies its own background and lighting treatment.

### Verification

```sh
# AppKit input, scaling, settings, tray behavior, and screenshots
bash scripts/snapshot-native.sh

# Engine behavior, colors, rendering performance, and reference parity
bash scripts/verify-native.sh /path/to/hamster-html

# Compare actual Metal and Core Graphics images (requires a Metal GPU)
bash scripts/verify-metal.sh

# Application-process CPU comparison with real windows, both themes and hidden state
bash scripts/verify-metal.sh --benchmark
```

The second command requires the separate reference project, which defaults to the sibling directory `../hamster-html` when no path is supplied. The release workflow runs the standalone native engine checks without that reference project.

AppKit verification writes screenshots to `/private/tmp/hamster-native-*.png`. Engine checks cover feeding, physics, behavior states, food recycling, a simulated nine-minute session, and all 13 color settings. Reference checks additionally compare sampled state and scene geometry. Rendering checks also compare cached and original vector output pixel by pixel at three resolutions, exercise theme changes, cache release and memory limits, and report both rendering times. Single-frame timings depend on the machine and do not represent the app's total CPU usage. `verify-metal.sh` compares actual GPU readbacks at multiple animation checkpoints. Its `--benchmark` mode uses a fixed seed, a pinned large window, and the native application event loop, warming up for one second and measuring eight seconds per renderer/theme while checking simulation and rendered frame counts. CPU percentages use user plus system time across all process threads, with 100% representing one CPU core; they exclude WindowServer and do not measure GPU power.

### Releases

Push a semantic version tag such as `v1.0.2` to trigger [GitHub Actions](.github/workflows/release.yml). The workflow tests the app, builds an `arm64` + `x86_64` universal binary, creates DMG and ZIP packages with checksums, verifies the packaged app launches, and publishes a GitHub Release.

A manual Actions run on a branch creates downloadable test artifacts. To package locally:

```sh
bash scripts/package-release.sh 1.0.2
```

Output goes to `dist/`. The current pipeline uses ad hoc signing and requires no signing secrets. Developer ID signing and Apple notarization would need separate credentials and configuration.

### Implementation

- [`HamsterView.swift`](hamster-mac/HamsterView.swift): input, scene coordinates, preferences, 30 FPS scheduling, and fallback rendering.
- [`Hamster3DRenderView.swift`](hamster-mac/Hamster3DRenderView.swift): on-demand 3D presentation, submission counters, and explicit screenshots.
- [`HamsterBodyGPU.swift`](hamster-mac/HamsterBodyGPU.swift): Metal surface generation, shared vertices, and buffer allocation.
- [`HamsterDeformableModel.swift`](hamster-mac/HamsterDeformableModel.swift): native articulation, deformation, fixed topology caching, and material batching.
- [`HamsterMetalRenderer.swift`](hamster-mac/HamsterMetalRenderer.swift): on-demand Metal submission, stencil coverage for fills/strokes/masks, and GPU night lighting.
- [`MetalGeometry.hpp`](hamster-mac/Native/MetalGeometry.hpp): path triangulation, static mesh caching, and draw-command export.
- [`AppDelegate.swift`](hamster-mac/AppDelegate.swift): application lifecycle and menu bar controls.
- [`HamsterEngine.cpp`](hamster-mac/Native/HamsterEngine.cpp): the native scene model, Core Graphics rendering, timers, and object reclamation.
- [`Original.hpp`](hamster-mac/Native/Original.hpp): generated C++ port of the reference algorithms, with the source SHA-256 recorded in its header.

Physics uses fixed 30 FPS steps with at most three catch-up frames. Updates run serially on the main thread, and unreachable engine objects are reclaimed periodically. Metal uses 4x MSAA when supported (otherwise single sampling), permits at most three frames in flight, and has no independent continuous draw loop. Hidden windows stop submitting and release drawing surfaces. The 2D Metal path never reads pixels back or synchronously waits for the GPU during interactive rendering. Use `./run.sh --hamster-cpu-renderer` to force Core Graphics for diagnosis. In the Core Graphics fallback, the static background and wheel frame are cached at device resolution and rebuilt when the scale or theme changes. Each of the two caches is limited to about 16 MiB; oversized windows fall back to vector drawing. Child draw order is sorted again only when nodes are added, removed, or change depth. Resuming a window resets timing without catching up on time spent hidden. Core Graphics and browser rendering may differ in typography and antialiasing.

If the reference algorithms change, regenerate the port with Node.js and TypeScript:

```sh
node scripts/port-native.cjs /path/to/hamster-html/src/original.js
```

## Credits

The original hamster was created by **[aBowman](http://abowman.com/google-modules/hamster)**. Its algorithms and attribution font come from the reference project's port of the original SWF. These resources are not claimed as original work and are not relicensed by this project. The reference project's `analysis/NOTES.md` documents the source analysis.
