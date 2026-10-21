# 应用私有的 69 字段状态提交模块

`modern_cpu_context_transaction.c/h` 提供真实旧 Hypervisor typed API 的完整字段快照、多字段暂存、持久提交、再次读回和显式恢复。覆盖 Q0–Q31、SCTLR_EL1、X0–X30、PC、FPCR、FPSR、SP_EL0/SP_EL1，共 69 字段、800 个不重叠寄存器字节。它是后续 macOS27 CPU 转换层的基础，目前只允许自有、同线程、从未运行的 CPU。

调用方先将 `VZTxn` 清零，并核实原提供者的文件 SHA、UUID、14 个真实入口及 RVA，再提供不可变的 typed callbacks。`VZTxnOwner` 必须记录当前 CPU 的真实生命周期、线程、代次和非零 epoch。原生上下文指针必须保持相同，版本必须仍为 `0x206879700000000e`；模块不修改版本，也不向原 macOS27 VMM 返回这个旧指针。

调用顺序为 `Bind → Snapshot → StageSIMD/StageReg/StageSys → Commit → Verify → Restore → Release`。Commit 成功后值继续保留，直到调用 Restore。两个 64 位 pending word 覆盖全部字段，包括 PC 至 SP_EL1 的高 word 五位。FPCR/FPSR 拒绝高 32 位；SCTLR 只接受原值、快照值或实际生产值 `0x30800180`。

提交前检查全部 69 字段和三个已审查脏标记；每次 typed write 后检查公开接口与原始状态读回，最后再次检查全部字段。中途失败时，已经尝试的 setter，包括可能先写入再返回错误的 setter，按逆序恢复。若线程、入口、owner、代次、epoch、上下文或版本发生变化，则拒绝继续对外来 CPU 写入。无法恢复的状态进入隔离状态；已提交的日志不能通过 Release 或重新 Bind 静默丢弃。

寄存器值恢复和脏标记恢复是两个独立结果。模块只读取原生 `0x670/0x678/0x748` 三个字，不直接写入或清除标记；这些结果不代表整个内核上下文的原子恢复，也不是 macOS27 的双向 dirty 转换。所有 setter 顺序执行，调用方必须独占并串行化 CPU 操作。

2026-10-04 的 iPad 原生探针 PID70456、父进程 wait0 验证了两批各 69 字段的持久提交、再次读回和精确恢复。第二批预先通过真实 typed API 建立了 68 个非零原值，并全部精确恢复。第一批 raw748 从 4 变为 5，恢复寄存器后仍为 5；因此第一批 `registerValuesExactlyRestored=true`、`nativeDirtyExactlyRestored=false`。CPU/VM 均销毁、worker 已 join，没有 run、guest map 或 GPU 调用。原始证据在 `DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-hypervisor-context-transaction-v6`。

冻结源的本地故障模型完成 1,873,136 个断言、883 个案例，包含部分写入、恢复错误、读回错误、所有权变化及 live foreign rebind；真实设备调用为零。模型证据不能替代原生运行。项目 C 文件仅调整了冻结源的 include 文件名，header 字节相同；项目动态库只完成本地构建，没有部署、添加信任或实际加载。

构建入口为 `VirtualMac/scripts/development/build-modern-cpu-context-transaction.py --output <新目录>`。它只构建应用私有库，使用 SDK 真实函数类型；不链接 Hypervisor/GPU，不安装或执行代码。

CPSR 的现代 state view、完整 system/control/AMX/GIC/SME 状态、原 VMM27 的 257 处直接 context 消费者、run/exit 闭环，以及 Swift/DiskImages2 依赖闭包仍未完成。69 字段测试通过不能作为完整 macOS27 CPU/VMM/VZ 或来宾指令执行的验收。
