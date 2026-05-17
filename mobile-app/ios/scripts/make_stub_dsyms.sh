#!/bin/bash
# Generates placeholder .dSYM bundles for vendored binary frameworks that don't
# ship their own dSYMs (cactus + flutter_gemma's LiteRT-LM dylibs are shipped
# with debug info stripped and OSO references pointing at vendor build caches
# we don't have). Without dSYMs, App Store Connect's symbol upload fails with
# "Upload Symbols Failed".
#
# Approach: clone a real dSYM bundle from the build output (the smallest one
# is preferred to keep the archive lean), rename the inner DWARF binary, then
# patch the cloned LC_UUID load command to match the target framework's binary
# UUID. Apple's symbol-upload pipeline matches dSYMs to binaries by UUID only,
# so the (semantically wrong) DWARF content doesn't matter — only that the
# UUID matches. Empty 56-byte stubs were tried first but `xcrun symbols`
# silently drops dSYMs with no symbol data during IPA Symbols/ generation.
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

# Pick the smallest existing real dSYM as the clone template, falling back to
# whichever ones happen to be present. Listed smallest-first by observed size
# in this project; resilient if some are missing.
TEMPLATE_DSYM=""
for candidate in ObjectBox.framework.dSYM App.framework.dSYM Runner.app.dSYM Flutter.framework.dSYM; do
  cand_path="$DSYM_DIR/$candidate"
  if [ -d "$cand_path" ]; then
    inner="$cand_path/Contents/Resources/DWARF"
    if [ -d "$inner" ] && [ -n "$(ls -A "$inner" 2>/dev/null)" ]; then
      TEMPLATE_DSYM="$cand_path"
      break
    fi
  fi
done

if [ -z "$TEMPLATE_DSYM" ]; then
  echo "warning: no template dSYM found in $DSYM_DIR; skipping stub generation" >&2
  exit 0
fi

echo "Using $TEMPLATE_DSYM as stub template"

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
  cp -R "$TEMPLATE_DSYM" "$dsym_bundle"

  # Rename inner DWARF binary to match this framework
  inner_dir="$dsym_bundle/Contents/Resources/DWARF"
  original_inner=$(ls "$inner_dir" | head -1)
  if [ "$original_inner" != "$fw" ]; then
    mv "$inner_dir/$original_inner" "$inner_dir/$fw"
  fi

  # Some templates (App.framework.dSYM in particular) ship as fat Mach-O;
  # thin them to arm64 first so the UUID patch hits a single slice.
  if file "$inner_dir/$fw" 2>/dev/null | grep -q "universal binary"; then
    lipo -thin arm64 "$inner_dir/$fw" -output "$inner_dir/$fw.thin" 2>/dev/null && \
      mv "$inner_dir/$fw.thin" "$inner_dir/$fw"
  fi

  /usr/bin/env python3 - "$uuid" "$inner_dir/$fw" <<'PY'
import struct, sys, uuid as uuidmod

uuid_hex, path = sys.argv[1], sys.argv[2]
target = uuidmod.UUID(uuid_hex).bytes

with open(path, 'rb+') as f:
    data = f.read()
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic != 0xfeedfacf:
        sys.exit(f"unexpected mach-o magic 0x{magic:x}")
    offset = 32  # mach_header_64 ends here
    while offset < len(data):
        cmd, cmdsize = struct.unpack_from('<II', data, offset)
        if cmd == 0x1b:  # LC_UUID
            f.seek(offset + 8)
            f.write(target)
            break
        offset += cmdsize
    else:
        sys.exit("LC_UUID not found in template dSYM")
PY

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.apple.xcode.dsym.${fw}" "$dsym_bundle/Contents/Info.plist" 2>/dev/null || true

  echo "Cloned stub dSYM for $fw (UUID $uuid)"
done
