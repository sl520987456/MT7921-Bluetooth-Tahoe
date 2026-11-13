# MT7921 Bluetooth on macOS Tahoe (26.x)

**Enable Foxconn MT7921 Bluetooth (`0489:E0CD`) on macOS Tahoe via the native `bluetoothd` MediaTek SRS stack — no `/etc/bluetool` firmware files needed.**

This is a fixed & enhanced fork of [laobamac/SimpleMtkBtFw](https://github.com/laobamac/SimpleMtkBtFw), verified working end-to-end on **macOS Tahoe 26.7** (x86_64 hackintosh). To our knowledge this is the first public, fully documented setup for the `0489:E0CD` device ID, which is **not** in Apple's built-in supported-device table.

```
Bluetooth Controller:
    Address: 4C:D5:77:0A:65:9C        <- real address (NULL before)
    State: On
    Chipset: SRS_7922
    Transport: USB
    Firmware Version: HCI Revision:2515, LMP Subrevision:2506
```

## Why most people are stuck

On Monterey+ (including Tahoe), macOS has **no kernel-side USB Bluetooth driver**. USB Bluetooth is claimed entirely by the user-space daemon `bluetoothd`, which maintains a **hard-coded supported-device table** inside its binary. On Tahoe 26.x that table contains exactly 7 USB IDs:

| VID | PID | Chip |
|-----|------|------|
| 0x0489 (Foxconn) | E0D8, E0E0, E0F1, E0F2, E0F6 | MT7921 / MT7922 |
| 0x0E8D (MediaTek) | 7922 | MT7922 |
| 0x13D3 (AzureWave) | 3568 | MT7922 |

Our device (`0489:E0CD`) is **not** in that table, so `bluetoothd` ignores it completely — even after the firmware is correctly uploaded by a kernel kext. This is the same wall described in the [laobamac issue tracker](https://github.com/laobamac/SimpleMtkBtFw/issues) and the [tonymacx86 MediaTek thread](https://www.tonymacx86.com/threads/wifi-6-e-bluetooth-5-x-mediatek-chipset-on-native-sequoia-tahoe.332855/) (discovered by Elias64Fr, validated on Tahoe 26.3 for MT7922 by CaseySJ).

## How this project solves it

Two kexts, three layers:

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3  bluetoothd (user space)                               │
│           claims the device in SRS mode, full native stack      │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2  SimpleMtkBtPatcher.kext (Lilu plugin, this fork)      │
│           • routes kernel _cs_validate_page                     │
│           • patches /usr/sbin/bluetoothd supported-device table │
│             (E0F1 → E0CD, equal-length byte swap)               │
│           • redirects firmware-boot skip checks in bluetoothd   │
│             and /usr/sbin/BlueTool to boot.efi                  │
│           • (legacy) HCI request hook for random address fix    │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1  SimpleMtkBtFw.kext (fixed build)                      │
│           matches 0489:E0CD at enumeration, uploads             │
│           BT_RAM_CODE_MT7961 firmware to the chip in kernel,    │
│           then hands the device over                            │
└─────────────────────────────────────────────────────────────────┘
```

Because Layer 1 already uploads firmware from the Linux firmware image embedded in the kext, and Layer 2 makes `bluetoothd`/`BlueTool` skip their own firmware download, **you do not need `/etc/bluetool` at all** (which is impossible to create on a sealed system volume anyway).

### Fix 1 — boot-hang glue for hand-built kexts

The upstream project must be built without full Xcode by many users; hand-rolled `kmod_info` glue that calls `OSRuntimeInitializeCPP` **hangs the machine at boot** on modern kernels: since recent xnu the symbol signature changed to `OSRuntimeInitializeCPP(OSKext*)` (single argument), and the kernel already runs `__mod_init_func` C++ constructors itself. Calling it with a `kmod_info_t*` pointer dereferences a fake OSKext and freezes during kext start.

This repo's [`kmod-info.cpp`](kmod-info.cpp) is a corrected glue:

- `start` only calls `_realmain` (Lilu plugins: wired to `PRODUCT_kern_start` via `KEXT_START_SYM`)
- `stop` returns success
- C++ constructors are never called manually

Both build scripts verify `mod_start`/`mod_stop` and (for the patcher) the Lilu `kern_start` entry symbol after linking, so a "silent dummy plugin" build failure can't happen again.

### Fix 2 — bluetoothd whitelist injection

`SimpleMtkBtPatcher.cpp` in this fork adds a `_cs_validate_page` route (same mechanism as acidanthera [BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM)'s BlueToolFixup): when the kernel validates `bluetoothd` pages, it finds the 20-byte Foxconn table (`89 04 D8 E0 | 89 04 E0 E0 | 89 04 F1 E0 | 89 04 F2 E0 | 89 04 F6 E0`) and swaps `E0F1 → E0CD` in place. Equal length, no other entries touched. It also replaces both firmware skip-check strings with `/System/Library/CoreServices/boot.efi` so `bluetoothd`/`BlueTool` never attempt their own firmware download.

No boot-argument is required; the patch applies on Tahoe 26.x whenever the byte pattern matches (verified against `bluetoothd` from 26.7; the table layout matches the disassembly published by Elias64Fr for 26.0–26.2).

## Building

Requirements: macOS with Xcode **Command Line Tools** only (no full Xcode), `git`, `python3`.

```bash
# 1. put firmware files into ./firmwares/
#    e.g. BT_RAM_CODE_MT7961_1_2_hdr.bin
#    from laobamac/SimpleMtkBtFw releases, linux-firmware, or Windows drivers
mkdir -p firmwares && cp /path/to/BT_RAM_CODE_MT7961_1_2_hdr.bin firmwares/

# 2. build both kexts (Lilu/MacKernelSDK are cloned automatically)
./build-bt.sh
./build-btpatcher.sh

# 3. products
#    build/SimpleMtkBtFw.kext
#    build-patcher/SimpleMtkBtPatcher.kext
```

`tools/make_firmware_cpp.py` zips the `.bin` firmware and embeds it as `FwBinary.cpp` (generated file, not tracked in git). You can list several `.bin` files to embed a multi-entry firmware table, exactly like upstream.

## Installing (OpenCore)

1. Copy both `.kext` bundles to `EFI/OC/Kexts/`.
2. Add to `config.plist` → `Kernel → Add`, **in this order**:
   1. `Lilu.kext`
   2. `SimpleMtkBtFw.kext` (Enabled)
   3. `SimpleMtkBtPatcher.kext` (Enabled)
3. No special boot-args needed. Keep NVRAM `bluetoothExternalDongleFailed` and `bluetoothInternalControllerInfo` **at all zeros**.
4. **Cold reboot** (full shutdown, wait ~10 s, power on).

Verification after boot:

```bash
system_profiler SPBluetoothDataType   # expect Chipset: SRS_7922, Transport: USB, real Address
```

`bluetoothd` log evidence to look for:

```
bluetoothd: [bm3_usb][GetProductAndVendorID] -- Found external Bluetooth dongle --
            vendorID = 0x0489, produceID = 0xE0CD
```

## Compatibility & notes

- **Tested**: MT7921 (Foxconn `0489:E0CD`, WiFi chip `14C3:7961`), macOS Tahoe **26.7**, x86_64.
- The table patch is data-only and should work across Tahoe 26.0–26.7 as long as the byte pattern matches; if a future macOS changes the table, the patcher simply does not apply (no crash), and you'll need a new pattern.
- The `E0F1 → E0CD` swap removes one *native* entry (a real MT7922 ID). If you also own an actual `0489:E0F1` device, patch a different slot instead — see `kMtkIdTablePatched` in `SimpleMtkBtPatcher.cpp`.
- MT7922 (`0489:E0E0` etc.) users: your ID is natively supported; you only need the firmware file route described in the tonymacx86 thread, no table patch required.
- WiFi is a separate driver: see [laobamac/SimpleMtkWlan](https://github.com/laobamac/SimpleMtkWlan) (PCIe `14C3:7961`).
- Keep a USB-stick rescue EFI. Verbose (`-v`) boot-arg is your friend while testing.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Boot hangs at verbose text (often right after ACPI AML lines) | Kext glue bug — never call `OSRuntimeInitializeCPP` yourself; use this repo's `kmod-info.cpp` |
| Bluetooth menu gray / `Address: NULL` | Check `bluetoothd` accepted the ID (see log line above); check table patch applied; check NVRAM vars are zero |
| `bluetoothd` crash-restart loop | Firmware state mismatch — cold reboot; verify Fw kext log shows "MediaTek device setup complete" |
| Device not visible at all | USB mapping issue: make sure the BT USB device (VID `0489`) enumerates under IOUSBHostFamily |

## Credits

- **laobamac** — original [SimpleMtkBtFw](https://github.com/laobamac/SimpleMtkBtFw) / SimpleMtkBtPatcher
- **zxystd** — IntelBluetoothFirmware lineage & deviceRequest hook technique
- **acidanthera** — [Lilu](https://github.com/acidanthera/Lilu), [BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM) (BlueToolFixup `_cs_validate_page` mechanism)
- **Elias64Fr** — reverse engineering of the Tahoe `bluetoothd` MediaTek supported-device table (tonymacx86)
- **CaseySJ** — validation on Tahoe 26.3 (MT7922)

## License

GPL-3.0, same as upstream. See [LICENSE](LICENSE).
