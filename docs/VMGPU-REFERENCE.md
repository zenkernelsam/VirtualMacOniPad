# VMGPU：作者原版 payload 快照（重建忠实性的"黄金基线"）

> 位置：`~/Desktop/VirtualMacOniPad/VMGPU/`（原在桌面，2026-09 移入本仓库根目录）
> 清单（已入库）：`docs/VMGPU-cdhash.tsv`（每文件的 size / UUID / CDHash）
> 规模：**181 个文件 / 86 个 Mach-O / 170.7 MB**
> 归属策略：**二进制本体不入 Git**（仓库政策：Apple 二进制/签名产物不提交）；**入库的只有本说明 + CDHash 清单**。

---

## 1. 这是什么 / 从哪来

- **是什么**：**官方 1.2.3(607) 版随包 payload 的完整快照** —— 即 iPad 实机上"能正常跑"的那份运行时。
- **从哪来**：从 iPad 的 `/var/root/VirtualMac/payload/` 整份拷出（含 `Frameworks/`、`Compatibility/`、`Installation.xpc`、`VirtualMachine.xpc`）。
- **组成**：
  | 顶层 | 大小 | 内容 |
  |---|---|---|
  | `Frameworks/` | 61 M | Virtualization / ParavirtualizedGraphics / MetalSerializer / Hypervisor / VideoToolbox(+ParavirtualizationSupport) / DiskImages2 / vmnet / Netrb + 兼容 dylib（MetalCompat / IOKit15Compat / LibSystem15Compat / LibCxx / LaunchServicesCompat(+`.ipados14`)） |
  | `Compatibility/` | 28 M | `iPadOS14/`、`iPadOS15/`、`iPadOS15Authenticated/` |
  | `Installation.xpc/` | 74 M | 安装器 XPC |
  | `VirtualMachine.xpc/` | 7.4 M | VMM XPC |

**不要修改它**：它是"参照物"，只读使用。

---

## 2. 为什么它是"好东西"（四个用途）

1. **重建忠实性的判据**：本项目 `build-frameworks → build-ipad-vm` 的重建产物**必须与它逐字节一致**（历史教训：不加 a2sb 缓存重建出的框架"不忠实"，会导致 **App 点启动即闪退**）。
2. **`__text` 逐字节比对**（最可靠的验证方式，见 §3）。
3. **CDHash / trustcache 核对**：用 `docs/VMGPU-cdhash.tsv` 比对"打包 trustcache 里的 CDHash"是否与二进制实际 CDHash 一致。
4. **A/B 归因**：崩溃/异常时，用它判断"是我们的**改动**引入的"还是"**重建过程**引入的"。

---

## 3. 怎么用（可直接复制的命令）

### 3.1 重建忠实性：`__text` 逐字节比对（推荐）
```bash
/usr/bin/python3 - <<'PY'
import subprocess
def code(p):
    out=subprocess.run(["otool","-l",p],capture_output=True,text=True).stdout.splitlines()
    off=sz=None
    for i,l in enumerate(out):
        if "sectname __text" in l:
            for j in range(i,i+12):
                s=out[j].strip()
                if s.startswith("offset"): off=int(s.split()[1],0)
                if s.startswith("size"):   sz=int(s.split()[1],0)
            break
    if off is None: return None
    d=open(p,'rb').read(); return d[off:off+sz]

BASE="/Users/ciscohe/Desktop/VirtualMacOniPad/VMGPU"          # 黄金基线
NEW="/Users/ciscohe/Desktop/VirtualMacOniPad/VirtualMac/build/ipad-vm/payload"  # 本次重建
for rel in ["Frameworks/Virtualization.framework/Versions/A/Virtualization",
            "Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics",
            "Frameworks/MetalSerializer.framework/Versions/A/MetalSerializer",
            "Frameworks/Hypervisor.framework/Versions/A/Hypervisor"]:
    print(rel.split("/")[1], "identical:", code(f"{BASE}/{rel}")==code(f"{NEW}/{rel}"))
PY
```

### 3.2 PG UUID 必须一致（快速自检）
```bash
/usr/bin/dwarfdump --uuid "$HOME/Desktop/VirtualMacOniPad/VMGPU/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
# 期望：732073AB-34E5-38C9-A919-53B628977BDB (arm64e)
```

### 3.3 CDHash 核对（与打包 trustcache 对照）
```bash
/opt/homebrew/bin/ldid -h VMGPU/Frameworks/LaunchServicesCompat.dylib | grep CDHash
grep LaunchServicesCompat docs/VMGPU-cdhash.tsv          # 基线值
# 再与包内 var/jb/usr/share/VirtualMac/trustcache.txt 的对应条目比较
```

---

## 4. Git 政策与"丢了怎么办"

- **不提交二进制**：`VMGPU/` 已在 `.gitignore` 中（与 `payload/` 同政策：Apple 二进制/签名产物不入 Git）。**入库的是** `docs/VMGPU-REFERENCE.md` + `docs/VMGPU-cdhash.tsv`。
- **若本机丢失**，两条恢复路径：
  1. 从 **iPad 实机**重新拷 `/var/root/VirtualMac/payload/`（需装官方 1.2.3）；
  2. 从**作者发布的 deb** 解包提取（`dpkg-deb -x`）。
- 恢复后请用 `docs/VMGPU-cdhash.tsv` 校验一致性（CDHash 应与表中一致，除非作者发了新版本）。
