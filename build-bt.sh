#!/bin/bash
# build-bt.sh — build SimpleMtkBtFw.kext WITHOUT full Xcode (CommandLineTools only)
#
# Usage:  ./build-bt.sh
# Output: build/SimpleMtkBtFw.kext
#
# Requires: Xcode Command Line Tools (clang + Kernel.framework SDK), git, python3
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/SimpleMtkBtFw"
OUT="$ROOT/build"
FWBIN="$SRC/FwBinary.cpp"

# --- dependencies (auto-clone) ---
DEPS="$ROOT/.deps"
mkdir -p "$DEPS"
LILU="$DEPS/Lilu"
[ -d "$LILU/.git" ] || git clone --depth 1 https://github.com/acidanthera/Lilu.git "$LILU"

# --- firmware: generate FwBinary.cpp if missing ---
if [ ! -f "$FWBIN" ]; then
  echo "== FwBinary.cpp missing, generating =="
  FWDIR="$ROOT/firmwares"
  if [ ! -d "$FWDIR" ] || ! ls "$FWDIR"/*.bin >/dev/null 2>&1; then
    echo "ERROR: no firmware files found."
    echo "Download MT7921 bluetooth firmware (e.g. BT_RAM_CODE_MT7961_1_2_hdr.bin)"
    echo "into ./firmwares/ then re-run this script."
    echo "Sources: laobamac/SimpleMtkBtFw releases, linux-firmware, or Windows drivers."
    exit 1
  fi
  python3 "$ROOT/tools/make_firmware_cpp.py" --fw-dir "$FWDIR" -o "$FWBIN"
fi

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
KH=$SDK/System/Library/Frameworks/Kernel.framework/Headers
rm -rf "$OUT"; mkdir -p "$OUT/obj"

CXXFLAGS="-x c++ -arch x86_64 -mkernel -nostdinc++ -nostdlib -fapple-kext -fno-builtin \
 -fno-stack-protector -fasm-blocks -mno-ms-bitfields -fobjc-arc -std=gnu++14 -O2 -g0 \
 -DKERNEL -DKERNEL_PRIVATE -DMACH -DBUILDING_KEXT -DMODULE_VERSION=\"1.0.0\" -DPRODUCT_NAME=\"SimpleMtkBtFw\" \
 -I$KH -isysroot $SDK -I$SRC"

for f in SimpleMtkBtFw BtMtk USBDeviceController FwBinary; do
  echo "== compile $f.cpp =="
  clang $CXXFLAGS -c "$SRC/$f.cpp" -o "$OUT/obj/$f.o" 2> "$OUT/obj/$f.err" || { echo "FAIL $f:"; head -30 "$OUT/obj/$f.err"; exit 1; }
done

echo "== compile zutil.c (as C++) =="
clang $CXXFLAGS -c "$SRC/zutil.c" -o "$OUT/obj/zutil.o"

echo "== compile kmod glue =="
clang $CXXFLAGS -DKEXT_BUNDLE_ID='"com.laobamac.SimpleMtkBtFw"' -DKEXT_VERSION='"1.0.0"' \
  -c "$ROOT/kmod-info.cpp" -o "$OUT/obj/kmodinfo.o"

echo "== link =="
ld -kext -arch x86_64 -undefined dynamic_lookup \
  -L$SDK/usr/lib -lkmodc++ -lkmod \
  -o "$OUT/SimpleMtkBtFw" \
  "$OUT/obj/SimpleMtkBtFw.o" "$OUT/obj/BtMtk.o" "$OUT/obj/USBDeviceController.o" \
  "$OUT/obj/FwBinary.o" "$OUT/obj/zutil.o" "$OUT/obj/kmodinfo.o"
echo "== binary: $(stat -f %z "$OUT/SimpleMtkBtFw") bytes =="

# --- assemble .kext bundle ---
B="$OUT/SimpleMtkBtFw.kext/Contents"
mkdir -p "$B/MacOS"
cp "$OUT/SimpleMtkBtFw" "$B/MacOS/SimpleMtkBtFw"
sed -e 's|\$(PRODUCT_BUNDLE_IDENTIFIER)|com.laobamac.SimpleMtkBtFw|g' \
    -e 's|\$(EXECUTABLE_NAME)|SimpleMtkBtFw|g' \
    -e 's|\$(PRODUCT_NAME)|SimpleMtkBtFw|g' \
    -e 's|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|KEXT|g' \
    -e 's|\$(MARKETING_VERSION)|1.0.0|g' \
    -e 's|\$(CURRENT_PROJECT_VERSION)|1.0.0|g' \
    -e 's|\$(MODULE_VERSION)|1.0.0|g' \
    -e 's|\$(DEVELOPMENT_LANGUAGE)|en|g' \
    "$SRC/Info.plist" > "$B/Info.plist"
plutil -lint "$B/Info.plist"

# --- sanity check: kmod_info start/stop must be non-NULL (mod_start/mod_stop) ---
nm "$OUT/SimpleMtkBtFw" | grep -E " T _mod_start| T _mod_stop" >/dev/null \
  || { echo "WARNING: mod_start/mod_stop not found — glue broken?"; exit 1; }

echo "== SimpleMtkBtFw.kext built OK: $OUT/SimpleMtkBtFw.kext =="
