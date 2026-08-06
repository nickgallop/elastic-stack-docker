#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
KEYCHAIN_PREFIX=elastic-stack-docker-vault
VAULT_TOKEN=""

usage() {
  cat <<'EOF'
Usage:
  scripts/vault-add-consumer.sh <name> <kv-path>

Onboards a new least-privilege Vault consumer: writes a policy scoped to
secret/data/<kv-path> (+ metadata), enables an AppRole bound to that policy,
and stores its role_id/secret_id in the macOS Keychain. Requires Vault to
already be bootstrapped (run `scripts/elastic-with-vault.sh up` at least
once first, so the root token exists in the Keychain).

Example:
  scripts/vault-add-consumer.sh es-automation automation/es-user
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

keychain_service() {
  printf '%s-%s' "$KEYCHAIN_PREFIX" "$1"
}

keychain_get() {
  security find-generic-password -a "$USER" -s "$(keychain_service "$1")" -w 2>/dev/null || true
}

keychain_set() {
  security add-generic-password -a "$USER" -s "$(keychain_service "$1")" -w "$2" -U >/dev/null
}

keychain_require() {
  value=$(keychain_get "$1")
  if [ -z "$value" ]; then
    echo "Missing Keychain item '$(keychain_service "$1")'. Run 'scripts/elastic-with-vault.sh up' first to bootstrap Vault." >&2
    exit 1
  fi
  printf '%s' "$value"
}

run_vault() {
  docker compose exec -T \
    -e VAULT_ADDR="$VAULT_ADDR" \
    -e VAULT_TOKEN="$VAULT_TOKEN" \
    vault vault "$@"
}

main() {
  require_cmd docker
  require_cmd security

  name=${1:-}
  kv_path=${2:-}
  if [ -z "$name" ] || [ -z "$kv_path" ]; then
    usage >&2
    exit 1
  fi

  cd "$ROOT_DIR"

  policy_file="vault/policies/$name.hcl"
  cat > "$policy_file" <<EOF
path "secret/data/$kv_path" {
  capabilities = ["create", "read", "update"]
}

path "secret/metadata/$kv_path" {
  capabilities = ["read", "list"]
}
EOF
  echo "Wrote $policy_file"

  VAULT_TOKEN=$(keychain_require root-token)

  run_vault policy write "$name" "/vault/policies/$name.hcl" >/dev/null
  echo "Wrote Vault policy '$name'"

  if ! run_vault auth list -format=json | grep -q '"approle/"'; then
    run_vault auth enable approle >/dev/null
  fi

  run_vault write "auth/approle/role/$name" \
    token_policies="$name" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null

  role_id=$(run_vault read -field=role_id "auth/approle/role/$name/role-id")
  secret_id=$(run_vault write -f -field=secret_id "auth/approle/role/$name/secret-id")

  keychain_set "$name-role-id" "$role_id"
  keychain_set "$name-secret-id" "$secret_id"
  role_id=""
  secret_id=""
  VAULT_TOKEN=""

  cat <<EOF

Consumer '$name' onboarded:
  - Vault policy: $name (scoped to secret/data/$kv_path)
  - AppRole:      $name
  - Keychain:     ${KEYCHAIN_PREFIX}-$name-role-id, ${KEYCHAIN_PREFIX}-$name-secret-id

Native macOS processes can read these directly via 'security find-generic-password'
(or Python's keyring package). Anything running inside a Linux container needs
role_id/secret_id injected as env vars by a host-side launcher script, the same
way elastic-with-vault.sh injects ELASTIC_PASSWORD/KIBANA_PASSWORD today.
EOF
}

main "$@"
