# 包含真实旧 CPSR 的独立 70 字段状态事务

`modern_cpu_context_transaction70.c/h` 把原有 69 字段私有事务扩展为完整 70 字段 journal：Q0–Q31、SCTLR_EL1、X0–X30、PC、FPCR、FPSR、SP_EL0/SP_EL1，以及真正旧 Hypervisor 的 CPSR。寄存器读取宽度共 804 字节。它是应用私有转换层基础，已在独立 iPad 探针中执行，尚未接入原 VMM27；原 69 字段模块及其 ABI、冻结原生证据保持原样。

原 macOS27 VMM 的 typed 状态保存路径在 `0x2878d4` 请求 `HV_REG_CPSR`。旧13 `get_reg` 入口 `0x58d8` 的 CPSR lane `0x59c8..0x59dc` 读取真正 context `0x110` 的低4字节并零扩展；旧 `set_reg` 入口 `0x59fc` 的 lane `0x5b00..0x5b18` 写入相同位置的低4字节。因此第70项必须调用真实 SDK typed ID34，通过只读 raw110/4B 校验；不能把 CPSR 作为69 journal之外的一次额外 setter。

新私有类型 `VZTxn70`、函数和 field table 有独立符号。Ops、Owner、Handle、Result 精确共享原模块的私有类型；两个模块检查同一个 `owner.activeLease`，相同 CPU 生命周期不能同时持有69和70事务。字段 index69 使用 pending 高字 bit5；合法高 mask 从 `0x1f` 扩展到 `0x3f`，更高位拒绝。

调用顺序仍为 Bind → Snapshot → Stage → Commit → Verify/Observe → Restore → Release。Bind 同时保存真实 SCTLR 与 CPSR 原值；Snapshot、提交前冲突检查、提交后核对、Verify、Restore前冲突检查均覆盖完整70字段。失败 setter 在调用前写入 attempted journal，即使部分写入后返回错误也按逆序恢复；失去真实 provider、owner、线程、generation、lease、stateEpoch、context 或 native version 时禁止继续对外来 CPU 写入。失败恢复隔离该自有 lifetime，不静默丢弃 journal。

CPSR target 只接受 Bind 原值、Snapshot 原值或已有 no-run 诊断采用的 `0x3c5`，高32位拒绝。`0x3c5` 在这里是有限诊断目标，不证明任意 PSTATE 模式或来宾运行有效。仍只允许自有、同线程、从未 run 的 CPU。真正旧 native 版本必须保持 `0x206879700000000e`；模块不写 raw、dirty 或版本。三个真实 native dirty word `0x670/0x678/0x748` 只读；寄存器值恢复与 dirty 恢复各自报告，顺序 typed setters 不是内核原子事务。

原27的 CPSR getter `0x51800` 和 setter `0x51c80` 使用真正的 C++ state VIEW：构造函数 `0x4c8b0`、配置 flag `configuration+0x38`、64位缓存 `VIEW+0xb8`、observer `VIEW+0x158`、authenticated vtable slots `0x40/0x48`。getter 可能返回缓存；setter 可能把虚拟 mode8 转换为有效 native mode4，并运行真实 observer、锁与控制过渡。本模块仅提供真实旧 native CPSR，不实现这些现代语义，不能作为该 Apple VIEW、强制配置 flag0、用 no-op observer 或通过改版本骗过原27消费者。

2026-10-04，本地独立 fault 模型通过 1,922,564 个断言、895 个案例、0失败，包括128组完整70字段持久提交/多次核对/恢复、280 setter故障、71恢复错误、140读回故障、24类 lifetime/入口变化、所有70字段的提交/恢复前冲突以及69/70双向 lease 互斥。模型 register bank 有独立 offset/width 表和 typed callbacks；全部真实 Hypervisor、设备、run 调用为0。不能把这些本地模型调用计为 iPad 实测。

项目构建入口 `VirtualMac/scripts/development/build-modern-cpu-context-transaction70.py --output <全新目录>` 已完成应用私有 arm64e 动态库构建、严格签名与 dyld 静态验证；原自然 CPU subtype 保留 `0x80000002`，平台/min/sdk 记录为 iOS14.5。唯一库依赖为 stock libSystem，15个导出仅新 VZTxn70 函数和字段表，没有 Hypervisor/GPU 导入、constructor 或 interpose。库尚未安装、添加信任或真实加载。

本轮完整证据位于 `DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-cpu-native-cpsr70-private-v1`。后续有限 native 验证必须通过真实旧 provider 的路径/UUID/SHA/入口加载身份、自己创建的 never-run CPU、完整70字段持久提交/核对/恢复、最终真实 CPU/VM destroy 与 worker join证明，且明确 no run/map/GPU。通过该测试仍不能验收现代 VIEW、原27完整 context、CPU执行、run/exit、DiskImages2 或完整 macOS27 VMM/VZ。

原生验证于2026-10-04完成：`modern-hypervisor-context-transaction70-native-v1`，
PID73020、直接父进程 wait0。单个自有 never-run CPU 生命周期内，两批完整70字段
各804B提交、持久核对、恢复通过，共140实际字段记录；第二批68项非CPSR字段
从已验证非零原值开始。两批CPSR都实际0→0x3c5→0，CPU/VM销毁和worker join
成功。原始stdout SHA为
7321ab4b8d268e4b75a984bb82e6950c757d195c9301c5bf694cf5542fdb5f13。
真实旧provider与探针前后SHA/CD一致，native版本及dirty只读。
此验证静态编入模块的探针，不代表上面单独项目动态库整文件已加载，
不证明内核dirty恢复、内核原子性、现代VIEW或来宾指令执行。
