# 应用 GPU 兼容性映射（MATLAB / Devin）

更新时间：2026-10-02

这份记录把应用侧 workaround 与 VirtualMac 的可修复边界分开。目标是把修复下沉到虚拟 GPU 数据路径；只有在协议、资源生命周期和实际像素读回都成立时，才移除应用侧 workaround。

## 已有应用补丁对应的事实

| 应用/症状 | Desktop/Patch 现状 | VirtualMac 侧证据 | 当前判断 |
|---|---|---|---|
| MATLAB CEF `TS_PROCESS_CRASHED` | 将 `pthread_jit_write_protect_supported_np` 的检查结果改为 1 | 崩溃点是 CEF `brk #0`；该函数是 guest hypervisor/JIT 能力查询，不是 GPU 命令或像素路径 | 不能用 GPU shim 证明已修复；需单独研究 guest JIT 能力，不能删补丁冒险验证 |
| MATLAB Live Editor / Preferences 局部不刷新 | 把 `disable-gpu-shader-disk-cache` 改成 `disable-gpu`，并可注入 SwiftShader | CEF/ANGLE 使用 Metal 合成；当前 guest shim 主要覆盖 GLD 的 Apple7 profile、采样描述符和特定 Rosetta 顶点路径，未证明 CEF 合成/IOSurface 交换完整 | 真实缺口仍是 Metal command/present/IOSurface 路径；不能把 GL 标题读回通过当作 CEF 已修复 |
| MATLAB figure 曲线空白 | `Painters + docked` | 受控记录显示坐标轴可见、离屏 PNG 有曲线，但 OpenGL 屏幕管线第一次后损坏；现有 shim 明确未覆盖复杂 VBO + shader + MSAA resolve 组合 | 最有价值的 VirtualMac 方向是 MSAA/VBO/resolve 的最小读回回归；当前无足够证据直接改兼容层 |
| Devin Electron GPU | `~/.devin/argv.json` 开启 `disable-hardware-acceleration`；验证以 GPU helper 消失为准 | Chromium/CEF 的 GPU 进程会走 guest Metal/IOSurface；目前没有 Electron 专用完成证据 | 先做正常 GPU compositor 的独立诊断，再决定是否需要 Metal/IOSurface 修复；不能仅删除 argv 开关 |

## 本轮已落地的基础稳定性修复

88 启动日志同时出现：

```text
[GuestTools] guest menu extra not acknowledged; repair attempt 109
```

并且 guest 内 `/tmp/VirtualMacGuestTools.ready` 不存在。`VirtualMacGuestToolsApp.m` 原先要求 `statusItem.button` 和 `statusItem.menu` 都非空才写 readiness marker；在 Aqua 启动时工具已经执行 host configuration/OpenGL policy，但 status item 尚未完成时，宿主每 10 秒重复 payload repair。这与 22:49:38 的 `backboardd.wakeups_resource`（258 wakeups/s）及 Jetsam 中 VMM 为最大进程的时间线相符，但仍不是卡死根因证明。

现在 marker 只依赖 host token，表示工具进程已应用配置；构建回归生成 arm64/x86_64 guest tools、签名验证通过。该改动不改变 GPU 能力声明、Metal 协议或应用设置，待下一次正常关机/启动并安装包含它的包后验收：应出现一次 `guest menu extra acknowledged token`，不再出现 repair attempt 增长。

## 下一步数字闸门

1. 新包首启先看 readiness/repair 计数和 wakeups，确认基础循环消失。
2. MATLAB：在隔离用户配置下分别记录 CEF GPU helper、Live Editor 重绘、Preferences 重绘、figure 连续三次屏幕读回；离屏 PNG 不能替代屏幕读回。
3. Devin：仅在有 GPU helper 和真实 WebView 像素读回的基线后，才做一次去掉 `disable-hardware-acceleration` 的应用级 A/B；不改 `Desktop/Patch`，不把进程存活当成功。
4. 若 MATLAB/Devin 仍失败，按最小失败栈选择 Metal/IOSurface、MSAA/VBO 或 JIT 独立方向；禁止恢复 Tier2/协议 207、Apple9/4095 或全局 bypass。

## 90 版本闸门（2026-10-03）

当前不直接构建 90。静态审计确认 `OpenGLPVGCompat.m` 没有 `CGLFlushDrawable`、`glSwapBuffers` 或 drawable present hook；它只处理 capability、render-pass sample descriptor、Rosetta vertex buffer 和限定 particle shader。全局加入 flush/present hook 会改变 MATLAB、Devin、Godot 及其他 OpenGL 应用的时序，现有证据不足以证明它能修复 MATLAB figure。

构建 90 前必须同时满足：

1. 89 readiness 修复已在真实 guest 首启中产生 `guest menu extra acknowledged token`，且 repair attempt 不再增长；
2. MATLAB 取得带时间戳的窗口 drawable/屏幕像素失败证据，证明失败发生在 present 或上下文生命周期；
3. 新 hook 有最小进程范围、关闭开关、窗口/离屏负回归，并通过连续多帧读回；
4. Devin 的 GPU helper/WebView 像素 A/B 与 MATLAB 证据分开，不能用任一应用代替另一应用。

90 候选新增的宿主稳定性保护是 GuestTools repair 上限：同一 guest agent connection 最多执行 3 次 payload repair；仍未收到 readiness 后改为每 60 秒只 probe，不再复制/重装 payload。新 agent connection 会重置 generation 并重新允许 repair。该保护不改变 GPU 能力、协议或应用开关，目的是避免 readiness 故障放大成 VMM wakeup/内存压力。

90 候选包已构建为 `2:1.2.3+90.17dfa3e.gpuready`，但尚未安装；包交付 hash 和证据见 WORKLOG。该版本解决的是 GuestTools 负载放大风险，不声称已经改善 ANGLE、MATLAB CEF JIT 或全部 Metal 能力。

## Devin Electron 静态映射（2026-10-03）

已检查 `/Applications/Devin.app`（Electron 42.2.0 / Devin 1.126.0）：其 Electron Framework 的 load commands 同时包含 `Metal.framework`、`MetalKit.framework`、`OpenGL.framework` 和 `IOSurface.framework`；内部字符串包含 ANGLE WebGL、Metal、Vulkan、`CAMetalLayer` 与 WebGL2 路径。`~/.devin/argv.json` 当前启用 `disable-hardware-acceleration`，因此现状不能证明 ANGLE 的哪条后端失败。

VirtualMac 的 `OpenGLPVGCompat.dylib` 只对 `AppleParavirtDevice` 的 GLD profile、特定 render-pass descriptor、Rosetta vertex buffer 和已知粒子 shader 做处理；它没有覆盖 Chromium/ANGLE 的 Metal texture-sharing、`CAMetalLayer` present 或 WebGL backend。删除 Devin 的软件渲染开关前，必须用 GPU helper 存在、ANGLE backend 日志和真实 WebView 像素读回来证明这些路径；不能用 GLD probe 或进程存活替代。

隔离硬件模式启动 Devin（临时 HOME、临时 `--user-data-dir`，不读取用户配置）时，正常创建了 `Devin Helper --type=gpu-process`，且没有 `--disable-gpu` 或 `--use-gl=disabled`。该 GPU helper 的 `vmmap` 逐字显示加载 `AppleParavirtGPUMetalIOGPUFamily`、Metal、MetalKit、IOSurface、IOGPU 和 OpenGL。它证明 88 的 VirtualMac GPU 栈可被 Electron GPU 进程打开，但尚未证明 WebView/ANGLE 最终像素正确。

随后通过 Chromium CDP `SystemInfo.getInfo` 和 attached workbench renderer 的 `Runtime.evaluate` 完成像素闸门：`displayType=ANGLE_METAL`、`glRenderer=ANGLE (Apple, ANGLE Metal Renderer: Apple Paravirtual device, Version 15.6.1 (Build 24G90))`、`gpu_compositing=enabled`、`webgl=enabled`、`webgpu=enabled`、`processCrashCount=0`；renderer 内 WebGL2 `clear + gl.finish + gl.readPixels` 返回 `[26,51,77,255]`、`error=0`。这证明 Devin 的 ANGLE WebGL 基础 GPU 路径在当前 88 客机可用。仍未证明所有 WebView、视频、复杂 WebGPU 页面长期稳定，因此不直接修改用户 argv 配置。

同一 CDP renderer 的 `navigator.gpu.requestAdapter()` 也成功返回 adapter，`maxBufferSize=4294967292`、`maxTextureDimension2D=16384`，并报告 BC/ASTC/ETC2、shader-f16、subgroups、texture-formats tier1/tier2 等 features。该结果证明 Devin 的基础 WebGPU adapter 路径也可用；它不等于所有 WebGPU workloads 或视频/WebView 组合已经验收。

随后执行真实 WebGPU workload：创建 `bgra8unorm` texture，执行 clear render pass，提交 command buffer，copy 到 MAP_READ buffer 并读回像素；结果 `ok=true format=bgra8unorm pixel=[77,51,26,255]`。这证明基础 WebGPU resource/render/submit/readback 链路在当前 88 可执行。

### MATLAB 当前启动状态

在临时 HOME/`MATLAB_PREFDIR` 下启动当前 MATLAB R2024a，未修改安装或用户配置。25 秒采样时主 MATLAB 进程仍在，CEF 相关命令行出现 `--use-gl=disabled`；这确认现有应用侧 workaround 正在强制软件 GL。该结果不证明 VirtualMac 的硬件 CEF 路径失败，因为当前实验没有还原未补丁 CEF，也没有 GUI 像素 A/B。

## MATLAB JIT 能力边界（2026-10-03）

在当前 VirtualMac 客机内直接编译并运行只读 probe，得到：

```text
pthread_jit_write_protect_supported_np=0
```

该值与 MATLAB CEF `TS_PROCESS_CRASHED` 的逐字证据一致：CEF 在返回 0 时触发 `brk #0`。VirtualMac 当前 GPU/Metal/GL shim 没有改变 hypervisor JIT capability；把 getter 强制返回 1 会复刻 Desktop/Patch 的应用症状补丁，不能称 GPU 直通修复。若要消除该补丁，必须先证明 guest JIT entitlement、写保护切换和执行内存契约能在 VM 中合法实现；当前没有这样的运行时证据。

追加 probe 还尝试了匿名 RWX 映射和 `pthread_jit_write_protect_np` 切换：`supported=0`、`mmap ... errno=13 (EACCES)`；切换调用本身没有崩溃，但没有建立可执行内存契约。该结果进一步排除只伪造 getter 作为正式修复。

后续 `MAP_JIT` 专用 probe 修正了测试条件：未签名样本也能 `MAP_JIT errno=0`，写入 arm64 JIT code、开启 write-protect、执行并返回 `42`。这支持一个默认关闭的诊断 interpose：`VIRTUAL_MAC_JIT_CAPABILITY_COMPAT=1` 时仅把错误的 getter 结果纠正为 1；它尚未通过未补丁 MATLAB CEF A/B，因此不默认开启、不作为 90 正式能力。

## Qoder CN outstanding issue（2026-10-03）

用户报告 Qoder CN CLI/IDE 显示“当前使用软件渲染”。只读证据存在矛盾：用户配置 `~/.qoder-cn/argv.json` 中硬件禁用项是注释；隔离 Qoder CDP 的 `SystemInfo.getInfo` 报 `ANGLE_METAL`、`Apple Paravirtual device`、`gpu_compositing=enabled`、`opengl=enabled_on`、`webgl=enabled`、`webgpu=enabled`、`processCrashCount=0`，启动参数只有 `--disable-skia-graphite`。待取得正式 Qoder UI/CLI 的原文提示、当前用户 profile 的 featureStatus 和 WebGL/WebGPU 像素读回，才能判断是 Qoder 的 Graphite 状态误报、GPU crash guard、还是实际渲染回退。不要擅改 Qoder 配置或 app bundle。

正式 Qoder profile 的 attached workbench renderer 进一步完成 WebGL2 `clear + readPixels`：`version=WebGL 2.0 (OpenGL ES 3.0 Chromium)`、`renderer=WebKit WebGL`、`pixel=[51,77,102,255]`、`error=0`。因此当前 Qoder 实际硬件 WebGL 路径可用；“软件渲染”文案仍作为 outstanding issue，待定位其状态来源，不作为 VirtualMac GPU 失败证据。

### Instance1 内核证据

只读核对 macPad 的 Instance1（iPadOS 16.3 kernelcache）后，Hex-Rays 的 `_proc_check_map_anon @ 0xfffffe00092a68c4` 显示 `MAP_JIT` 路径必须经过 developer-mode/device-unlock 状态，并从进程 entitlement 查询 `dynamic-codesigning`；缺失时返回拒绝。kernel 字符串还明确写出 `MAP_JIT requires sandboxing` 与 `MAP_JIT requires the dynamic-codesigning entitlement`。因此 MATLAB CEF 的 JIT workaround 是 VM guest execution-policy 缺口，不能由 GPU 直通层安全伪造。
