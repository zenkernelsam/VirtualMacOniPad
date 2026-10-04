# VirtualMac 虚拟磁盘 I/O 优化研究

更新时间：2026-10-04

本文只记录静态审计和安全的后续 A/B 设计，尚未修改 92、未切换当前 VM 的磁盘策略，也没有在运行中的 VMM 上做压力测试。

## 当前基线

`VirtualMac/vz/host/VirtualMacApp.m:5071` 使用：

```objc
initWithURL:readOnly:error:
```

然后把 attachment 放入 `VZVirtioBlockDeviceConfiguration`。这条旧构造器没有显式指定 caching/synchronization mode，实际默认策略由移植的 Virtualization.framework 决定，当前日志没有把它打印出来。

92 安装后的 iPad 只读元数据：

| 项目 | 观测值 |
|---|---:|
| `Disk.img` 逻辑大小 | 549,755,813,888 bytes（512 GiB） |
| `Disk.img` APFS 实际占用 | `ls -ls` 约 438,916,024 KiB（约 419 GiB） |
| `/private/var` 可用空间 | 约 1.1 TiB |
| 宿主文件系统 | APFS |

因此当前“读写慢”不能直接归因于空间不足；磁盘文件已经相当大，随机 I/O、APFS extent/写时复制、guest 内部 APFS 空间和同步策略都可能参与。没有匹配 workload 和 IOPS/延迟数据前，不声称已有单一根因。

## 已确认的高级入口

对实际打包的 Ventura Virtualization payload 做 `strings`/Objective-C 元数据审计，确认存在：

- `initWithURL:readOnly:cachingMode:synchronizationMode:error:`；
- `VZDiskImageCachingModeAutomatic=0`、`Uncached=1`、`Cached=2`；
- `VZDiskImageSynchronizationModeFull=1`、`Fsync=2`、`None=3`；
- 内部 `AsynchronousRawDiskImage`/`AsynchronousDiskImageAdapter`；
- `VZVirtioDeviceConfiguration` 的 `virtioQueueCount`/`setVirtioQueueCount:`，并由 `VZVirtioBlockDeviceConfiguration` 继承。

这些是实际 payload 中的类、selector、enum 或内部字符串，不代表每种组合都已在 iPadOS 16.3 上运行验收。

## 候选策略与风险

| 策略 | 预期 | 风险/判断 |
|---|---|---|
| Automatic + Full | 默认安全基线 | 写入延迟可能偏高；应先测基线 |
| **Automatic + Fsync** | 保留同步语义，减少 full barrier 级别开销 | 第一候选；仍需离线 A/B 和断电恢复验证 |
| Cached + Fsync | 可能改善重复读取和小写入合并 | 可能增加 iPad 内存/VM 压力；10 GiB guest 下必须观察 Jetsam/wakeups |
| Uncached + Fsync | 降低宿主 page cache 压力 | 通常不会改善随机 I/O；作为对照，不是默认优化 |
| Cached + None | 可能最快 | 断电/强杀后 guest 文件系统损坏风险高；禁止作为正式默认或在未批准时实测 |
| 提高 `virtioQueueCount` | 可能增加并发 I/O | guest block driver、VMM 和 iPad backing store 都要支持；不能猜 4/8 就打开 |

当前最稳妥的路线是先做 `Automatic + Fsync`，再单独评估 `Cached + Fsync`。`SynchronizationModeNone` 只可作为明确批准的诊断实验，不能以“速度快”冒充修复。

## 施工设计

把 attachment 创建封装成小函数：

1. 首先检查高级 selector 是否存在；
2. 从 VM 配置读取 profile（默认 `automatic-full`，候选 `automatic-fsync`、`cached-fsync`）；
3. 用 enum 数值调用五参数 initializer；
4. initializer 失败时记录错误并回退旧三参数 initializer；
5. 日志打印实际 profile、cachingMode、synchronizationMode 和 fallback；
6. 不改变 Disk.img 格式，不在 VM 运行时重建或搬移磁盘。

`virtioQueueCount` 应作为独立实验，不与 caching/sync 同包切换，否则无法判断收益来源。只有在 guest 侧确认多队列、VMM validation 成功且有 I/O workload 对照后才考虑施工。

## 必须先取得的证据

暂停 VM 后保存 Disk.img 与 bundle 元数据；启动后在同一 workload 下分别记录：

- guest `df -h`/APFS 可用空间、宿主 Disk.img 逻辑/实际占用；
- VMM CPU、wakeups、Jetsam/thermal 状态；
- macOS guest 文件复制、Xcode/应用启动、系统更新等 matched latency；
- VM 日志中的 attachment profile 和错误；
- 正常关机后重启，确认 guest 文件系统无校验/恢复异常。

读写测试必须串行、短时、先小文件；不在当前 92 上直接启用 `None`、不在线 defrag/重打洞、不对 Disk.img 做 destructive trim。若确认文件 extent 碎片是主因，另做离线复制到新 APFS 文件的可回滚方案，不能在运行中 VM 上整理原盘。

## 当前结论

项目已经具备把先进磁盘策略带入 VirtualMac 的 API 入口，最有希望的真实优化是显式 `Automatic + Fsync`，其次才是受控的 `Cached + Fsync` 或 virtio 多队列。当前 92 仍保持原策略；下一次用户方便停机后，先做 profile 可达性和 matched I/O A/B，再决定是否打 93。长期体验还取决于 guest APFS 空间、Disk.img extent 和宿主内存压力，不能仅凭构造器切换承诺“明显变快”。

## VirtualBox/VMware/QEMU 格式能否直接搬来

### 静态结论

对实际打包的 Virtualization.framework payload 做字符串和 ObjC 元数据搜索：

- 能看到 `RawDiskImage`、`AsynchronousRawDiskImage`、`Di2DiskImage`、`VZDiskImageFormat`、`.asif`、`raw-disk-io`；
- 没有 `VDI`、`VMDK` 或 `QCOW2` 格式名，也没有对应的 VZ attachment selector；
- 当前 VirtualMac 明确使用 `VZDiskImageStorageDeviceAttachment` + `Disk.img`，VZ block backend 自己管理异步 raw I/O。

因此不能把 VDI/VMDK/QCOW2 文件路径直接填入 `Disk.img`。若先用 `qemu-img`/VirtualBox/VMware 工具离线转换成 raw，再交给 VZ，得到的只是一次转换后的 raw 文件；性能取决于文件 extent、APFS 和 VZ cache/sync，不能把原格式的 COW/压缩层带进 VZ。

### 性能比较

| 方案 | 能否直接接入当前 VZ | I/O 特性 | 判断 |
|---|---|---|---|
| 当前 raw `Disk.img` | 可以 | VZ `AsynchronousRawDiskImage`，无额外 VDI/VMDK/QCOW2 元数据层 | 更适合作为低层基线，不代表当前策略已最优 |
| VirtualBox VDI dynamic/snapshot | 否 | 分配 bitmap、COW/snapshot 元数据 | 随机写可能增加寻址和写放大；格式本身不保证更快 |
| VMware VMDK sparse/snapshot | 否 | extent/COW/snapshot 层，具体性能依实现 | 需要 VMware 专用 backend；不能只移植文件格式 |
| QEMU QCOW2 | 否 | refcount、COW、可选压缩/缓存 | 通常多一层映射；对 macOS guest 随机写不应默认优于 raw |
| Apple `.asif`/DiskImages2 | 待运行时验证 | Apple 原生 disk-image/cache/snapshot 方向 | payload 出现 `.asif` 和 `Di2DiskImage`，但尚未证明 iPadOS16.3 VZ 可创建/挂载，不能直接替换 92 |

### 关于“VMware 已开源”

需要区分：VMware Workstation/Fusion 近年有免费授权变化，`open-vm-tools` 等组件开源，但 VMware 的完整 hypervisor、VMDK backend 和商业虚拟磁盘栈并不因此成为可直接移植到 VirtualMac 的开源实现。若指定某个 VMware Git 仓库或许可证，后续可以单独审计；在没有具体仓库前，不能把“免费”或“部分组件开源”当成完整磁盘后端已可复用。

### 可移植的真正技术

VirtualBox/VMware/QEMU 值得借鉴的是：异步 I/O、批量/多队列、host page cache 策略、discard/trim、离线 compact、快照元数据和崩溃一致性设计。当前项目最接近这些能力的安全施工顺序仍是：

1. VZ 原生 `Automatic + Fsync`；
2. 受控 `Cached + Fsync`，观察 10 GiB guest 下内存压力；
3. 独立验证 `virtioQueueCount`，不与 cache/sync 同包；
4. 若证实 raw 文件 extent 碎片，再做停机、复制、校验、可回滚的离线 repack；
5. 最后才探测 `.asif`/DiskImages2 是否能在本 payload/iPadOS 上安全创建并挂载。

禁止把 QCOW2/VDI/VMDK 的 COW 层塞进 VMM hook，也不在运行中的 `Disk.img` 上做 trim、打洞或 compact。

## 后续排队：挂起恢复后的 guest 时间

用户报告低电量、息屏或合盖后 iPadOS 会冻结 VM 进程；恢复进入 macOS guest 后，系统时间停在冻结时刻，需要手动校时。该现象符合 guest 虚拟时钟在 host suspend/resume 期间没有收到时间校正，不能归因于磁盘 I/O。后续应分别取 host resume 时间、VMM/GuestTools agent reconnect 时间和 guest `date`/time-sync 日志，再设计 resume-only 校时；不在本次磁盘包中混入时间逻辑。
