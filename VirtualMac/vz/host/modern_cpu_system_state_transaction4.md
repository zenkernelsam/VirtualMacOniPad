这是一组独立、应用私有的真实旧 provider 系统寄存器事务，供下一步有界 native 验证使用。它没有接入原 macOS27 VMM，不构造 Apple USER/VIEW/KernelContext，不运行来宾 CPU，也不能称为完整 macOS27 CPU 实现。原 69/70 字段源文件和冻结包没有修改。

实现复用已验证的私有 70 字段 journal/lifetime 流程，新增独立 `VZSysTxn4*` 符号。`VZTxnOps/Owner/Handle/Result` 使用原私有 ABI，同一 owner 的 `activeLease` 在 69、70 与 SYS4 之间双向排他。实际回调仍必须来自 Root 验证过的真实旧13 image/entry；`identityVerified` 只是入口的前置条件，不能凭这个布尔值代替 image/loaded-byte 验证。

| 字段 | 真 SDK typed ID | 旧只读 raw offset | 原27普通 group/offset | 原27真实保存消费者 |
|---|---:|---:|---:|---:|
| TPIDR_EL1 | c684 | 358 | 0 / 8 → 358 | 288550 → 保存对象+658 |
| TPIDR_EL0 | de82 | 360 | 0 / 10 → 360 | 288530 → 保存对象+650 |
| TPIDRRO_EL0 | de83 | 368 | 0 / 18 → 368 | 288570 → 保存对象+660 |
| CSSELR_EL1 | d000 | 388 | 0 / 38 → 388 | 287b14 → 保存指针 x21 |

每个字段宽8字节，合计32字节。官方本地 MacOSX27.0 SDK 枚举、旧13 mapper `5e2c..6658`、原27普通 mapper `6a3c..6de4` 与完整原 VMM 保存函数 `2875a8..28a258` 的离线证据见 `modern-cpu-system-state-contract-audit-v1/contract.json`。这两个保存边界由 LC_FUNCTION_STARTS 确认。152 个官方 SYS 枚举分别在两份原 mapper 的有限整数 CFG 中求值，共304例；原 VMM 完整保存函数内有132个真实 SYS typed 调用。静态解析只读取原 bytes 与相对 jump table，不加载或执行这些 Apple images。

四个字段的旧 mapper dirty mask 都为0，旧 public setter 进入 `6c8c` 的真实64位槽写入。原27 getter 通过真实 USER+10 指针，在 `5a70` group0 分支读 raw350+offset；原27 setter `7b68→7c0c` 同样直接写该槽，不要求 VIEW observer。SYS4 没有把原27 syscall、缓存/dirty 位置搬到旧 provider：它只调用真实旧13 typed get/set，raw offset仅用于只读交叉验证。

Bind 保存真实原 CSSELR。Stage 允许 TLS 的任意64位 typed 值；CSSELR 的诊断目标只允许 exact bind 值、exact snapshot 值或0..15，不宣称其他模式已经验证。四字段 Snapshot、Commit preflight、全组 readback、Verify 与显式 Restore 全部检查 owner/thread/lifetime/generation/lease/stateEpoch/providerEpoch/context pointer 和真实旧 native version `0x206879700000000e`。旧 native version 只读。CSSELR 和其他字段的 getter/setter失败也不会被当作成功。

真正 setter 在调用前加入 attempted，支持错误发生在写入前、部分写入后、完全写入后以及错误值回读。恢复按逆序调用 typed setter，并再读完整四字段。身份或 lifetime 改变时禁止向 foreign CPU 恢复。恢复失败保留 journal 并 quarantine。成功 Commit 持久保留请求值，必须明确 Restore；`Release` 不会丢弃已提交状态。

三个 native dirty words 670/678/748 只观察，不清零、不修复、不 forge。`registerValuesExactlyRestored` 与 `nativeDirtyExactlyRestored` 分开报告。四 SYS 的 old mask0 只是原机器码事实；真正 native 检查前不能声称整页或完整CPU状态没有其他副作用。这不是 kernel atomic transaction，调用方必须串行化同一 CPU 的全部操作，仅允许 owned 且 never-run CPU。

有意义的本地故障模型包含16组全字段持久提交/验证/恢复、每字段四种 setter 错误、每位置 restore error、16种 owner/provider/lifetime/context失效、各字段/dirty-word冲突、读回失败、错误 typed/raw 对照、提交后 restore 冲突、非法 high mask 和69/70/SYS4双向 lease排他。70 cases / 2396 assertions 全部通过；同一模型 ASan+UBSan 也通过。模型回调不调用 Hypervisor，因此这些结果只证明私有 journal 逻辑，真实 M2/iPad SYS API 的运行结果尚未验证。

后续可实现组另有 PAR_EL1（旧/新380、mask0）、AFSR0/1 与 AMAIR（旧418/420/3d8，新430/438/3f0，旧mask1）。它们已经静态定位，但没有加入此模块。带lazy-op8的组必须另外观察旧cache4100与dirty748真实状态，不能把新a08/4110结构复制到旧 context。

现代 VIEW 仍有明确缺口：原27 public SYS getter6678先调用6448、setter7d70先调用8238，SCTLR/CPACR/TTBR0/1/TCR/SPSR/ELR/ESR/FAR/MAIR/VBAR/CONTEXTIDR/CNTKCTL/虚拟计时器/SP_EL1/MDSCR进入 USER+2c0 的真实 VIEW。原69/70旧 typed 成功不等于这些现代状态合同已经实现。control16、EL2/SME/GIC/新 feature ID bank 等没有 old typed 等价证明的路径继续明确拒绝，不能返回旧 raw 指针给原27消费者。
