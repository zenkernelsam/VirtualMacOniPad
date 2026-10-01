# WORKLOG — 逐条进度日志（压缩后先读本文件 + AGENTS.md）

## 2026-10-01（会话 1：接手 + 盘点 + GPU 研究启动）

### 完成
- [x] 读三份交接文档（SUPER-HANDOVER / VM-crash-fix-and-build-notes / VMGPU-REFERENCE）
- [x] 复述十条准则、区分战线已知/未知（见会话首轮回复）
- [x] **SSH 通道打通**：`sshpass -p cisco ssh -p 2222 root@192.168.64.1`（NAT 网关=宿主 iPad；22/2222 双通；密码问用户，勿入库）
- [x] 定位 iPad 侧关键路径：payload `/var/root/VirtualMac/payload/`；VM 数据 `/var/mobile/Media/VirtualMac/`；App 在 `/var/jb/Applications/VirtualMac.app`（→ preboot procursus）
- [x] 拉取诊断证据到 `.diag/20260920-121651/`（最新诊断包的小文件：manifest/Settings/logs/plist/2 份 VirtualMac.ips）
- [x] 黄金基线普查：`Virtualization.framework`（13.2.1 提取）**含 USB 类**（见审计文档 §4）
- [x] 客机 GPU 实况取证：`AppleParavirtGPU` IOAccelerator、`AppleParavirtDisplay` 2732×2048、`OpenGLPVGCompat.dylib` 已注入
- [x] 写 `AGENTS.md`（仓库根，压缩恢复用）
- [ ] `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md`（编写中，等 vz/host 盘点 subagent 报告合并）
- [ ] `docs/GPU-NATIVE-RESEARCH.md`（骨架+首批证据）
- [ ] iPad 诊断包清理：3×~1.1GB zip，价值文件已抽取 → 待用户确认后删（**先备份证据再删，已获原则同意**）
- [ ] commit + push（随文档完成执行）

### 关键新事实（详见审计文档）
1. payload = **macOS 13.2.1 (22D68) Ventura 提取**，服务 15.6.1 客机 → 版本错配是 GPU 问题温床
2. `OpenGLPVGCompat.m` 头注释逐字：*"the Ventura-era serializer rejects GLD's defaultRasterSampleCount hint and custom FSAA sample locations"*
3. App 端 `makeConfiguration` 两次字典下标 SIGSEGV（9/20，vmfix1 在装）——非 PG 另一只虫子
4. 运行期无 USB 设备；输入走 `VZUSBKeyboardConfiguration`+`VZUSCScreenCoordinatePointing`（Ventura 命名，非 macOS14+ 的 VZMac*）
5. GuestTools 走 virtio socket :505050，协议=QGA 风格 JSON；guest 启动参数 `-arm64e_preview_abi`

### 待办（下一步候选）
- IDA Instance4（:13340）反编译 `_attachUSBDevice:error:` → 判定 USB 直通在 iPadOS 16.3 的可行性/entitlement
- GPU：列 GLD/PVG 失配面清单；拿 Matlab/Devin 的失败签名（客机内可复现，Devin 就在本机？待确认 Patch 里 Devin 指什么——~/Desktop/Patch 只读）
- App `makeConfiguration` 崩溃定位（IDA app+733648 调用点）
- 诊断 zip 清理（用户已同意，证据已抽）

### 阻塞/待用户
- 无
