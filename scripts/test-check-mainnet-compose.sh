#!/usr/bin/env bash
# Self-check for check-mainnet-compose.sh: each way the mainnet treasury's compose file could be made
# to collide with, or drift from, the stage stack, by exit code and by the line printed. CI runs it
# (test-treasury-scripts.yml) with no docker and no .env: the guard reads two JSON files, and the
# fixtures below are tiny renderings of `docker compose config --format json`.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

passed=0
failed=0

# The stage stack: the three app services on the stage network, the two databases on a private one.
cat > "$T/stage.json" <<'JSON'
{
  "networks": {
    "clutch-network": {"name": "clutch-stage_clutch-network"},
    "treasury-network": {"name": "clutch-stage_treasury-network", "internal": true}
  },
  "services": {
    "treasury-postgres": {"networks": {"treasury-network": null}, "environment": {"POSTGRES_DB": "treasury"}},
    "orchestrator-postgres": {"networks": {"treasury-network": null}, "environment": {"POSTGRES_DB": "orchestrator"}},
    "treasury-service": {
      "image": "ghcr.io/clutchprotocol/clutch-treasury:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "environment": {"APP_CHAIN_ID": "2077", "APP_SIGNER_URL": "http://tron-signer:8093", "APP_PER_TX_MINT_CAP_CLT": "50000000"}
    },
    "tron-signer": {
      "image": "ghcr.io/clutchprotocol/clutch-tron-signer:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "environment": {"APP_PER_TX_PAYOUT_CAP_USDT": "25000000"}
    },
    "payment-orchestrator": {
      "image": "ghcr.io/clutchprotocol/clutch-orchestrator:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "ports": [{"published": "8091", "target": 8091}],
      "environment": {"APP_TREASURY_URL": "http://treasury-service:8090", "APP_MAX_REDEMPTION_CLT": "25000000"}
    }
  }
}
JSON

# The mainnet stack as it should render: its own names, a private network, no ports, a superset of
# the stage settings plus the KMS ones.
cat > "$T/mainnet.json" <<'JSON'
{
  "name": "clutch-main-treasury",
  "networks": {
    "clutch-network": {"name": "clutch-mainnet", "external": true},
    "treasury-network": {"name": "clutch-main-treasury_treasury-network", "internal": true}
  },
  "services": {
    "treasury-postgres": {"networks": {"treasury-network": null}, "environment": {"POSTGRES_DB": "treasury"}},
    "orchestrator-postgres": {"networks": {"treasury-network": null}, "environment": {"POSTGRES_DB": "orchestrator"}},
    "mainnet-treasury-service": {
      "image": "ghcr.io/clutchprotocol/clutch-treasury:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "environment": {
        "APP_CHAIN_ID": "1000", "APP_SIGNER_URL": "http://mainnet-tron-signer:8093",
        "APP_PER_TX_MINT_CAP_CLT": "1000000000", "APP_SIGNER_KIND": "azure_kms", "APP_MINT_AUTHORITY_SECRET": "",
        "APP_NODE_WS_URL": "ws://mainnet-node3:8183/ws",
        "APP_USDT_CONTRACT": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "APP_TRONGRID_URL": "https://api.trongrid.io"
      }
    },
    "mainnet-tron-signer": {
      "image": "ghcr.io/clutchprotocol/clutch-tron-signer:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "environment": {
        "APP_PER_TX_PAYOUT_CAP_USDT": "200000000",
        "APP_USDT_CONTRACT": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "APP_TRONGRID_URL": "https://api.trongrid.io"
      }
    },
    "mainnet-payment-orchestrator": {
      "image": "ghcr.io/clutchprotocol/clutch-orchestrator:sha-df5243a",
      "networks": {"treasury-network": null, "clutch-network": null},
      "environment": {
        "APP_TREASURY_URL": "http://mainnet-treasury-service:8090", "APP_MAX_REDEMPTION_CLT": "200000000",
        "APP_USDT_CONTRACT": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "APP_TRONGRID_URL": "https://api.trongrid.io"
      }
    }
  }
}
JSON

# check <name> <expected exit code> <text the output must contain> <jq filter that mutates the mainnet fixture>
check() {
  local name="$1" want="$2" text="$3" filter="$4" out code=0
  jq "$filter" "$T/mainnet.json" > "$T/m.json"
  out=$(bash scripts/check-mainnet-compose.sh "$T/stage.json" "$T/m.json" 2>&1) || code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code (wanted $want), wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

check "a clean pair passes" 0 "no service name is shared with the stage stack" '.'
check "the databases may share a name: they sit on a private network" 0 "OK    no service name is shared" '.'
check "an app service with a stage name fails" 1 "service names shared with the stage stack: treasury-service" \
  '.services["treasury-service"] = .services["mainnet-treasury-service"] | del(.services["mainnet-treasury-service"])'
check "a database on a shared network under a stage name fails" 1 "service names shared with the stage stack: treasury-postgres" \
  '.services["treasury-postgres"].networks = {"clutch-network": null}'
check "a published port fails" 1 "services that publish a port: mainnet-payment-orchestrator" \
  '.services["mainnet-payment-orchestrator"].ports = [{"published": "8091", "target": 8091}]'
check "a stage network fails" 1 "services on a stage network: mainnet-payment-orchestrator" \
  '.networks["clutch-stage"] = {"name": "clutch-stage_clutch-network", "external": true} | .services["mainnet-payment-orchestrator"].networks["clutch-stage"] = null'
check "a stage setting missing from the mainnet service fails" 1 "mainnet-tron-signer lacks the stage settings: APP_PER_TX_PAYOUT_CAP_USDT" \
  'del(.services["mainnet-tron-signer"].environment.APP_PER_TX_PAYOUT_CAP_USDT)'
check "a stage host in a mainnet URL fails" 1 "mainnet settings that name a stage host: mainnet-payment-orchestrator.APP_TREASURY_URL" \
  '.services["mainnet-payment-orchestrator"].environment.APP_TREASURY_URL = "http://treasury-service:8090"'
check "an image on latest fails" 1 "not pinned to a sha tag: mainnet-treasury-service" \
  '.services["mainnet-treasury-service"].image = "ghcr.io/clutchprotocol/clutch-treasury:latest"'
check "the wrong chain id fails" 1 "mainnet-treasury-service must run chain 1000" \
  '.services["mainnet-treasury-service"].environment.APP_CHAIN_ID = "2077"'
check "a plaintext mint key beside the KMS signer fails" 1 "mainnet-treasury-service must have an empty APP_MINT_AUTHORITY_SECRET" \
  '.services["mainnet-treasury-service"].environment.APP_MINT_AUTHORITY_SECRET = "abcd"'
check "the env signer instead of KMS fails" 1 "mainnet-treasury-service must sign with azure_kms" \
  '.services["mainnet-treasury-service"].environment.APP_SIGNER_KIND = "env"'
check "the testnet node URL fails" 1 "mainnet-treasury-service must read a mainnet node" \
  '.services["mainnet-treasury-service"].environment.APP_NODE_WS_URL = "ws://node3:8083/ws"'
check "the Nile TronGrid fails" 1 "mainnet-tron-signer must use TronGrid mainnet" \
  '.services["mainnet-tron-signer"].environment.APP_TRONGRID_URL = "https://nile.trongrid.io"'
check "the Nile USDT contract fails" 1 "mainnet-payment-orchestrator must watch the mainnet USDT contract" \
  '.services["mainnet-payment-orchestrator"].environment.APP_USDT_CONTRACT = "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
