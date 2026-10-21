# 原 macOS27 标量读取函数的私有缓存桥

模块调用原 macOS27 Hypervisor 的真实内部读取函数 RVA `0x3810`，覆盖 X0–X30、PC、FPCR 和 FPSR 共34项。调用方必须验证完整原件的 SHA、UUID、平台及292字节函数体，并提供保持不变的身份、线程、epoch 和检查回调。模块复制调用方独占的0x350字节缓存，在调用前后再次检查身份，采用原调用点的隐藏 x8 目的地及 arm64e IA/0认证 ABI。

这份缓存和24字节holder都是应用私有数据。它们没有Apple CPU生命周期、state view或vtable；不能提供给其他Hypervisor函数，也不能返回给原27 VMM。项目接口仅接受ID0..33，CPSR34在C与汇编两层拒绝。返回wire仅按payload0..7和flag8读取，没有将其冒称完整C++ `std::expected` 类型。输出不得与输入重叠；guard失败不修改输出。

2026-10-04，iPadOS16.1.1/M2的独立probe PID71457实际通过8批×34=272个非零读取，以及16个无效ID的真实错误返回。12项护栏、单独汇编CPSR拒绝、缓存及输出canary均通过；原生进程父wait0。原27函数体292字节与提供的27原件逐字相同，其SHA为 `f0d89a925a82de3a6d7feb09c0b1b81692d87a55d87b4683d6f877c2b89a2216`。原始记录为 `DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-hypervisor-original27-scalar-accessor-v1`。

测试输入是明确的自有模式缓存，不是live CPU。没有调用公开CPU wrapper、创建VM/vCPU、执行来宾指令或提交GPU工作。它证明了一个原27受限消费者读取路径，不证明完整新内核context或原27 VMM运行。69字段持久提交模块与本模块尚未在同一个live CPU路径连接；CPSR条件状态、现代dirty双向转换和run/exit同步仍须实现。

`build-modern-cpu-scalar-read-bridge.py --output 新目录` 只构建本地应用私有库。项目动态库没有部署或添加信任；真实probe静态编入相同C/h/S源码，另外加载已有原27 Hypervisor与两项运行库。
