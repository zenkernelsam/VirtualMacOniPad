# 独立 ADI 依赖

来源：apple-auth/apple-auth v0.1.3，commit `98c862f7bebc8283a9b87f1578e703f0765dc81d`。
本目录保留群友 20261111.2 备份中的完整 SDK 源码、许可、第三方声明和对应 macOS 静态依赖。

`prebuilt/macos-arm64_x86_64/libapple_auth.a` SHA256：
`69ee8eb959aabaf5b4444fc57958d98d037ff2897f8684c1c034186d9f7bddca`。
构建脚本核验该指纹；此归档的源码独立重建需源码 CMake 中声明的依赖。
当前项目在其上编译自己的 native provider，账号修复不再依赖 Python 或未公开的设备路由插件。

只调用 account-free ADI 初始化及 OTP 接口。SDK 中存在的媒体登录/下载 API 不代表系统 App Store、Music、TV 登录成功。
用户 identity、ADI、密码、2FA、账户 session 均不在本目录，也不打入安装包。
