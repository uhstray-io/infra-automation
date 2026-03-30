#!/usr/bin/env bash
# proxmox/pre-validate.sh — Pre-validation checks for Proxmox VM provisioning
# Validates: API connectivity, node status, storage, ISOs, available VMIDs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

source "${LIB_DIR}/common.sh"
source "${SCRIPT_DIR}/lib/pve-api.sh"

# ── Configuration ────────────────────────────────────────────────────────────
TARGET_NODE="${TARGET_NODE:-alphacentauri}"
VM_STORAGE="${VM_STORAGE:-vm-lvms}"
ISO_STORAGE="${ISO_STORAGE:-SharedISOs}"
UBUNTU_ISO="${UBUNTU_ISO:-SharedISOs:iso/ubuntu-24.04.3-live-server-amd64.iso}"
VMID_MIN="${VMID_MIN:-200}"
VMID_MAX="${VMID_MAX:-299}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

PASS=0
FAIL=0
WARN=0

check_pass() { info "  PASS: $1"; PASS=$((PASS + 1)); }
check_fail() { error "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check_warn() { warn "  WARN: $1"; WARN=$((WARN + 1)); }

# ── 1. API Connectivity ─────────────────────────────────────────────────────
info "== 1. Proxmox API Connectivity =="

if pve_validate_connection; then
  version=$(pve_get_version)
  check_pass "API reachable at ${PVE_HOST} (PVE ${version})"
else
  check_fail "Cannot reach Proxmox API at ${PVE_HOST}"
  error "Aborting: fix API connectivity before proceeding"
  exit 1
fi

# ── 2. Target Node ───────────────────────────────────────────────────────────
info "== 2. Target Node: ${TARGET_NODE} =="

if pve_validate_node "$TARGET_NODE"; then
  check_pass "Node '${TARGET_NODE}' is online"
else
  check_fail "Node '${TARGET_NODE}' is not online or not found"
fi

# List all nodes for reference
info "  Cluster nodes:"
pve_api GET /nodes | jq -r '.data[] | "    \(.node): \(.status)"'

# ── 3. Storage ───────────────────────────────────────────────────────────────
info "== 3. Storage Validation =="

# VM disk storage
if pve_validate_storage "$TARGET_NODE" "$VM_STORAGE" "images"; then
  avail=$(pve_api GET "/nodes/${TARGET_NODE}/storage" | jq -r --arg s "$VM_STORAGE" '.data[] | select(.storage == $s) | (.avail / 1073741824 | floor)')
  check_pass "VM storage '${VM_STORAGE}' active with ${avail}GB available"
else
  check_fail "VM storage '${VM_STORAGE}' not suitable for VM images"
fi

# ISO storage
if pve_validate_storage "$TARGET_NODE" "$ISO_STORAGE" "iso"; then
  check_pass "ISO storage '${ISO_STORAGE}' active and supports ISOs"
else
  check_fail "ISO storage '${ISO_STORAGE}' not available for ISOs"
fi

# Check snippet support (needed for cloud-init custom user-data)
if pve_storage_has_content "$TARGET_NODE" "local" "snippets"; then
  check_pass "Snippets enabled on 'local' storage"
else
  check_warn "Snippets not enabled on 'local' storage (will use seed ISO approach)"
fi

# Full storage listing
info "  Storage on ${TARGET_NODE}:"
pve_api GET "/nodes/${TARGET_NODE}/storage" | jq -r '.data[] | "    \(.storage): \(.type) [\(.content)] active=\(.active) avail=\((.avail // 0) / 1073741824 | floor)GB"'

# ── 4. Ubuntu ISO ────────────────────────────────────────────────────────────
info "== 4. Ubuntu ISO =="

if pve_validate_iso "$TARGET_NODE" "$ISO_STORAGE" "$UBUNTU_ISO"; then
  iso_size=$(pve_api GET "/nodes/${TARGET_NODE}/storage/${ISO_STORAGE}/content" | jq -r --arg v "$UBUNTU_ISO" '.data[] | select(.volid == $v) | (.size / 1073741824 * 100 | floor / 100)')
  check_pass "Ubuntu ISO found: ${UBUNTU_ISO} (${iso_size}GB)"
else
  check_fail "Ubuntu ISO not found: ${UBUNTU_ISO}"
fi

# List all available ISOs
info "  Available ISOs on ${ISO_STORAGE}:"
pve_list_isos "$TARGET_NODE" "$ISO_STORAGE" | sed 's/^/    /'

# ── 5. Existing VMs ─────────────────────────────────────────────────────────
info "== 5. VM Inventory =="

# VMs on target node
info "  VMs on ${TARGET_NODE}:"
pve_api GET "/nodes/${TARGET_NODE}/qemu" | jq -r '.data | sort_by(.vmid) | .[] | "    \(.vmid): \(.name) (\(.status))"'

# VMs in the target ID range
info "  VMs in ${VMID_MIN}-${VMID_MAX} range (all nodes):"
pve_api GET /cluster/resources?type=vm | jq -r --argjson min "$VMID_MIN" --argjson max "$VMID_MAX" \
  '[.data[] | select(.vmid >= $min and .vmid <= $max)] | sort_by(.vmid) | .[] | "    \(.vmid): \(.name) @ \(.node) (\(.status))"'

# Next available VMID
next_vmid=$(pve_next_vmid "$VMID_MIN" "$VMID_MAX" 2>/dev/null) || true
if [[ -n "$next_vmid" ]]; then
  check_pass "Next available VMID in ${VMID_MIN}-${VMID_MAX}: ${next_vmid}"
else
  check_fail "No available VMIDs in ${VMID_MIN}-${VMID_MAX} range"
fi

# Template VMID check
if pve_vm_exists "$TEMPLATE_VMID"; then
  if pve_is_template "$TARGET_NODE" "$TEMPLATE_VMID" 2>/dev/null; then
    check_pass "Template VM ${TEMPLATE_VMID} already exists"
  else
    check_warn "VMID ${TEMPLATE_VMID} exists but is NOT a template"
  fi
else
  check_pass "VMID ${TEMPLATE_VMID} available for template creation"
fi

# ── 6. Network Bridge ───────────────────────────────────────────────────────
info "== 6. Network Configuration =="

bridges=$(pve_api GET "/nodes/${TARGET_NODE}/network" | jq -r '[.data[] | select(.type == "bridge") | .iface] | join(", ")')
if [[ -n "$bridges" ]]; then
  check_pass "Network bridges on ${TARGET_NODE}: ${bridges}"
else
  check_warn "No network bridges found (API may lack permission)"
fi

# ── 7. SSH Key ───────────────────────────────────────────────────────────────
info "== 7. SSH Key =="

if [[ -f "${SCRIPT_DIR}/secrets/uhstray_ed25519.pub" ]]; then
  check_pass "SSH public key found: proxmox/secrets/uhstray_ed25519.pub"
else
  check_fail "SSH public key missing: proxmox/secrets/uhstray_ed25519.pub"
fi

if [[ -f "${SCRIPT_DIR}/secrets/uhstray_ed25519" ]]; then
  perms=$(stat -f '%Lp' "${SCRIPT_DIR}/secrets/uhstray_ed25519" 2>/dev/null || stat -c '%a' "${SCRIPT_DIR}/secrets/uhstray_ed25519" 2>/dev/null)
  if [[ "$perms" == "600" ]]; then
    check_pass "SSH private key permissions correct (600)"
  else
    check_warn "SSH private key permissions: ${perms} (should be 600)"
  fi
else
  check_fail "SSH private key missing: proxmox/secrets/uhstray_ed25519"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "=========================================="
info "Pre-Validation Summary"
info "=========================================="
info "  PASS: ${PASS}"
[[ $WARN -gt 0 ]] && warn "  WARN: ${WARN}"
[[ $FAIL -gt 0 ]] && error "  FAIL: ${FAIL}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  error "Pre-validation FAILED — fix the above issues before proceeding"
  exit 1
else
  info "Pre-validation PASSED — ready to provision"
  echo ""
  info "Recommended next steps:"
  info "  Template VMID: ${TEMPLATE_VMID}"
  info "  OpenBao VMID:  ${next_vmid:-N/A}"
  info "  Target node:   ${TARGET_NODE}"
  info "  VM storage:    ${VM_STORAGE}"
  info "  ISO:           ${UBUNTU_ISO}"
fi
