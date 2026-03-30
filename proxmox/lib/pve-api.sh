#!/usr/bin/env bash
# proxmox/lib/pve-api.sh — Proxmox VE REST API client (curl+jq)
# Requires: lib/common.sh sourced first (for info/warn logging).
# Uses warn() for non-fatal errors so callers can handle failures gracefully.
# Source guard: only load once
[[ -n "${_PVE_API_SH_LOADED:-}" ]] && return 0
_PVE_API_SH_LOADED=1

# Non-fatal error logger (warn, not error — error() from common.sh exits the process)
_pve_err() { printf '[%s] PVE ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# ── Configuration ────────────────────────────────────────────────────────────
PVE_HOST="${PVE_HOST:-https://192.168.1.52:8006}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-stray@pve!workflow-agent}"

# Load token secret from file if not set
if [[ -z "${PVE_TOKEN_SECRET:-}" ]]; then
  _pve_secret_file="${PVE_SECRETS_DIR:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/secrets}/stray@pve!workflow-agent.txt"
  if [[ -f "$_pve_secret_file" ]]; then
    PVE_TOKEN_SECRET="$(cat "$_pve_secret_file")"
  fi
fi

# ── Core API ─────────────────────────────────────────────────────────────────

# pve_api METHOD PATH [curl-args...]
# Makes an authenticated call to the Proxmox API. Returns the JSON response.
pve_api() {
  local method="$1" path="$2"; shift 2
  if [[ -z "${PVE_TOKEN_SECRET:-}" ]]; then
    _pve_err "PVE_TOKEN_SECRET not set and no secret file found"
    return 1
  fi
  curl -s -k -X "$method" \
    "${PVE_HOST}/api2/json${path}" \
    -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
    "$@"
}

# pve_api_data METHOD PATH [curl-args...]
# Same as pve_api but extracts .data from the response
pve_api_data() {
  pve_api "$@" | jq -r '.data'
}

# ── Node Operations ──────────────────────────────────────────────────────────

# pve_list_nodes — Returns all cluster nodes with status
pve_list_nodes() {
  pve_api GET /nodes | jq -r '.data[] | {node, status}'
}

# pve_node_online NODE — Returns 0 if node is online
pve_node_online() {
  local node="$1"
  local status
  status=$(pve_api GET /nodes | jq -r --arg n "$node" '.data[] | select(.node == $n) | .status')
  [[ "$status" == "online" ]]
}

# ── VM Operations ────────────────────────────────────────────────────────────

# pve_list_vms [NODE] — List all VMs, optionally filtered by node
pve_list_vms() {
  local node="${1:-}"
  if [[ -n "$node" ]]; then
    pve_api GET "/nodes/${node}/qemu" | jq -r '.data[] | {vmid, name, status}'
  else
    pve_api GET /cluster/resources?type=vm | jq -r '.data[] | {vmid, name, node, status}'
  fi
}

# pve_vm_exists VMID — Returns 0 if VM with given ID exists
pve_vm_exists() {
  local vmid="$1"
  pve_api GET /cluster/resources?type=vm | jq -e --argjson id "$vmid" '.data[] | select(.vmid == $id)' > /dev/null 2>&1
}

# pve_vm_status NODE VMID — Returns current VM status (running/stopped/etc)
pve_vm_status() {
  local node="$1" vmid="$2"
  pve_api GET "/nodes/${node}/qemu/${vmid}/status/current" | jq -r '.data.status'
}

# pve_next_vmid MIN MAX — Find next available VMID in range
pve_next_vmid() {
  local min="${1:-200}" max="${2:-299}"
  local used
  used=$(pve_api GET /cluster/resources?type=vm | jq -r '[.data[].vmid] | sort | .[]')
  for ((id=min; id<=max; id++)); do
    if ! echo "$used" | grep -qx "$id"; then
      echo "$id"
      return 0
    fi
  done
  return 1
}

# pve_create_vm NODE VMID [curl-args...] — Create a new VM
pve_create_vm() {
  local node="$1" vmid="$2"; shift 2
  pve_api POST "/nodes/${node}/qemu" \
    -d "vmid=${vmid}" \
    "$@"
}

# pve_configure_vm NODE VMID [curl-args...] — Update VM configuration
pve_configure_vm() {
  local node="$1" vmid="$2"; shift 2
  pve_api PUT "/nodes/${node}/qemu/${vmid}/config" "$@"
}

# pve_resize_disk NODE VMID DISK SIZE — Resize a VM disk
pve_resize_disk() {
  local node="$1" vmid="$2" disk="$3" size="$4"
  pve_api PUT "/nodes/${node}/qemu/${vmid}/resize" \
    -d "disk=${disk}" \
    -d "size=${size}"
}

# pve_start_vm NODE VMID — Start a VM
pve_start_vm() {
  local node="$1" vmid="$2"
  pve_api POST "/nodes/${node}/qemu/${vmid}/status/start"
}

# pve_stop_vm NODE VMID — Stop a VM (graceful)
pve_stop_vm() {
  local node="$1" vmid="$2"
  pve_api POST "/nodes/${node}/qemu/${vmid}/status/stop"
}

# pve_shutdown_vm NODE VMID — Shutdown a VM (ACPI)
pve_shutdown_vm() {
  local node="$1" vmid="$2"
  pve_api POST "/nodes/${node}/qemu/${vmid}/status/shutdown"
}

# pve_delete_vm NODE VMID — Delete a VM
pve_delete_vm() {
  local node="$1" vmid="$2"
  pve_api DELETE "/nodes/${node}/qemu/${vmid}"
}

# ── Template Operations ──────────────────────────────────────────────────────

# pve_clone_vm NODE TEMPLATE_VMID NEW_VMID NAME [TARGET_NODE]
pve_clone_vm() {
  local node="$1" template_vmid="$2" new_vmid="$3" name="$4"
  local target_node="${5:-$node}"
  pve_api POST "/nodes/${node}/qemu/${template_vmid}/clone" \
    -d "newid=${new_vmid}" \
    -d "name=${name}" \
    -d "target=${target_node}" \
    -d "full=1"
}

# pve_convert_to_template NODE VMID — Convert a VM into a template
pve_convert_to_template() {
  local node="$1" vmid="$2"
  pve_api POST "/nodes/${node}/qemu/${vmid}/template"
}

# pve_is_template NODE VMID — Returns 0 if VM is a template
pve_is_template() {
  local node="$1" vmid="$2"
  local tmpl
  tmpl=$(pve_api GET "/nodes/${node}/qemu/${vmid}/config" | jq -r '.data.template // 0')
  [[ "$tmpl" == "1" ]]
}

# ── Cloud-Init ───────────────────────────────────────────────────────────────

# pve_set_cloudinit NODE VMID CIUSER SSHKEYS IPCONFIG [NAMESERVER] [SEARCHDOMAIN]
pve_set_cloudinit() {
  local node="$1" vmid="$2" ciuser="$3" sshkeys="$4" ipconfig="$5"
  local nameserver="${6:-}" searchdomain="${7:-}"

  local args=()
  args+=(-d "ciuser=${ciuser}")
  args+=(-d "sshkeys=$(printf '%s' "$sshkeys" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=""))')")
  args+=(-d "ipconfig0=${ipconfig}")
  [[ -n "$nameserver" ]] && args+=(-d "nameserver=${nameserver}")
  [[ -n "$searchdomain" ]] && args+=(-d "searchdomain=${searchdomain}")

  pve_api PUT "/nodes/${node}/qemu/${vmid}/config" "${args[@]}"
}

# pve_set_cicustom NODE VMID USER_SNIPPET [NETWORK_SNIPPET] [META_SNIPPET]
# Requires snippet storage. Snippet format: "storage:snippets/filename"
pve_set_cicustom() {
  local node="$1" vmid="$2" user="$3"
  local network="${4:-}" meta="${5:-}"

  local cicustom="user=${user}"
  [[ -n "$network" ]] && cicustom="${cicustom},network=${network}"
  [[ -n "$meta" ]] && cicustom="${cicustom},meta=${meta}"

  pve_api PUT "/nodes/${node}/qemu/${vmid}/config" \
    -d "cicustom=${cicustom}"
}

# ── Storage Operations ───────────────────────────────────────────────────────

# pve_list_storage NODE — List storage on a node
pve_list_storage() {
  local node="$1"
  pve_api GET "/nodes/${node}/storage" | jq -r '.data[] | {storage, type, content, active, avail_gb: ((.avail // 0) / 1073741824 | floor), total_gb: ((.total // 0) / 1073741824 | floor)}'
}

# pve_storage_has_content NODE STORAGE CONTENT_TYPE
pve_storage_has_content() {
  local node="$1" storage="$2" content_type="$3"
  pve_api GET "/nodes/${node}/storage" | jq -e --arg s "$storage" --arg c "$content_type" \
    '.data[] | select(.storage == $s) | .content | split(",") | any(. == $c)' > /dev/null 2>&1
}

# pve_list_isos NODE STORAGE — List ISO images on a storage
pve_list_isos() {
  local node="$1" storage="${2:-local}"
  pve_api GET "/nodes/${node}/storage/${storage}/content" | jq -r '[.data[] | select(.content == "iso") | .volid] | .[]'
}

# pve_upload_file NODE STORAGE CONTENT_TYPE FILEPATH
# Upload a file to Proxmox storage (ISO, snippet, etc.)
pve_upload_file() {
  local node="$1" storage="$2" content_type="$3" filepath="$4"
  pve_api POST "/nodes/${node}/storage/${storage}/upload" \
    -F "content=${content_type}" \
    -F "filename=@${filepath}"
}

# pve_storage_enable_snippets NODE STORAGE
# Enable snippets content type on a storage backend
pve_storage_enable_snippets() {
  local node="$1" storage="$2"
  local current_content
  current_content=$(pve_api GET "/nodes/${node}/storage" | jq -r --arg s "$storage" '.data[] | select(.storage == $s) | .content')
  if echo "$current_content" | tr ',' '\n' | grep -qx "snippets"; then
    info "Snippets already enabled on ${storage}"
    return 0
  fi
  pve_api PUT "/storage/${storage}" \
    -d "content=${current_content},snippets"
}

# ── Task/Job Tracking ────────────────────────────────────────────────────────

# pve_wait_task NODE UPID [TIMEOUT_SECONDS]
# Wait for a Proxmox task to complete. Returns 0 on success, 1 on failure.
pve_wait_task() {
  local node="$1" upid="$2" timeout="${3:-300}"
  local elapsed=0
  while ((elapsed < timeout)); do
    local resp
    resp=$(pve_api GET "/nodes/${node}/tasks/${upid}/status")
    local status
    status=$(echo "$resp" | jq -r '.data.status')
    case "$status" in
      stopped)
        local exitstatus
        exitstatus=$(echo "$resp" | jq -r '.data.exitstatus')
        if [[ "$exitstatus" == "OK" ]]; then
          return 0
        else
          _pve_err "Task failed: $exitstatus"
          return 1
        fi
        ;;
      running)
        sleep 5
        ((elapsed += 5))
        ;;
      *)
        sleep 2
        ((elapsed += 2))
        ;;
    esac
  done
  _pve_err "Task timed out after ${timeout}s"
  return 1
}

# pve_extract_upid RESPONSE — Extract UPID from a Proxmox API response
pve_extract_upid() {
  echo "$1" | jq -r '.data // empty'
}

# ── Validation Helpers ───────────────────────────────────────────────────────

# pve_validate_connection — Check that we can reach the Proxmox API
pve_validate_connection() {
  local resp
  resp=$(pve_api GET /version 2>/dev/null) || return 1
  echo "$resp" | jq -e '.data.version' > /dev/null 2>&1
}

# pve_get_version — Return the Proxmox version string
pve_get_version() {
  pve_api GET /version | jq -r '.data.version'
}

# pve_validate_node NODE — Check node exists and is online
pve_validate_node() {
  local node="$1"
  pve_node_online "$node"
}

# pve_validate_storage NODE STORAGE CONTENT_TYPE — Check storage exists, is active, has capacity
pve_validate_storage() {
  local node="$1" storage="$2" content_type="$3"
  local info
  info=$(pve_api GET "/nodes/${node}/storage" | jq --arg s "$storage" --arg c "$content_type" '
    .data[] | select(.storage == $s) |
    if (.content | split(",") | any(. == $c)) then
      {ok: true, active: .active, avail_gb: ((.avail // 0) / 1073741824 | floor)}
    else
      {ok: false, reason: "content type \($c) not enabled"}
    end
  ')
  if [[ -z "$info" ]]; then
    _pve_err "Storage '${storage}' not found on node '${node}'"
    return 1
  fi
  local ok
  ok=$(echo "$info" | jq -r '.ok')
  if [[ "$ok" != "true" ]]; then
    local reason
    reason=$(echo "$info" | jq -r '.reason')
    _pve_err "Storage '${storage}' validation failed: ${reason}"
    return 1
  fi
  local active
  active=$(echo "$info" | jq -r '.active')
  if [[ "$active" != "1" ]]; then
    _pve_err "Storage '${storage}' is not active"
    return 1
  fi
  return 0
}

# pve_validate_iso NODE STORAGE VOLID — Check that an ISO exists
pve_validate_iso() {
  local node="$1" storage="$2" volid="$3"
  pve_api GET "/nodes/${node}/storage/${storage}/content" | jq -e --arg v "$volid" '.data[] | select(.volid == $v)' > /dev/null 2>&1
}

# pve_wait_ssh HOST [PORT] [TIMEOUT_SECONDS]
# Wait for SSH to become available on a host
pve_wait_ssh() {
  local host="$1" port="${2:-22}" timeout="${3:-300}"
  local elapsed=0
  while ((elapsed < timeout)); do
    if nc -z -w 2 "$host" "$port" 2>/dev/null; then
      return 0
    fi
    sleep 5
    ((elapsed += 5))
  done
  return 1
}
