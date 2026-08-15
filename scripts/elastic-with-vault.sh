#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_DIR=$ROOT_DIR
VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
VAULT_SECRET_PATH=${VAULT_SECRET_PATH:-secret/elastic}
VAULT_MOUNT=${VAULT_SECRET_PATH%%/*}
VAULT_KEY_PATH=${VAULT_SECRET_PATH#*/}
VAULT_ROLE=elastic-stack
KEYCHAIN_PREFIX=elastic-stack-docker-vault
VAULT_TOKEN=""

usage() {
  cat <<'EOF'
Usage:
  scripts/elastic-with-vault.sh up
  scripts/elastic-with-vault.sh show
  scripts/elastic-with-vault.sh env

Commands:
  up    Ensure Vault is running/unsealed, generate elastic passwords if missing, then start Compose with Vault-backed credentials.
  show  Print the stored Vault secret metadata and values.
  env   Print shell exports for the stored elastic and kibana passwords.

Notes:
  - `up` generates passwords only when the Vault secret does not already exist.
  - For an already initialized Elasticsearch data volume, Vault must contain the
    same password that Elasticsearch was bootstrapped with, or startup auth will fail.
  - No Vault secret ever touches disk. On first run, the root token and unseal
    key are captured straight from `vault operator init` output into the macOS
    Keychain, then used once to bootstrap a least-privilege `elastic-stack`
    AppRole (also Keychain-only). Every routine run authenticates via that
    AppRole, not the root token. Onboard additional least-privilege consumers
    with scripts/vault-add-consumer.sh.
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
    echo "Missing Keychain item '$(keychain_service "$1")'. Run '$0 up' first to bootstrap Vault." >&2
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

start_vault() {
  docker compose up -d vault >/dev/null
}

wait_for_vault() {
  echo "Waiting for Vault to become available..."
  while :; do
    if docker compose exec -T vault sh -c 'vault status -format=json >/dev/null 2>&1; code=$?; [ "$code" -eq 0 ] || [ "$code" -eq 2 ]'; then
      return 0
    fi
    sleep 1
  done
}

vault_status_json() {
  docker compose exec -T vault vault status -format=json 2>/dev/null || true
}

parse_init_field() {
  # Args: <key>. Reads `vault operator init -format=json` output from stdin.
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

parse_unseal_key() {
  # Reads `vault operator init -format=json` output from stdin.
  awk '/"unseal_keys_b64"/{getline; gsub(/[",[:space:]]/, "", $0); print; exit}'
}

bootstrap_vault() {
  # Called once, immediately after `vault operator init`, with VAULT_TOKEN
  # already set to the root token. Only place in this script that uses it.
  echo "Bootstrapping Vault: kv-v2 mount, elastic-stack policy, AppRole..."

  if ! run_vault secrets list -format=json | grep -q "\"$VAULT_MOUNT/\""; then
    run_vault secrets enable -path="$VAULT_MOUNT" kv-v2 >/dev/null
  fi

  run_vault policy write "$VAULT_ROLE" /vault/policies/elastic-stack.hcl >/dev/null

  if ! run_vault auth list -format=json | grep -q '"approle/"'; then
    run_vault auth enable approle >/dev/null
  fi

  run_vault write "auth/approle/role/$VAULT_ROLE" \
    token_policies="$VAULT_ROLE" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null

  role_id=$(run_vault read -field=role_id "auth/approle/role/$VAULT_ROLE/role-id")
  secret_id=$(run_vault write -f -field=secret_id "auth/approle/role/$VAULT_ROLE/secret-id")

  keychain_set "$VAULT_ROLE-role-id" "$role_id"
  keychain_set "$VAULT_ROLE-secret-id" "$secret_id"
  role_id=""
  secret_id=""

  echo "Stored $VAULT_ROLE AppRole credentials in Keychain."
}

ensure_initialized_and_unsealed() {
  status_json=$(vault_status_json)
  if [ -z "$status_json" ]; then
    echo "Vault did not respond." >&2
    exit 1
  fi

  if printf '%s' "$status_json" | grep -Eq '"initialized"[[:space:]]*:[[:space:]]*false'; then
    echo "Initializing Vault (1 key share, 1 key threshold)..."
    init_json=$(docker compose exec -T vault vault operator init -key-shares=1 -key-threshold=1 -format=json)

    root_token=$(printf '%s' "$init_json" | parse_init_field root_token)
    unseal_key=$(printf '%s' "$init_json" | parse_unseal_key)
    init_json=""

    keychain_set root-token "$root_token"
    keychain_set unseal-key "$unseal_key"
    needs_bootstrap=1
  else
    unseal_key=$(keychain_require unseal-key)
    needs_bootstrap=0
  fi

  status_json=$(vault_status_json)
  if printf '%s' "$status_json" | grep -Eq '"sealed"[[:space:]]*:[[:space:]]*true'; then
    echo "Unsealing Vault..."
    docker compose exec -T -e VAULT_UNSEAL_KEY="$unseal_key" vault sh -c 'vault operator unseal "$VAULT_UNSEAL_KEY"' >/dev/null
  fi
  unseal_key=""

  if [ "$needs_bootstrap" = 1 ]; then
    VAULT_TOKEN=$root_token
    bootstrap_vault
    VAULT_TOKEN=""
    root_token=""
  fi
}

export_vault_auth() {
  role_id=$(keychain_require "$VAULT_ROLE-role-id")
  secret_id=$(keychain_require "$VAULT_ROLE-secret-id")

  VAULT_TOKEN=$(docker compose exec -T \
    -e VAULT_ADDR="$VAULT_ADDR" \
    -e VAULT_ROLE_ID="$role_id" \
    -e VAULT_SECRET_ID="$secret_id" \
    vault sh -c 'vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID"')
  role_id=""
  secret_id=""

  if [ -z "$VAULT_TOKEN" ]; then
    echo "Failed to authenticate via AppRole '$VAULT_ROLE'." >&2
    exit 1
  fi
}

random_password() {
  openssl rand -base64 24 | tr -d '\n'
}

secret_exists() {
  run_vault kv get -mount="$VAULT_MOUNT" "$1" >/dev/null 2>&1
}

ensure_elastic_secret() {
  if secret_exists "$VAULT_KEY_PATH"; then
    return 0
  fi

  elastic_password=$(random_password)
  kibana_password=$(random_password)

  run_vault kv put "$VAULT_SECRET_PATH" \
    elastic_password="$elastic_password" \
    kibana_password="$kibana_password" \
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

  echo "Generated credentials and stored them in Vault at $VAULT_SECRET_PATH"
}

get_secret_field() {
  field=$1
  run_vault kv get -mount="$VAULT_MOUNT" -field="$field" "$VAULT_KEY_PATH"
}

compose_up() {
  elastic_password=$(get_secret_field elastic_password)
  kibana_password=$(get_secret_field kibana_password)

  echo "Starting Compose with Vault-backed elastic credentials..."
  ELASTIC_PASSWORD=$elastic_password \
  KIBANA_PASSWORD=$kibana_password \
  docker compose up -d
}

wait_for_kibana() {
  echo "Waiting for Kibana to become healthy..."
  cid=$(docker compose ps -q kibana)
  while :; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "")
    [ "$health" = "healthy" ] && return 0
    sleep 2
  done
}

sync_fleet_output_ca() {
  # The `certs` volume's CA is regenerated whenever it's recreated (e.g. `docker compose
  # down -v`), which would otherwise silently break fleet-server's TLS trust of es01 without
  # any config drift being obvious. Read the CA straight from es01's mount and push it into
  # Fleet's default output on every `up`, so the trusted CA is always the one actually in use.
  echo "Syncing Fleet output CA with the current certs volume..."
  ca_pem=$(docker compose exec -T es01 cat config/certs/ca/ca.crt)
  ca_escaped=$(printf '%s' "$ca_pem" | awk '{printf "%s\\n", $0}')

  attempt=0
  http_code=""
  while [ "$attempt" -lt 10 ]; do
    http_code=$(docker compose exec -T kibana curl -s -o /dev/null -w '%{http_code}' \
      --cacert config/certs/ca/ca.crt \
      -u "elastic:${elastic_password}" \
      -X PUT "https://localhost:5601/api/fleet/outputs/fleet-default-output" \
      -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
      -d "{\"name\":\"default\",\"type\":\"elasticsearch\",\"hosts\":[\"https://es01:9200\"],\"is_default\":true,\"is_default_monitoring\":true,\"ca_trusted_fingerprint\":null,\"ssl\":{\"certificate_authorities\":[\"$ca_escaped\"]}}")
    if [ "$http_code" = "200" ]; then
      echo "Fleet output CA synced."
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 3
  done

  echo "Warning: could not sync Fleet output CA (last HTTP status: $http_code). Fleet may still be setting up - re-run '$0 up' once it settles." >&2
}

deploy_custom_apm_pipeline() {
  echo "Deploying custom traces-apm ingest pipeline..."

  pipeline_json=$(cat <<'EOF'
{
  "description": "Custom enrichment for traces-apm-*: request format, span volume/complexity classification.",
  "processors": [
    {
      "dissect": {
        "if": "ctx.transaction?.name != null && ctx.transaction.name.contains('/noisy/')",
        "field": "transaction.name",
        "pattern": "%{}/noisy/%{labels.request_format}",
        "ignore_failure": true
      }
    },
    {
      "script": {
        "if": "ctx.transaction?.span_count?.started != null",
        "source": "def started = ctx.transaction.span_count.started; def class = started >= 100 ? 'high' : (started >= 20 ? 'medium' : 'low'); if (ctx.labels == null) { ctx.labels = [:]; } ctx.labels.span_volume_class = class;"
      }
    },
    {
      "script": {
        "if": "ctx.numeric_labels?.node_count != null",
        "source": "def nodes = ctx.numeric_labels.node_count; def complexity = nodes >= 500 ? 'high' : (nodes >= 50 ? 'medium' : 'low'); if (ctx.labels == null) { ctx.labels = [:]; } ctx.labels.node_complexity = complexity;"
      }
    }
  ],
  "on_failure": [
    {
      "set": {
        "field": "labels.pipeline_error",
        "value": "{{_ingest.on_failure_message}}"
      }
    }
  ]
}
EOF
  )

  attempt=0
  response=""
  while [ "$attempt" -lt 10 ]; do
    response=$(docker compose exec -T es01 curl -s \
      --cacert config/certs/ca/ca.crt \
      -u "elastic:${elastic_password}" \
      -X PUT "https://localhost:9200/_ingest/pipeline/traces-apm@custom" \
      -H 'Content-Type: application/json' \
      -d "$pipeline_json")
    if printf '%s' "$response" | grep -q '"acknowledged":true'; then
      echo "Custom traces-apm ingest pipeline synced."
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 3
  done

  echo "Warning: could not sync custom traces-apm ingest pipeline (last response: $response). The apm package may still be installing - re-run '$0 up' once it settles." >&2
}

show_secret() {
  run_vault kv get "$VAULT_SECRET_PATH"
}

show_env() {
  elastic_password=$(get_secret_field elastic_password)
  kibana_password=$(get_secret_field kibana_password)

  printf "export ELASTIC_PASSWORD='%s'\n" "$elastic_password"
  printf "export KIBANA_PASSWORD='%s'\n" "$kibana_password"
}

main() {
  require_cmd docker
  require_cmd openssl
  require_cmd security

  cmd=${1:-}
  case "$cmd" in
    up)
      cd "$COMPOSE_DIR"
      start_vault
      wait_for_vault
      ensure_initialized_and_unsealed
      export_vault_auth
      ensure_elastic_secret
      compose_up
      wait_for_kibana
      sync_fleet_output_ca
      deploy_custom_apm_pipeline
      ;;
    show)
      cd "$COMPOSE_DIR"
      export_vault_auth
      show_secret
      ;;
    env)
      cd "$COMPOSE_DIR"
      export_vault_auth
      show_env
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
