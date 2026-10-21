# 普通寄存器桥接：独立的 36 字段切片

`modern_cpu_scalar_slice.c/h` 提供应用私有 VZScalar API，覆盖 X0–X30、PC、FPCR、FPSR、SP_EL0 和 SP_EL1。它与已有的 33 字段向量/SCTLR 切片独立，保留各自 ABI 和 64 位意图掩码。

调用方必须先核实真实旧 Hypervisor 提供者及入口 RVA，再提供 SDK typed get/set 回调。每次操作验证活 owner、线程、ID、generation、context 地址和原生版本。FPCR/FPSR 仅接受 32 位目标；CPSR 的现代条件分派尚未解决，因此不提供。SP 使用真实逻辑系统寄存器 API，不推定新27的 raw SP 布局。适配器不手写任何原生 raw 状态、dirty 标记或版本号。

RoundTripOne 暂时写入一个意图、核对公开与原始缓存读回，再准确恢复保存值；包括部分写入后 API 报错的路径。这是可逆往返操作，成功仍恢复原值，并不是供来宾长期运行的持久提交接口。旧内核上下文指针不暴露给原27 VMM。

2026-10-04 独立 iPad 原生探针 PID69309、父进程 wait exit0：36 个非零且不同目标的公开/raw读回、准确恢复、worker join、CPU/VM 销毁和原版本不变全部通过。84564 项本地 Mock 检查包括9216次非零原值往返、324条失败路径和13种失效所有权场景；Mock 数量不代表硬件执行检查。探针不映射或执行来宾指令、不调用GPU，未测试原27直接 context 消费者。

独立构建：`python3 VirtualMac/scripts/development/build-modern-cpu-scalar-slice.py --output <新的输出目录>`。构建使用 SDK 的真实函数类型，产物无诊断启动权限、无直接 Hypervisor/GPU 导入；脚本不安装、不添加 trustcache、不执行原生 VM。当前生产 CPU/VMM/VZ 仍是13.2.1，此库尚未连接生产原27调用点。
