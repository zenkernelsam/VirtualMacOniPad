普通向量寄存器适配层

modern_cpu_register_slice.c/h 从独立 v4 候选迁入，只有 include 文件名改变。它保存 Q0–Q31 和 SCTLR_EL1 的应用私有快照及单字段写入意图，使用真正的 SDK 向量类型和原 Hypervisor 13 的 typed API。向量参数遵循 q0 的 ABI；SCTLR 使用逻辑寄存器接口。提交测试会读回 API 值及原上下文缓存，再准确恢复先前保存的值。setter 返回错误时仍尝试恢复，恢复失败会阻止成功结果。

同线程、资源所有权、generation、实际 context 地址及原缓存版本都必须匹配。64 位意图掩码支持 Q31 和第 33 个 SCTLR 字段，避免 32 位移位溢出。上下文只读；内核版本和脏标记由原生 API 管理。未知寄存器、SVE/SME 和新上下文布局没有被声明支持。

2026-10-04 在 M2/iPadOS16.1.1 上，v4 原生进程 67135 实际验证了全部 33 个字段：写入、API/raw 读回、准确恢复、自有 vCPU/VM 销毁和子进程退出均通过。此前本地 8,192 组向量模式及失败路径共 73,801 项检查通过。这些结果只证明寄存器适配；探针没有执行来宾指令。v2 的规范路径检查失败记录保留，v3 修复后验证通过。

构建命令：python3 VirtualMac/scripts/development/build-modern-cpu-register-slice.py --output <新目录>。脚本只生成并签名应用私有库，不安装或添加 trustcache。库不替换 Apple 的 context 指针，也未接入原 macOS27 VMM 的直接上下文访问。完整 macOS27 CPU/VMM/VZ 仍未完成。
