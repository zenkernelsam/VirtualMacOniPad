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

