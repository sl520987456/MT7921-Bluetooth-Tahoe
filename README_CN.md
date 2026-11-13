<div align="right">

[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md) [![简体中文](https://img.shields.io/badge/lang-简体中文-CB171E.svg)](README_CN.md)

</div>

# MT7921 蓝牙 · macOS Tahoe (26.x) 原生驱动方案

**让 Foxconn MT7921 蓝牙（`0489:E0CD`）在 macOS Tahoe 上被原生 `bluetoothd` 的 MediaTek SRS 蓝牙栈完整接管——无需 `/etc/bluetool` 固件文件。**

本项目是 [laobamac/SimpleMtkBtFw](https://github.com/laobamac/SimpleMtkBtFw) 的修复增强版，已在 **macOS Tahoe 26.7**（x86_64 黑苹果）端到端验证。据我们所知，这是 `0489:E0CD` 这个设备 ID 的**首个**公开完整方案——它不在苹果官方支持表里。

```
Bluetooth Controller:
    Address: 4C:D5:77:0A:65:9C        ← 真实地址（之前一直是 NULL）
    State: On
    Chipset: SRS_7922
    Transport: USB
    Firmware Version: HCI Revision:2515, LMP Subrevision:2506
```

## 为什么大家都卡在这一步

Monterey 起（含 Tahoe），macOS **没有内核态 USB 蓝牙驱动**，USB 蓝牙完全由用户态守护进程 `bluetoothd` 接管，它二进制里有一张**硬编码支持表**。Tahoe 26.x 的表里只有 7 个 USB ID：

| VID | PID | 芯片 |
|-----|------|------|
| 0x0489 (Foxconn) | E0D8, E0E0, E0F1, E0F2, E0F6 | MT7921 / MT7922 |
| 0x0E8D (MediaTek) | 7922 | MT7922 |
| 0x13D3 (AzureWave) | 3568 | MT7922 |

我们的 `0489:E0CD` **不在表里**，`bluetoothd` 看都不看——即使内核 kext 已把固件刷好也没用。这正是 [laobamac 仓库 issue](https://github.com/laobamac/SimpleMtkBtFw/issues) 和 [tonymacx86 MediaTek 帖子](https://www.tonymacx86.com/threads/wifi-6-e-bluetooth-5-x-mediatek-chipset-on-native-sequoia-tahoe.332855/)（Elias64Fr 逆向、CaseySJ 在 26.3 验证 MT7922）里全网卡住的同一堵墙。

## 本项目的解法

两个 kext、三层架构：

```
┌─────────────────────────────────────────────────────────────────┐
│  第 3 层   bluetoothd（用户态）                                  │
│            SRS 模式认领设备，苹果原生蓝牙栈全量接管                │
├─────────────────────────────────────────────────────────────────┤
│  第 2 层   SimpleMtkBtPatcher.kext（Lilu 插件，本 fork 增强）     │
│            • 路由内核 _cs_validate_page                          │
│            • 运行时改 /usr/sbin/bluetoothd 支持表                │
│              （E0F1 → E0CD，等长字节替换）                        │
│            • 把 bluetoothd 和 /usr/sbin/BlueTool 的              │
│              固件跳过检查路径改指向 boot.efi                      │
│            • （保留）HCI 请求钩子：随机地址修复                    │
├─────────────────────────────────────────────────────────────────┤
│  第 1 层   SimpleMtkBtFw.kext（修复版构建）                       │
│            枚举时匹配 0489:E0CD，内核态把 BT_RAM_CODE_MT7961      │
│            固件写入芯片，然后把设备交出去                          │
└─────────────────────────────────────────────────────────────────┘
```

第 1 层固件已内嵌（Linux 固件镜像），第 2 层让 `bluetoothd`/`BlueTool` 跳过自己的固件下载——所以**完全不需要 `/etc/bluetool`**（反正密封系统卷上也创建不了）。

### 修复 1 —— 手搓 kext 的启动挂死

不用完整 Xcode 手搓 kext 的同学，若胶水代码调用 `OSRuntimeInitializeCPP` 会**开机挂死**：新版 xnu 里该符号签名已改为 `OSRuntimeInitializeCPP(OSKext*)`（单参数），且内核本来就会自动执行 `__mod_init_func` 的 C++ 构造函数。拿 `kmod_info_t*` 当 `OSKext*` 传进去，内核解引用假指针，kext start 阶段直接冻结。

本仓库的 [`kmod-info.cpp`](kmod-info.cpp) 是修正版胶水：

- `start` 只调 `_realmain`（Lilu 插件用 `KEXT_START_SYM` 接到 `PRODUCT_kern_start`）
- `stop` 直接返回成功
- 绝不手动调用 C++ 构造

两个构建脚本都会在链接后自动核验 `mod_start`/`mod_stop`（Patcher 还核验 Lilu `kern_start` 入口符号），从根上杜绝"哑巴插件/NULL start"两类翻车。

### 修复 2 —— bluetoothd 白名单注入

本 fork 的 `SimpleMtkBtPatcher.cpp` 增加了 `_cs_validate_page` 路由（机制同 acidanthera [BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM) 的 BlueToolFixup）：内核校验 `bluetoothd` 页面时，找到 20 字节 Foxconn 表（`89 04 D8 E0 | 89 04 E0 E0 | 89 04 F1 E0 | 89 04 F2 E0 | 89 04 F6 E0`），原地把 `E0F1` 换成 `E0CD`。等长替换、不动其他条目。同时把两处固件跳过检查字符串换成 `/System/Library/CoreServices/boot.efi`，`bluetoothd`/`BlueTool` 就永远不会尝试自己下载固件。

**无需任何 boot-arg**；只要字节模式匹配，Tahoe 26.x 上自动生效（对 26.7 的 `bluetoothd` 逐字节验证过；表结构与 Elias64Fr 公开的 26.0–26.2 反汇编一致）。

## 构建

要求：macOS + Xcode **Command Line Tools**（无需完整 Xcode）、`git`、`python3`。

```bash
# 1. 固件放进 ./firmwares/
#    例如 BT_RAM_CODE_MT7961_1_2_hdr.bin
#    来源：laobamac/SimpleMtkBtFw releases、linux-firmware、或 Windows 驱动包
mkdir -p firmwares && cp /path/to/BT_RAM_CODE_MT7961_1_2_hdr.bin firmwares/

# 2. 编两个 kext（Lilu/MacKernelSDK 自动克隆）
./build-bt.sh
./build-btpatcher.sh

# 3. 产物
#    build/SimpleMtkBtFw.kext
#    build-patcher/SimpleMtkBtPatcher.kext
```

`tools/make_firmware_cpp.py` 把 `.bin` 固件 zlib 压缩后嵌入生成 `FwBinary.cpp`（生成文件不入 git）。可以传多个 `.bin` 生成多固件条目表，和上游一致。

## 安装（OpenCore）

1. 两个 `.kext` 拷到 `EFI/OC/Kexts/`
2. `config.plist` → `Kernel → Add`，**按此顺序**：
   1. `Lilu.kext`
   2. `SimpleMtkBtFw.kext`（启用）
   3. `SimpleMtkBtPatcher.kext`（启用）
3. 不需要特殊 boot-arg；NVRAM `bluetoothExternalDongleFailed` 和 `bluetoothInternalControllerInfo` 保持**全零**
4. **冷启动**（彻底关机等 10 秒再开机）

开机后验证：

```bash
system_profiler SPBluetoothDataType   # 期望 Chipset: SRS_7922、Transport: USB、真实 Address
```

`bluetoothd` 日志里应能看到：

```
bluetoothd: [bm3_usb][GetProductAndVendorID] -- Found external Bluetooth dongle --
            vendorID = 0x0489, produceID = 0xE0CD
```

## 兼容性与注意事项

- **实测环境**：MT7921（Foxconn `0489:E0CD`，WiFi 芯片 `14C3:7961`）、macOS Tahoe **26.7**、x86_64
- 表补丁是纯数据替换，Tahoe 26.0–26.7 应该都适用；将来苹果改了表，补丁自动不生效（不会崩），需更新模式
- `E0F1 → E0CD` 会顶掉一个原生条目（真实 MT7922 设备 ID）。如果你手里真有 `0489:E0F1` 的设备，改 `SimpleMtkBtPatcher.cpp` 里 `kMtkIdTablePatched` 换个槽位即可
- MT7922（`0489:E0E0` 等）用户：你的 ID 原生支持，走 tonymacx86 帖子的固件文件路线即可，不需要表补丁
- WiFi 是另一个驱动：见 [laobamac/SimpleMtkWlan](https://github.com/laobamac/SimpleMtkWlan)（PCIe `14C3:7961`）
- 测试期间建议备一个 U 盘救急 EFI，`-v` 开着方便定位

## 排错速查

| 症状 | 原因 / 处理 |
|---|---|
| verbose 启动中途挂死（常在 ACPI AML 行后） | kext 胶水 bug——千万别自己调 `OSRuntimeInitializeCPP`，用本仓库 `kmod-info.cpp` |
| 蓝牙菜单灰 / `Address: NULL` | 查 `bluetoothd` 是否接受了 ID（见上面日志行）；查表补丁是否生效；查 NVRAM 变量全零 |
| `bluetoothd` 崩溃重启循环 | 固件状态不一致——冷启动；确认 Fw 日志有 "MediaTek device setup complete" |
| 设备根本不可见 | USB 定制问题：确认 BT 设备（VID `0489`）已在 IOUSBHostFamily 下枚举 |

## 致谢

- **laobamac** — 原版 [SimpleMtkBtFw](https://github.com/laobamac/SimpleMtkBtFw) / SimpleMtkBtPatcher
- **zxystd** — IntelBluetoothFirmware 一脉与 deviceRequest 钩子技术
- **acidanthera** — [Lilu](https://github.com/acidanthera/Lilu)、[BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM)（BlueToolFixup 的 `_cs_validate_page` 机制）
- **Elias64Fr** — Tahoe `bluetoothd` MediaTek 支持表逆向（tonymacx86）
- **CaseySJ** — Tahoe 26.3 实测验证（MT7922）

## 许可证

GPL-3.0，与上游一致。见 [LICENSE](LICENSE)。
