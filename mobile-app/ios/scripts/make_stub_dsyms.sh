#!/bin/bash
# Generates stub .dSYM bundles for vendored binary frameworks that don't ship
# their own dSYMs (cactus + flutter_gemma's LiteRT-LM dylibs are shipped with
# debug info stripped and OSO references pointing at vendor build caches we
# don't have).
#
# Without dSYMs, App Store Connect's symbol upload fails with "Upload Symbols
# Failed" — the IPA is accepted but crashes from those frameworks won't be
# symbolicated. Apple's upload pipeline matches dSYMs to binaries by reading
# `LC_UUID` from the Mach-O at `<bundle>/Contents/Resources/DWARF/<name>`.
# A minimal 56-byte MH_DSYM Mach-O containing only LC_UUID is sufficient to
# satisfy the UUID match (no real DWARF — crashes still won't be symbolicated
# in App Store Connect, but the warning goes away).
#
# Usage: make_stub_dsyms.sh <FRAMEWORKS_DIR> <DSYM_OUTPUT_DIR>
# Designed to be called from a CocoaPods-generated build phase during archive.
set -eu

FRAMEWORKS_DIR="${1:?usage: $0 FRAMEWORKS_DIR DSYM_OUTPUT_DIR}"
DSYM_DIR="${2:?usage: $0 FRAMEWORKS_DIR DSYM_OUTPUT_DIR}"

FRAMEWORKS=(
  cactus
  cactus_util
  LiteRtLm
  GemmaModelConstraintProvider
  LiteRtMetalAccelerator
  StreamProxy
  objective_c
  sqlite3
)

mkdir -p "$DSYM_DIR"

for fw in "${FRAMEWORKS[@]}"; do
  binary="$FRAMEWORKS_DIR/${fw}.framework/${fw}"
  if [ ! -f "$binary" ]; then
    continue
  fi

  uuid=$(xcrun dwarfdump --uuid "$binary" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$uuid" ]; then
    echo "warning: could not read UUID for $fw" >&2
    continue
  fi

  dsym_bundle="$DSYM_DIR/${fw}.framework.dSYM"
  dwarf_path="$dsym_bundle/Contents/Resources/DWARF/${fw}"

  if [ -f "$dwarf_path" ]; then
    existing=$(xcrun dwarfdump --uuid "$dwarf_path" 2>/dev/null | head -1 | awk '{print $2}')
    if [ "$existing" = "$uuid" ]; then
      continue
    fi
  fi

  rm -rf "$dsym_bundle"
  mkdir -p "$dsym_bundle/Contents/Resources/DWARF"

  cat > "$dsym_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleIdentifier</key>
  <string>com.apple.xcode.dsym.${fw}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>dSYM</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST

  /usr/bin/env python3 - "$uuid" "$dwarf_path" <<'PY'
import struct, sys, uuid as uuidmod

MH_MAGIC_64 = 0xfeedfacf
CPU_TYPE_ARM64 = 0x0100000c
MH_DSYM = 0xa
LC_UUID = 0x1b

uuid_hex, dst = sys.argv[1], sys.argv[2]
ub = uuidmod.UUID(uuid_hex).bytes
header = struct.pack('<IIIIIIII',
                     MH_MAGIC_64, CPU_TYPE_ARM64, 0, MH_DSYM,
                     1, 24, 0, 0)
cmd = struct.pack('<II16s', LC_UUID, 24, ub)
with open(dst, 'wb') as f:
    f.write(header + cmd)
PY

  echo "Generated stub dSYM for $fw (UUID $uuid)"
done
