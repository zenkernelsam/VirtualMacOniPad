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
4. 运行期无 USB 外设；输入设备实际走 `_VZMacKeyboardConfiguration`/`VZMacTrackpadConfiguration`（App 日志逐字）；vzboot.m 备用路径用 `VZUSBKeyboardConfiguration`+`VZUSCScreenCoordinatePointing`（注释称 VZMac* 属 14+，与日志矛盾，待澄清）
5. GuestTools 走 virtio socket :505050，协议=QGA 风格 JSON；guest 启动参数 `-arm64e_preview_abi`

### 追加（GPU 首日取证）
- [x] 客机 GPU 实况：`AppleParavirtDevice` family 探测、BC7 可建、OpenGL shim 前后对比（0→2 加速渲染器）、`/Library/VirtualMac/OpenGLPVGCompat.dylib` 全局注入确认
- [x] **每日 GPU 复位风暴实锤**：20 份 Kernel gpuRestart（9/26 起），`submitEvent:INCOMPLETE` 签名；触发者跨 app（witchontheholyni/GitHub Desktop/WebKit/WindowServer）
- [x] APVFeatures 双层协商面摸清：宿主 Ventura 14 位 vs 客机 38 键 + `binaryVersion` 握手 + `PGSerializerFeatures.supportsOpenGL`（shim 要开的那一位）
- [x] OpenGL shim 机制全解（IOGLBundleName interpose + supportsFamily 谎报 Apple1-7 + 两处 sample-count 归一化 + Rosetta 内联顶点小缓冲）
- [x] vmmhook.m 地图：hv_* 全套 interpose、USB HCI swizzle 组（restore 桥服务端在此）、xpc/IOService/IOSurfaceCreate 改写、VMM 内存 2×physical 放宽
- [x] USB 桥服务端定位：`vmmhook.m:2171-2187` 在 VMM 进程内 bind `/tmp/vz-usb-restore.sock`（chmod 0666）；`installation_usb_shim.m` 是 MobileDevice 侧 shim；`vz/development/probes/usb_bridge_probe.c` 是现成联调探针
- [x] 审计疑点澄清×1：`_VZMacKeyboardConfiguration`/`VZMacTrackpadConfiguration` **确实存在于** Ventura payload（nm 逐字符号）→ vzboot.m 注释"14+ 才有"已过时，非路径矛盾
- [x] 客机活体 `HostConfiguration.plist`：`OpenGLAcceleration=1`、`OpenGLAllowed=1`、`Build=55-02a51a0c7c5808e5`（宿主策略下发正常）

### 阻塞/待用户
- 🔴 **iPad SSH 断**：22:53 起 `kex_exchange_identification: Connection reset by peer`（22/2222 都重置，TCP 可连）。宿主侧拿不到 `/tmp/vmm.stderr.log`/`/tmp/pvg-trace.log`（GPU 复位根因的决定性证据）。用户手动 sshd 重启失败（launchctl EPERM），**决定重启 iPad** → 客机随宿主断电，本会话终止。
- IDA Instance4 @13340 已写入 `~/.config/devin/mcp_config.json`（CLI 需重启生效）；待用户在 IDA 里加载 `VMGPU/Frameworks/ParavirtualizedGraphics.framework`。
- ~~vz/host 盘点 subagent（9e85a372）长跑未归~~ **已由主会话亲自动手完成**：审计文档 §2.4 全量 hook 面/装配点表（21 个 `__interpose`、hv_* 全套、USB HCI swizzle 组、10 个设备装配写点）。subagent 若后续归来可作交叉验证，无须重派。

### iPad 重启后的续会话行动清单（按序）
1. 用户在 iPad 上重跑 Dopamine 越狱（semi-untethered，必须重打）→ respring 后 SSH 才会回来。
2. 验证 SSH：`sshpass -p cisco ssh -p 2222 root@192.168.64.1 'echo ok'`（22 也试）。
3. **立刻拉** `/tmp/vmm.stderr.log`、`/tmp/pvg-trace.log`、`/var/mobile/Media/VirtualMac/Sequoia.bundle/VirtualMac.log` → 与客机 gpuRestart 时间戳对齐，定位 `submitEvent:INCOMPLETE` 的宿主侧原因（反序列化失败楔死/未知 opcode/宿主 Metal 挂起/内存双计 四选一）。
4. 若日志信息量不足 → 下一步是"诊断级"增强 pvg_trace（把命令 opcode 序列打到文件，重启后对账），标 diagnostic。
5. 顺便按 §"清理"条款处理 iPad 上 3×~1.1GB 旧诊断 zip（先 NAS 备份 manifest，再废纸篓/隔离）。
6. IDA Instance4 就绪后：PG fifo 命令分发反编译（优先 CMD=0x37 对应处理函数）+ `_attachUSBDevice:error:` 的 entitlement 检查路径。
