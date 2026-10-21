# macOS 27 CPU 运行库兼容接口

`modern_cpu_runtime_compat.cpp` 独立实现八个缺失导出。`scripts/development/build-modern-cpu-runtime.py` 构建独立的 iOS arm64e ABI0 与 macOS 对照库，要求使用一个尚不存在的输出目录。它不替换原 `ModernRuntimeCompat`，不修改 iPadOS 或生产包。

```sh
python3 VirtualMac/scripts/development/build-modern-cpu-runtime.py /private/tmp/virtualmac-cpu-runtime-new-build
```

接口范围：

- `malloc_type_calloc`：按 SDK 的旧系统回退路径调用真实 `calloc`，保留溢出拒绝、零初始化与释放语义；旧分配器不记录新增的类型描述元数据。
- `std::__1::__hash_memory`：使用 SDK 的 CityHash/Murmur2 模板。
- `bad_expected_access<void>::what` 与 RTTI：使用真实 SDK 类和系统 C++ 异常 ABI。
- 原子 monitor、wait、notify-all：同一库内的真实互斥锁、序列与条件变量；三个接口必须一起绑定到同一库，避免混用等待表。
- `exception_ptr::__from_native_exception_pointer`：调用真实 `libc++abi` 的异常引用计数；不复制异常头或伪造异常对象。

实现依据 LLVM 提交 `65a82906cff9c7a7a33844812d35ce159d88a354` 和实际 SDK27.1 类定义，遵循 Apache-2.0 WITH LLVM-exception。原始源码、SDK 摘录及来源清单保存在 `DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-runtime-extension-native-v1/source-attribution.json`；独立异常工厂的原始文件保存在 `modern-exception-pointer-compat-v1/upstream-exception-pointer.ipp`。

2026-10-04，合并后的库在 iPadOS16.1.1/M2 上通过 404 次分配、哈希、异常、线程检查和 134 次异常引用生命周期检查。测试使用真实分配、真实 pthread 阻塞/唤醒、实际异常重抛和最终析构；所有八个定义均验证实际所属库及 RVA。原生记录位于 `modern-cpu-runtime-integrated-native-actual-v1`。

越狱环境自动加载了四个既有库，记录中保留这个隔离限制。上述结果仅证明这八个接口的独立功能，不证明 macOS27 VMM/VZ 的调用点、完整强导入闭包或整个虚拟化栈已兼容。生产包的 19 个代码文件和四项元数据保持原字节；完整 CPU/VMM/Swift/DiskImages2 仍在移植。


后续强导入验证：2026-10-04 的 `modern-cpu-provider-strong-native-actual-v3` 在真实 M2/iPadOS16.1.1 上又通过 411+135=546 项检查。探针的原始 chained-import 记录均为非 weak、普通正库编号；其中七项绑定 `VM27CxxProvider`，calloc 绑定 `VM27AllocatorProvider`。每个实际函数地址又与同一 CPU 实现库的固定 UUID、RVA、完整文件哈希匹配。功能执行来自强导入的指针，`dlsym` 仅用于独立身份对照。工厂探针没有枚举全部加载图像，不为它声称完全隔离。

`build-modern-cpu-providers.py RUNTIME_DIRECTORY NEW_OUTPUT_DIRECTORY` 可生成这些应用私有转发库。C++ 库明确重导出七项并转发原生 libc++；分配器库明确重导出 calloc 并转发原生 libsystem_malloc。构建侧仅声明原生依赖的路径身份，避免 SDK27 误称老系统拥有新接口；这个 `.tbd` 文件没有函数、变量或运行时代码。不能把分配器转发库直接替换整个 libSystem 的依赖，因为它只覆盖分配器范围。三个原子接口继续共用同一 CPU 库中的真实等待表。

`prepare-modern-cpu-imports.py PINNED_ORIGINAL_VMM NEW_OUTPUT_DIRECTORY` 目前只支持已核实的 macOS27 原始 VMM SHA。它把真实 chained table 中的五个对应导入分别导向新增私有依赖，保留原 libc++/libSystem 的依赖与所有其它导入；同步对应 nlist 库编号，并移除旧签名。实际离线候选仅改 84 字节，全部代码节/文件承载节保持相同，1,203 个导入及 1,064 个强导入数量、weak 标记和 addend 均不变，dyld 静态校验通过。它仍是 macOS27 平台的未签名候选，未移植或在 iPad 执行；不要部署到生产。VZ 的 nlist 记录不足以确认真实 fixup，工具拒绝用符号元数据替代运行时绑定。
