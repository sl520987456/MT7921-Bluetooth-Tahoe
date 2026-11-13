#!/bin/bash
# build-btpatcher.sh — build SimpleMtkBtPatcher.kext (Lilu plugin) WITHOUT full Xcode
#
# Usage:  ./build-btpatcher.sh
# Output: build/SimpleMtkBtPatcher.kext
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/SimpleMtkBtPatcher"
OUT="$ROOT/build-patcher"

# --- dependencies (auto-clone) ---
DEPS="$ROOT/.deps"
mkdir -p "$DEPS"
LILU="$DEPS/Lilu"
MKSDK="$DEPS/MacKernelSDK"
[ -d "$LILU/.git" ] || git clone --depth 1 https://github.com/acidanthera/Lilu.git "$LILU"
[ -d "$MKSDK/.git" ] || git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git "$MKSDK"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
KH=$SDK/System/Library/Frameworks/Kernel.framework/Headers
rm -rf "$OUT"; mkdir -p "$OUT/obj"

FLAGS="-x c++ -arch x86_64 -mkernel -nostdinc++ -nostdlib -fapple-kext -fno-builtin \
 -fno-stack-protector -fasm-blocks -mno-ms-bitfields -fobjc-arc -std=gnu++14 -O2 -g0 \
 -DKERNEL -DKERNEL_PRIVATE -DMACH -DBUILDING_KEXT \
 -DMODULE_VERSION=\"1.0.0\" -DPRODUCT_NAME=SimpleMtkBtPatcher \
 -I$LILU/Lilu -I$MKSDK/Headers -I$SRC -isysroot $SDK -I$KH"

echo "== compile SimpleMtkBtPatcher.cpp =="
clang $FLAGS -c "$SRC/SimpleMtkBtPatcher.cpp" -o "$OUT/obj/btpatcher.o"

echo "== compile Lilu plugin_start.cpp =="
clang $FLAGS -c "$LILU/Lilu/Library/plugin_start.cpp" -o "$OUT/obj/plugin_start.o"

echo "== compile kmod glue =="
clang $FLAGS -DKEXT_BUNDLE_ID='"com.laobamac.SimpleMtkBtPatcher"' -DKEXT_VERSION='"1.0.0"' \
  -DKEXT_START_SYM=SimpleMtkBtPatcher_kern_start \
  -c "$ROOT/kmod-info.cpp" -o "$OUT/obj/kmodinfo.o"

echo "== link =="
ld -kext -arch x86_64 -undefined dynamic_lookup \
  -L$SDK/usr/lib -lkmodc++ -lkmod \
  -o "$OUT/SimpleMtkBtPatcher" \
  "$OUT/obj/btpatcher.o" "$OUT/obj/plugin_start.o" "$OUT/obj/kmodinfo.o"
echo "== binary: $(stat -f %z "$OUT/SimpleMtkBtPatcher") bytes =="

# --- assemble .kext bundle ---
B="$OUT/SimpleMtkBtPatcher.kext/Contents"
mkdir -p "$B/MacOS"
cp "$OUT/SimpleMtkBtPatcher" "$B/MacOS/SimpleMtkBtPatcher"
sed -e 's|\$(PRODUCT_BUNDLE_IDENTIFIER)|com.laobamac.SimpleMtkBtPatcher|g' \
    -e 's|\$(EXECUTABLE_NAME)|SimpleMtkBtPatcher|g' \
    -e 's|\$(PRODUCT_NAME)|SimpleMtkBtPatcher|g' \
    -e 's|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|KEXT|g' \
    -e 's|\$(MARKETING_VERSION)|1.0.0|g' \
    -e 's|\$(CURRENT_PROJECT_VERSION)|1.0.0|g' \
    -e 's|\$(MODULE_VERSION)|1.0.0|g' \
    -e 's|\$(DEVELOPMENT_LANGUAGE)|en|g' \
    "$SRC/Info.plist" > "$B/Info.plist"
plutil -lint "$B/Info.plist"

# --- sanity check: Lilu plugin entry must exist ---
nm "$OUT/SimpleMtkBtPatcher" | grep -q " T _SimpleMtkBtPatcher_kern_start" \
  || { echo "WARNING: kern_start entry missing — plugin will never load!"; exit 1; }

echo "== SimpleMtkBtPatcher.kext built OK: $OUT/SimpleMtkBtPatcher.kext =="
