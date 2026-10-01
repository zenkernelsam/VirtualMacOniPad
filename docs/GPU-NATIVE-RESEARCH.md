# GPU 主线研究：让 VM GPU 达到"真 Mac 虚拟机"水准

> 起始：2026-10-01 · 维护：Devin · 状态：**进行中**（持续更新）
> 用户目标（原话）：「尽量找到和解决现在虚拟机GPU不完美运作，想做到和Mac运行虚拟机一样的原生GPU支援能力」
> 已知痛点：Matlab、Devin(Electron GPU)、Qoder CN 等软件需 disableGPU 或崩溃。

---

## 1. 已确认的架构事实（逐字证据附后）

### 1.1 通路总图
```
客机 App (Metal/GLD/Quartz)
   └→ 客机 AppleParavirtGPU (IOAccelerator, MetalPluginClassName=AppleParavirtDevice)
        └→ virtio GPU 协议 → 宿主 ParavirtualizedGraphics.framework (PGDevice/PGFIFO/PGTask/...)
             └→ MetalSerializer.framework（命令序列化/反序列化）
                  └→ iPadOS Metal.framework → M1 GPU
```
- 客机内核对象（`ioreg` 逐字）：`AppleParavirtGPU`（IOAcceleratorES，`MetalPluginName=AppleParavirtGPUMetalIOGPUFamily`）、`AppleParavirtDisplay`（2732×2048，`external=Yes`）。
- 显示链路：`_VZGraphicsDevice` + `_VZFramebuffer` → `framebuffer state activated rate=30` → "已连接原生PVG帧缓冲区"（VirtualMac.log）。

### 1.2 版本错配（**核心矛盾**）
- payload 提取自 **macOS 13.2.1 (22D68)**：`Virtualization 104.7.1 / DTPlatformVersion 13.2`、`PG 13.0.34`（Info.plist 逐字）。
- 客机 = macOS **15.6.1**。**客机的 Metal/GLD/CoreAnimation 期望与 Ventura 代 serializer/PG 对话**，所有"不完美"大概率落在这一界面上。
- `vz/guest/OpenGLPVGCompat.m` 头注释逐字：
  > *"macOS does not advertise its Metal-backed OpenGL renderer for a paravirtual GPU. The renderer itself works over PVG, but the Ventura-era serializer rejects GLD's defaultRasterSampleCount hint and custom FSAA sample locations. This guest shim opts PVG into GLD and normalizes only those redundant overrides before the render pass is serialized."*
- → OpenGL 在客机里的实现 = GLD（Metal-backed GL 驱动）跑在 PVG 上；shim 做两件事：①让 PVG 设备对 GLD 可见（opt-in）；②归一化 serializer 不认的 render-pass 字段。当前 `DYLD_INSERT_LIBRARIES=/Library/VirtualMac/OpenGLPVGCompat.dylib` 已全局注入（本机 `launchctl getenv` 逐字）。
- `MetalBCSupportEnabled` 键 + `vz/host/native_bc_texture_support.m` + `vz/shaders/` = BCn 压缩纹理支持（Ventura serializer 不认识的 texture 类型，自建转换？待读实现）。

### 1.3 历史崩溃（已修）
- A/B 两类同源：`PGTask mappedAddressForOffset:` 回退 `base+offset` → SIGSEGV / `Corrupted library` 断言（`docs/VM-crash-fix-and-build-notes.md`）。修复=`create=YES`+已映射区间校验+安全失败。**这是"Electron 类 app 打崩整机"的根因，已修。**

### 1.4 现存失败签名（待补全）
| 软件 | 失败表现 | 推测层级 | 证据状态 |
|---|---|---|---|
| Matlab | 需 disableGPU | GLD/compat-profile OpenGL（Java2D/JOGL）| 待复现取证 |
| Devin | GPU 无法运转 | Chromium GPU 进程 Metal 路径 | 待复现取证 |
| Qoder CN | 曾致 VM 崩溃（已修）→ 现状？ | Electron/Chromium | 待回归验证 |
| （更多样本待收集）| | | |

---

## 2. 研究假设清单（按优先级）

> 每条假设都要落成"可测探针 + 判定证据"再动手。

- **H1：serializer 协议差距**。Ventura MetalSerializer 不理解 15.6.1 客机产生的部分命令/descriptor 字段（OpenGL shim 只归一化了 GLD 的两处，Metal 原生路径可能还有别的）。取证：对 MetalSerializer 做 symbol/字符串 diff（13.2.1 vs 15.6.1 本机 DSC 版）；客机内复现失败并抓 `vmm.stderr.log`/`pvg-trace.log`。
- **H2：feature set/capability 宣告**。PVG 向客机宣告的 Metal feature set / GPU family 与 GLD/框架期望不符 → app 探测时走 fallback 或直接 fail。取证：客机 `MTLDevice` 探针枚举 supportsFamily/supportedFeatureSets（仓库已有 `metal-device.m`、`hwprobe.m` 探针可编）。
- **H3：IOSurface/共享内存路径缺陷**。`IOSurfaceLookupFromXPCObject` 已被 vzxpchook rebind——显示/视频正常但某些 IOSurface 用法（video decode 输出、CamX、零拷贝纹理）可能未覆盖。取证：VT 已直通工作（7 user client），说明 IOSurface 主路径 OK；查还剩哪些 selector 没 hook。
- **H4：地址翻译残留**。mappedAddressForOffset 已修一类；PGTask 可能还有别的 offset→host 路径（例如非分段任务的 fast path、IOGPUKernelMappedMemory）有同类缺陷。取证：pvg_trace.m 全量 hook 点清单（subagent 在跑）+ IDA 对照。
- **H5：OpenGL compat 覆盖不全**。denylist 已有（firefox/sublime_merge/plugin-container…），说明作者已知 shim 与部分 app 不兼容。Matlab 可能需入 denylist（用软件渲染）或 shim 需扩展归一化字段。取证：客机内跑 Matlab/复现，看崩在哪层（GLD? serializer? PVG?）。

---

## 3. 下一步（可测第一步 + 验证方式）

1. **客机侧 GPU 能力基线探针**（本机可直接跑）：编译 `vz/development/probes/metal-device.m`+`hwprobe.m`+`metal-bc-probe.m`，输出 guest 看到的 MTLDevice feature set/registryID/GL 渲染器名。验收：把输出与真 Mac VM（Apple Virtualization.framework 标准 PVG）的已知输出对比——差异即 gap 清单。
   - 对照组获取：公开资料 + `web_search`（VZ PVG 的 Metal feature set 有社区记录）；如有真 Mac 可跑同一探针。
2. **Devin/Matlab 失败复现取证**：在本机（即客机）直接运行，抓 stderr/Console/crash report，定位失败层。验收：拿到逐字错误（如 `MTLReportFailure`、GLD error、PVG reject）。
3. **MetalSerializer 13.2.1↔15.6.1 差异分析**（IDA Instance4 / 本地 nm+strings）：列出 15.6.1 新增而 13.2.1 没有的序列化命令。验收：差异命令表。
4. **USB 侧**（与 GPU 解耦，并行）：IDA 反编译 `_attachUSBDevice:error:`。验收：反编译片段证明它绑定的 host 侧接口类别（IOUSBHost? AVP restore 专用?）。

## 4. 约束

- 客机内可自由编译/运行探针（烧的是 VM 的 vCPU，不影响宿主稳定性）。
- iPad 侧只读取证红线（AGENTS.md §2）。
- 重建 payload 必须过 `__text` 逐字节比对（VMGPU-REFERENCE §3.1）。

## 5. 证据存档

- `.diag/20260920-121651/`：诊断包抽取件
- 本研究引用的逐字输出已直接嵌在上文
