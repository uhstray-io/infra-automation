#!/usr/bin/env bash
# bao-client.sh — Lightweight OpenBao HTTP API client
# Uses curl + jq only — no OpenBao binary required on service VMs.
# Source guard: safe to source multiple times
[ -n "${_BAO_CLIENT_SH_LOADED:-}" ] && return 0
_BAO_CLIENT_SH_LOADED=1

OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"
BAO_TOKEN="${BAO_TOKEN:-}"

# ── Internal helpers ──────────────────────────────────────────────────────────

_bao_api() {
  local method="$1" path="$2"; shift 2
  curl -sf -X "$method" \
    -H "X-Vault-Token: ${BAO_TOKEN}" \
    -H "Content-Type: application/json" \
    "${OPENBAO_ADDR}/v1${path}" \
    "$@"
}

# ── Authentication ────────────────────────────────────────────────────────────

# bao_authenticate <secrets_dir>
# Authenticates via AppRole using role_id + secret_id from <secrets_dir>/
# Sets BAO_TOKEN for subsequent calls.
bao_authenticate() {
  local secrets_dir="$1"
  local role_id secret_id

  role_id=$(cat "${secrets_dir}/role-id.txt" 2>/dev/null) || {
    echo "ERROR: ${secrets_dir}/role-id.txt not found" >&2; return 1
  }
  secret_id=$(cat "${secrets_dir}/secret-id.txt" 2>/dev/null) || {
    echo "ERROR: ${secrets_dir}/secret-id.txt not found" >&2; return 1
  }

  local response
  response=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    "${OPENBAO_ADDR}/v1/auth/approle/login" \
    -d "$(jq -n --arg r "$role_id" --arg s "$secret_id" '{"role_id":$r,"secret_id":$s}')")

  BAO_TOKEN=$(echo "$response" | jq -r '.auth.client_token')
  [ -n "$BAO_TOKEN" ] && [ "$BAO_TOKEN" != "null" ] || {
    echo "ERROR: AppRole authentication failed" >&2; return 1
  }
  export BAO_TOKEN
}

# bao_authenticate_root <secrets_dir>
# Authenticates using the root token from init.json (bootstrap only)
bao_authenticate_root() {
  local secrets_dir="$1"
  BAO_TOKEN=$(jq -r '.root_token' "${secrets_dir}/init.json" 2>/dev/null) || {
    echo "ERROR: ${secrets_dir}/init.json not found" >&2; return 1
  }
  [ -n "$BAO_TOKEN" ] && [ "$BAO_TOKEN" != "null" ] || {
    echo "ERROR: No root token in init.json" >&2; return 1
  }
  export BAO_TOKEN
}

# ── KV v2 Operations ─────────────────────────────────────────────────────────

# bao_kv_get <path> — returns JSON data object
bao_kv_get() {
  local path="$1"
  _bao_api GET "/secret/data/${path}" | jq -r '.data.data'
}

# bao_kv_get_field <path> <field> — returns a single field value
bao_kv_get_field() {
  local path="$1" field="$2"
  _bao_api GET "/secret/data/${path}" | jq -r --arg f "$field" '.data.data[$f] // empty'
}

# bao_kv_put <path> <json_data>
# Writes a new version of a secret. json_data is a JSON object of key-value pairs.
bao_kv_put() {
  local path="$1" json_data="$2"
  _bao_api POST "/secret/data/${path}" -d "$(jq -n --argjson data "$json_data" '{"data": $data}')"
}

# bao_kv_patch <path> key=value [key=value...]
# Merges fields into an existing secret without overwriting other fields.
bao_kv_patch() {
  local path="$1"; shift
  local data="{}"
  for kv in "$@"; do
    local key="${kv%%=*}" val="${kv#*=}"
    data=$(echo "$data" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
  done
  curl -sf -X PATCH \
    -H "X-Vault-Token: ${BAO_TOKEN}" \
    -H "Content-Type: application/merge-patch+json" \
    "${OPENBAO_ADDR}/v1/secret/data/${path}" \
    -d "$(jq -n --argjson d "$data" '{"data": $d}')" >/dev/null
}

# ── Health Check ──────────────────────────────────────────────────────────────

# bao_health — returns 0 if OpenBao is initialized and unsealed
bao_health() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OPENBAO_ADDR}/v1/sys/health" 2>/dev/null) || code="000"
  [ "$code" = "200" ]
}

# bao_wait_ready <timeout_seconds>
# Polls until OpenBao is initialized and unsealed
bao_wait_ready() {
  local timeout="${1:-60}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if bao_health; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "ERROR: OpenBao not ready at ${OPENBAO_ADDR} after ${timeout}s" >&2
  return 1
}
