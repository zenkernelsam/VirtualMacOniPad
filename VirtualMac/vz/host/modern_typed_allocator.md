# 应用私有的 typed allocator 兼容实现

`modern_typed_allocator_compat.c` 使用真实旧版 libSystem 分配函数。
`modern_typed_allocator.h` 保存 SDK 的 LP64 参数顺序：zone 接口第四参数为
64 位 type_id，第五参数为64位 options。编译时禁止自动 typed-memory 改写，
避免包装器再次调用自身。

开发脚本 `scripts/development/build-modern-typed-allocator.py --output <新目录>`
默认只编译两项增量入口：malloc_type_posix_memalign、
malloc_type_zone_malloc_with_options。它只构建和签名，不部署、添加信任哈希或
全局替换系统 allocator。三项 malloc/calloc/realloc 原始 fallback 由
VZ_TYPED_ALLOCATOR_INCREMENTAL_ONLY 控制。增加 `--all-five` 可以构建
VM27AllocatorProvider.dylib，同时导出这三项接口；默认两接口构建参数保持原样。

来源为 Apple libmalloc812.100.31 的公开提交
c49dafa25f1efe8607701ae6014a663ad2ee437f，以及 SDK27.1 的公开 allocator 声明和
backdeployment 分支。具体源码区间、逐文件 SHA、原始版权声明和 APSL-2.0
保存在 `vendor/libmalloc-typed-backport`。适配代码保留已冻结实现的完整正文，
仅增加来源和修改日期说明。

实机证据：2026-10-04 iPad PID72688，原两入口库执行25例、137项检查通过；
20次分配由真实 owner 全部释放，25例请求总计1897B，单例至多256B。
验证了默认/自有zone、合法对齐、CLEAR、实际非标签指针、原生错误、零尺寸观察
及自有内容 SHA。输入和输出前后均校验文件和运行时身份，实际完整映像头部
及加载命令参与 census，只有准确旧 stock Swift 被允许。

新项目构建已完成4个文件承载段的字节比对，均与原实测库完全一致；
其中 __text SHA 为 e8f36d4294caf79f3d5c1944f9bf7708c4b4355a3ef80efc5249c11afa71bd67。
新文件的 install name、SDK stamp、UUID 和签名标识不同，尚未部署或执行。未知 options 的 trap、MTE/TSD、typed分配遥测与隔离未在此次
iPad测试中覆盖。descriptor 按官方旧系统 fallback 忽略，不能宣称完整现代
allocator、Swift27、Virtualization27、Apple8 或 EVE 兼容。

五接口项目构建于2026-10-04完成，50528B，SHA
d037098b9c45882d54fba0cafb12d7e7c1d1d94fe46831389e1a370879e72503。
与独立冻结的五接口测试库相比，签名之外全部字节相同；两者代码签名身份不同。
独立冻结库的三接口原生测试已通过：PID72936、直接 wait0，6真实调用、31项检查，
3个自有缓冲区全部释放；真实calloc清零/溢出errno和realloc扩缩容prefix SHA正确。
stdout SHA为5c376b9f5e8953fe425de80bbd4a67e520ea976ce892ec9ed4dcc286be353365。
该五接口整文件只实测这三个新增接口，另外两项的25例证据来自此前两接口文件。
新项目签名身份不同的整文件尚未部署、加入 trustcache 或运行。构建记录保存在 DeviceDiagnostics 的
modern-allocator-provider-project-build-v1，不能把字节相等记作整文件原生通过。
