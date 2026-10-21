# X86-MIGRATION.md — 迁移到 x86 黑苹果说明

> 打包日期：2026-10-21。打包方式：`gtar | zstd`，排除了宿主 arm64-only 工具与可重下的 IPSW 大文件。
> 本文档同时被复制到压缩包旁边（飞牛 VirtualMacOniPad_iOS），在 x86 上先读本文件再动手。

## 1. 压缩包排除项（及原因）

| 排除路径 | 大小 | 原因 |
|---|---|---|
| `VirtualMac/build/downloads/` | ~30GB | 4 个可重下的 IPSW/DMG（见 §2 清单） |
| `VirtualMac/build/toolchain/bin/` | ~200MB | `ipsw`、`ipsw-a2sb` 均为 **Mach-O arm64**，x86 无法运行 |
| `VirtualMac/build/toolchain/venv/` | ~36MB | Python 3.14 venv，内部全部 arm64 + 绝对路径绑定，跨机必重建 |
| `**/.DS_Store` | — | Finder 垃圾文件 |

> 注意：`toolchain/ipsw-src/`（blacktop/ipsw 源码 + 本地 a2sb 命令）**已保留**；`VirtualMac/build/inputs/`（2.2GB 已提取的 dyld cache/框架）也保留，不必重新提取。

## 2. x86 上需要重新下载的资源

落地路径统一为 `VirtualMac/build/downloads/`。带 ✅ 的 SHA256 来自 `setup.sh` 官方清单；13.4.1 的 SHA256 为本次打包实测。

| 文件 | 大小 | SHA256 | 来源 |
|---|---|---|---|
| `UniversalMac_13.4.1_22F82_Restore.ipsw` | 12GB | `5ac144d1661614806d765bc0466d719152e2594c2db3888f1ac02276f5638e98` | ipsw.me / appledb.dev 搜 22F82 → Apple CDN |
| `UniversalMac_11.6_20G165_Restore.ipsw` | 13GB | `9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6` ✅ | `https://updates.cdn-apple.com/2021FallFCS/fullrestores/071-97388/C361BF5E-0E01-47E5-8D30-5990BC3C9E29/UniversalMac_11.6_20G165_Restore.ipsw` |
| `iPad_Spring_2021_14.5_18E199_Restore.ipsw` | 4.9GB | `11023b65bc2f08eabbb141fa494873d41a1d4a43fca09904480d8e55e8065dc4` ✅ | `https://updates.cdn-apple.com/2021SpringFCS/fullrestores/071-17692/4BB409F6-D860-416B-A0EF-BDC941C74F3E/iPad_Spring_2021_14.5_18E199_Restore.ipsw` |
| `DeviceSupport_macOS_27_beta.dmg` | 15MB | `d02e14429a02a78d8bf9d84df8ae55f5a03f2a00dbf58767f451b68eda417ca1` ✅ | `https://github.com/nfzerox/DeviceSupportMirror/releases/download/1.0/DeviceSupport_macOS_27_beta.dmg` |

按需（仅 `--full-ipados-audit` 或重新提取 inputs 时才要）：

| 文件 | SHA256 | 来源 |
|---|---|---|
| `UniversalMac_13.2.1_22D68_Restore.ipsw` ✅ | `0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04` | `https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-48346/EFF99C1E-C408-4E7A-A448-12E1468AF06C/UniversalMac_13.2.1_22D68_Restore.ipsw`（注意：build/inputs 已含其提取件，日常构建未必需要） |
| `iPad14,3,iPad14,4,iPad14,5,iPad14,6_16.3.1_20D67_Restore.ipsw` | `a4d922f3fdc960fd5714b5d46c13b928c1249e072cb93301bd1f7bb66ec29cc0` | `https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-50028/ACF197BE-D22C-49EC-94C5-C1B58D7708AC/iPad14,3,iPad14,4,iPad14,5,iPad14,6_16.3.1_20D67_Restore.ipsw` |
| `iPad_Pro_Spring_2021_15.0_19A346_Restore.ipsw` | `f678d0c061c1dd8a3afdf4a3aee12123b95c47607a2fe5a8accc4b608ccf7344` | `https://updates.cdn-apple.com/2021FallFCS/fullrestores/002-02897/6B63FC96-3F0A-4DC4-B065-BFA88F2EF7AF/iPad_Pro_Spring_2021_15.0_19A346_Restore.ipsw` |

校验：`shasum -a 256 <file>` 对比上表；不符即重下。

## 3. x86 上需要重建/重装的宿主工具

```bash
# 1) 解压（需 zstd；Intel brew 前缀为 /usr/local）
brew install zstd gnu-tar   # 如尚未装
gtar -xf VirtualMacOniPad-x86-migration-20261021.tar.zst
cd VirtualMacOniPad/VirtualMac

# 2) 依赖（Brewfile：go dpkg ldid-procursus sshpass aria2 gnu-tar libimobiledevice python rsync）
brew bundle --file=Brewfile

# 3) 一键重建 toolchain：venv+dyldextractor 补丁+ipsw-a2sb 全自动（bootstrap.sh 已处理）
./scripts/bootstrap.sh
```

`bootstrap.sh` 在 x86 上会做的事（无需手工）：建 `toolchain/venv` → `pip install -r requirements.lock.txt` → 给 dyldextractor 打 `patches/dyldextractor-2.2.2-arm64e.patch` → `ipsw-src` fetch+checkout `b7229017` → 装 `vz/ipsw_patches/dyld_a2sb.go` → `CGO_ENABLED=1 go build` 出 **amd64** 的 `bin/ipsw-a2sb`。`ipsw-src` 已随包带走，fetch 只需拉小对象。

其他按需：

- **Xcode + CLT**：交叉编译 iOS arm64/arm64e 产物不受宿主架构影响，照常。
- **`ipsw`（上游全功能版）**：`brew install ipsw` 或 GitHub blacktop/ipsw 的 darwin_amd64 release；日常只用 `ipsw-a2sb` 时可不装。
- **`toolchain/Dopamine-src`**：仅 `scripts/development/probe-ipad-amfi-entitlement.sh` 用，`git clone https://github.com/opa334/Dopamine` 到该路径。
- **IDA Pro**：需 x86 版（ida-pro-mcp 在 x86 上同理重装插件）。
- **mtl-caps-dump 探针**：`vz/development/probes/` 下 3 个未跟踪二进制是 arm64/arm64e **目标产物**（跑在客机/iPad，不跑在宿主），已保留在包内；要重编用源码 `mtl-caps-dump.m`。

## 4. 包内仍是 arm64 的内容（正常，非遗漏）

- 全部 iPadOS/客机目标产物：`.deb`、payload 框架、probes —— 项目产物本来就是 arm64。
- `.diag/` 与 `build/inputs/` 里的 arm64e Apple 二进制 = 取证证据/分析对象。
- `VMGPU/` 黄金基线（Apple 官方 payload，只读）。

## 5. 环境差异备忘

- x86 黑苹果**没有 Rosetta**：任何漏网的 arm64-only 宿主二进制会直接跑不动——§1 已清掉已知的两个；若再遇到 `Bad CPU type`，`file <路径>` 确认后重编。
- brew 前缀从 `/opt/homebrew` 变为 `/usr/local`；venv 的 `pyvenv.cfg` 指向 `/opt/homebrew/opt/python@3.14`，这正是必须重建 venv 的原因之一。
- iPad 侧操作不变（SSH `192.168.64.1:2222`、ldid 签名、`/var/jb` 前缀），只要求 x86 机能产出 arm64 产物——Xcode/clang/ldid/go 均可。
