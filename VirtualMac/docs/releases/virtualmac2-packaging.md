# Virtual Mac 2 独立 deb 打包与安装

`2.0.0beta1` 使用 `CFBundleShortVersionString=2.0.0beta1`、
`CFBundleVersion=1001` 和 Debian `Version: 1001`。产物名为
`VirtualMac_2.0.0beta1_1001.deb`，包名及 App 标识均为
`com.mac.virtual.v2`。各语言的主屏幕名称会附加发行版本，便于与原版区分。

目前运行组合是 macOS 27 的 PVG、MetalSerializer、GPU task 与私有着色器编译器，
配合已验证的 Ventura CPU、VMM 和 Virtualization。完整 macOS 27 CPU/VMM/VZ
移植仍在开发中。本发行版面向已经测试的 rootless iPadOS 16 越狱环境。

## 与原版并存

保留并安装 Virtual Mac 1.2.3。新包依赖 `com.mac.virtual (>= 1.2.3)`，共享原版的
安装及网络辅助组件；新包只拥有 `/var/jb/Applications/VirtualMac2.app` 与
`/var/root/VirtualMac2` 下自身的发行文件。新包不会替换原版 App，也不会重启共享
网络服务、终止虚拟机或修改 `/System`、系统 `/usr` 中的文件。

安装、升级和卸载前，正常关闭全部虚拟机并退出 Virtual Mac 2。维护脚本检测到
仍在运行的 VMM、安装任务、GPU task、私有编译 worker 或新 App 时会拒绝操作。
在 iPad 的越狱终端中，以 root 运行：

```sh
dpkg -i /tmp/VirtualMac_2.0.0beta1_1001.deb
```

卸载新包时使用 `dpkg -r com.mac.virtual.v2`。虚拟机目录
`/var/mobile/Media/VirtualMac/*.bundle`、备份、设备专属编译器身份收据以及既有
转换缓存会保留。新包不会清理其他测试 App；每个测试版本应按其实际安装来源
单独卸载，避免误删虚拟磁盘。

## 在 Mac 上打包已核验的运行组合

`scripts/development/build-virtualmac2-deb.py` 接受完整运行目录与已核验的二进制。
不要将 VM 磁盘、用户诊断日志或整棵开发候选目录传入。下面路径均指向对应的
独立输入目录。在仓库的 `VirtualMac` 目录中执行：

```sh
python3 scripts/development/build-virtualmac2-deb.py \
  --runtime-payload /absolute/path/reviewed/payload \
  --app /absolute/path/reviewed/VirtualMac2.app \
  --compiler-runtime /absolute/path/reviewed/compiler-runtime \
  --shader-cache /absolute/path/reviewed/air25 \
  --probes /absolute/path/reviewed/probes \
  --release-version 2.0.0beta1 --build-number 1001 \
  --output /absolute/path/fresh-release
```

需要 Python 3、Xcode 的 `codesign`/`dyld_info`、`plutil` 与 `dpkg-deb`。
输入目录不会被改写。App 在 `/private/tmp` 的无扩展属性副本中更新版本并重新
密封；程序 UUID、所有文件支持的代码 section 和原有权限声明必须保持一致。
打包器不会重签已有运行框架。全部 Mach-O 的 CodeDirectory 页、内嵌权限及要求
哈希都必须通过，并逐项核对 CDHash 与 dyld 结构。旧 `ldid` 签名在 Mac 的
严格策略下可能被拒绝；这种差异记录于清单，不能等同于整个旧框架 bundle 的
资源密封已通过。新的 App、编译器及测试工具仍要求严格签名验证通过。

输出包含 deb、`SHA256SUMS`、`release-manifest.json` 与 `release-code-pins.json`。
清单只使用目标安装路径，列出文件 SHA256、CDHash 和验证结果；不包含 Mac 的
私有工作目录。数据归档仅含新包拥有的两个目录，不写入 `/var/root` 或 `/var/jb`
等既有父目录的权限元数据。框架的相对符号链接必须保持在其已核验目录中。

## 保留已有编译缓存

七个私有编译器部件放在新包的 `package-source` 中。安装脚本逐项核对 SHA256，
当目标文件的字节、owner、mode 和独立文件属性完全相同时不改写文件。因此，
已有设备收据绑定的 inode 与纳秒级 stat 数据可以保留。文件不匹配时才使用原子
替换。编译器代码归 root；只有 `compiler27/work` 与静态 AIR 缓存由 mobile 写入。

发行包不会附带某台 iPad 的 `persistent-cache-identity-v1.json`，也不会覆盖已存
收据或 `converter-cache-v1`。新设备缺少匹配收据时自动沿用普通编译路径；可选
持久缓存的重新建立需按
[编译缓存说明](../../scripts/development/README-persistent-converter-cache.md)
收集并核验该设备自身的身份信息。
