#!/usr/bin/env bash
# Build a cloud-init seed ISO (NoCloud datasource) for Ubuntu autoinstall.
# The ISO contains user-data and meta-data, labeled "cidata".
# Works on Linux (genisoimage) and macOS (mkisofs from cdrtools or hdiutil).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-${SCRIPT_DIR}/autoinstall-seed.iso}"
USER_DATA="${SCRIPT_DIR}/autoinstall-user-data.yml"
META_DATA="${SCRIPT_DIR}/meta-data"

# Validate inputs
for f in "$USER_DATA" "$META_DATA"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing required file: $f" >&2
    exit 1
  fi
done

# Build the ISO
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp "$USER_DATA" "${TMPDIR}/user-data"
cp "$META_DATA" "${TMPDIR}/meta-data"

if command -v genisoimage &>/dev/null; then
  genisoimage -output "$OUTPUT" -volid cidata -joliet -rock \
    "${TMPDIR}/user-data" "${TMPDIR}/meta-data"
elif command -v mkisofs &>/dev/null; then
  mkisofs -output "$OUTPUT" -volid cidata -joliet -rock \
    "${TMPDIR}/user-data" "${TMPDIR}/meta-data"
elif command -v hdiutil &>/dev/null; then
  # macOS: use hdiutil to create a hybrid ISO
  hdiutil makehybrid -o "$OUTPUT" -iso -joliet \
    -default-volume-name cidata "$TMPDIR"
  # hdiutil appends .iso if not present
  [[ -f "${OUTPUT}.iso" ]] && mv "${OUTPUT}.iso" "$OUTPUT"
else
  echo "ERROR: No ISO creation tool found." >&2
  echo "  Install one of:" >&2
  echo "    Linux:  apt install genisoimage" >&2
  echo "    macOS:  brew install cdrtools (or hdiutil is built-in)" >&2
  exit 1
fi

echo "Seed ISO created: $OUTPUT"
echo "  Size: $(du -h "$OUTPUT" | cut -f1)"
