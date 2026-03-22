#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OQS_PREFIX="$REPO_ROOT/oqs-provider/.local"
OQS_MODULES="$OQS_PREFIX/lib64/ossl-modules"
OQS_LD_LIBRARY_PATH="$OQS_PREFIX/lib64:$OQS_PREFIX/lib:${LD_LIBRARY_PATH:-}"

JQ_BIN="${JQ_BIN:-jq}"
PERF_BIN="${PERF_BIN:-perf}"
TCPDUMP_BIN="${TCPDUMP_BIN:-tcpdump}"

CPU_EVENTS="task-clock,cycles,instructions,branches,branch-misses,cache-references,cache-misses"

if [[ $# -ne 1 ]]; then
  echo "Uso: $0 <scenario.json>" >&2
  exit 1
fi

SCENARIO_PATH="$1"
if [[ "$SCENARIO_PATH" != /* ]]; then
  SCENARIO_PATH="$REPO_ROOT/$SCENARIO_PATH"
fi

if [[ ! -f "$SCENARIO_PATH" ]]; then
  echo "ERROR: scenario no encontrado: $SCENARIO_PATH" >&2
  exit 1
fi

command -v "$JQ_BIN" >/dev/null 2>&1 || {
  echo "ERROR: jq no disponible" >&2
  exit 1
}

command -v "$PERF_BIN" >/dev/null 2>&1 || {
  echo "ERROR: perf no disponible" >&2
  exit 1
}

SCENARIO_ID="$("$JQ_BIN" -r '.scenario_id' "$SCENARIO_PATH")"
CAMPAIGN="$("$JQ_BIN" -r '.campaign' "$SCENARIO_PATH")"
TLS_GROUP="$("$JQ_BIN" -r '.tls_group' "$SCENARIO_PATH")"
CHAIN_PROFILE="$("$JQ_BIN" -r '.chain_profile' "$SCENARIO_PATH")"
HOST="$("$JQ_BIN" -r '.host' "$SCENARIO_PATH")"
PORT="$("$JQ_BIN" -r '.port' "$SCENARIO_PATH")"
SERVER_NAME="$("$JQ_BIN" -r '.server_name' "$SCENARIO_PATH")"
RUNS_JSON="$("$JQ_BIN" -r '.runs' "$SCENARIO_PATH")"

CAPTURE_PERF_CLIENT_JSON="$("$JQ_BIN" -r '.capture_perf_client' "$SCENARIO_PATH")"
CAPTURE_PERF_SERVER_JSON="$("$JQ_BIN" -r '.capture_perf_server' "$SCENARIO_PATH")"
CAPTURE_PCAP_JSON="$("$JQ_BIN" -r '.capture_pcap' "$SCENARIO_PATH")"

RUNS_EFFECTIVE="${RUNS_OVERRIDE:-$RUNS_JSON}"
CAPTURE_PERF_CLIENT="${CAPTURE_PERF_CLIENT_OVERRIDE:-$CAPTURE_PERF_CLIENT_JSON}"
CAPTURE_PERF_SERVER="${CAPTURE_PERF_SERVER_OVERRIDE:-$CAPTURE_PERF_SERVER_JSON}"
CAPTURE_PCAP="${CAPTURE_PCAP_OVERRIDE:-$CAPTURE_PCAP_JSON}"

PROFILE_JSON="$REPO_ROOT/profiles/chains/${CHAIN_PROFILE}.json"
PROFILE_OUT_DIR="$REPO_ROOT/pki_factory/output/${CHAIN_PROFILE}"

if [[ ! -f "$PROFILE_JSON" ]]; then
  echo "ERROR: chain profile no encontrado: $PROFILE_JSON" >&2
  exit 1
fi

if [[ ! -f "$PROFILE_OUT_DIR/chain.json" ]]; then
  echo ">>> Chain profile no generado aún; generando: $CHAIN_PROFILE"
  "$REPO_ROOT/pki_factory/scripts/gen_chain.sh" "$PROFILE_JSON"
fi

STAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
RESULT_DIR="$REPO_ROOT/results/campaign_${CAMPAIGN}/${SCENARIO_ID}/${STAMP}"
mkdir -p "$RESULT_DIR"

BENCH_CSV="$RESULT_DIR/bench_${SCENARIO_ID}.csv"
PERF_CLIENT_CSV="$RESULT_DIR/perf_client_${SCENARIO_ID}.csv"
PERF_SERVER_CSV="$RESULT_DIR/perf_server_${SCENARIO_ID}.csv"
SERVER_LOG="$RESULT_DIR/server_${SCENARIO_ID}.log"
PCAP_FILE="$RESULT_DIR/pcap_${SCENARIO_ID}.pcap"
META_JSON="$RESULT_DIR/meta_${SCENARIO_ID}.json"

SERVER_PID=""
TCPDUMP_PID=""
PERF_SERVER_PID=""
NEED_SUDO="false"
STATUS="started"
CLIENT_EXIT_CODE=""

if [[ "$CAPTURE_PCAP" == "true" || "$CAPTURE_PERF_CLIENT" == "true" || "$CAPTURE_PERF_SERVER" == "true" ]]; then
  NEED_SUDO="true"
fi

cleanup() {
  if [[ -n "${TCPDUMP_PID}" ]]; then
    sudo -n kill -INT "${TCPDUMP_PID}" 2>/dev/null || kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
    wait "${TCPDUMP_PID}" 2>/dev/null || true
  fi

  if [[ -n "${PERF_SERVER_PID}" ]]; then
    sudo -n kill -INT "${PERF_SERVER_PID}" 2>/dev/null || kill -INT "${PERF_SERVER_PID}" 2>/dev/null || true
    wait "${PERF_SERVER_PID}" 2>/dev/null || true
  fi

  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi

  if [[ "$NEED_SUDO" == "true" ]]; then
    sudo -n chown "$USER:$USER" \
      "$BENCH_CSV" \
      "$PERF_CLIENT_CSV" \
      "$PERF_SERVER_CSV" \
      "$SERVER_LOG" \
      "$PCAP_FILE" \
      "$META_JSON" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo ">>> Scenario: $SCENARIO_ID"
echo ">>> Result dir: $RESULT_DIR"
echo ">>> Runs: $RUNS_EFFECTIVE"
echo ">>> capture_perf_client: $CAPTURE_PERF_CLIENT"
echo ">>> capture_perf_server: $CAPTURE_PERF_SERVER"
echo ">>> capture_pcap: $CAPTURE_PCAP"

if [[ "$NEED_SUDO" == "true" && "$EUID" -ne 0 ]]; then
  echo ">>> Solicitaré privilegios para tcpdump/perf..."
  sudo -v
fi

"$REPO_ROOT/runner/run_openssl_server.sh" "$CHAIN_PROFILE" "$TLS_GROUP" "$PORT" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

sleep 1

if [[ "$CAPTURE_PCAP" == "true" ]]; then
  if ! command -v "$TCPDUMP_BIN" >/dev/null 2>&1; then
    echo "ERROR: capture_pcap=true pero tcpdump no está disponible" >&2
    exit 1
  fi

  if [[ "$EUID" -eq 0 ]]; then
    "$TCPDUMP_BIN" -i lo -U -w "$PCAP_FILE" "tcp port $PORT" >/dev/null 2>&1 &
    TCPDUMP_PID=$!
  else
    sudo -n "$TCPDUMP_BIN" -i lo -U -w "$PCAP_FILE" "tcp port $PORT" >/dev/null 2>&1 &
    TCPDUMP_PID=$!
  fi

  sleep 1
fi

if [[ "$CAPTURE_PERF_SERVER" == "true" ]]; then
  "$PERF_BIN" stat -x, \
    -e "$CPU_EVENTS" \
    -p "$SERVER_PID" \
    -o "$PERF_SERVER_CSV" >/dev/null 2>&1 &
  PERF_SERVER_PID=$!
  sleep 0.2
fi

CLIENT_CMD=(
  "$REPO_ROOT/bench/tls_bench_client"
  "$HOST"
  "$PORT"
  "$TLS_GROUP"
  "$PROFILE_OUT_DIR/certs/root.crt"
  "$SERVER_NAME"
  "$RUNS_EFFECTIVE"
)

set +e
if [[ "$CAPTURE_PERF_CLIENT" == "true" ]]; then
  env \
    LD_LIBRARY_PATH="$OQS_LD_LIBRARY_PATH" \
    OPENSSL_MODULES="$OQS_MODULES" \
    "$PERF_BIN" stat -x, \
      -e "$CPU_EVENTS" \
      -o "$PERF_CLIENT_CSV" \
      "${CLIENT_CMD[@]}" > "$BENCH_CSV"
  CLIENT_EXIT_CODE=$?
else
  env \
    LD_LIBRARY_PATH="$OQS_LD_LIBRARY_PATH" \
    OPENSSL_MODULES="$OQS_MODULES" \
    "${CLIENT_CMD[@]}" > "$BENCH_CSV"
  CLIENT_EXIT_CODE=$?
fi
set -e

if [[ -n "${TCPDUMP_PID}" ]]; then
  sudo -n kill -INT "${TCPDUMP_PID}" 2>/dev/null || kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
  wait "${TCPDUMP_PID}" 2>/dev/null || true
  TCPDUMP_PID=""
fi

if [[ -n "${SERVER_PID}" ]]; then
  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""
fi

if [[ -n "${PERF_SERVER_PID}" ]]; then
  wait "${PERF_SERVER_PID}" 2>/dev/null || true
  PERF_SERVER_PID=""
fi

if [[ "$CLIENT_EXIT_CODE" == "0" ]]; then
  STATUS="completed"
elif [[ "$CLIENT_EXIT_CODE" == "130" ]]; then
  STATUS="interrupted"
else
  STATUS="failed"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
"$JQ_BIN" -n \
  --arg scenario_id "$SCENARIO_ID" \
  --arg campaign "$CAMPAIGN" \
  --arg generated_at "$GENERATED_AT" \
  --arg result_dir "$RESULT_DIR" \
  --arg bench_csv "$BENCH_CSV" \
  --arg perf_client_csv "$PERF_CLIENT_CSV" \
  --arg perf_server_csv "$PERF_SERVER_CSV" \
  --arg server_log "$SERVER_LOG" \
  --arg pcap_file "$PCAP_FILE" \
  --arg scenario_path "$SCENARIO_PATH" \
  --arg chain_profile "$CHAIN_PROFILE" \
  --arg status "$STATUS" \
  --argjson runs_requested "$RUNS_JSON" \
  --argjson runs_effective "$RUNS_EFFECTIVE" \
  --argjson client_exit_code "$CLIENT_EXIT_CODE" \
  --arg capture_perf_client "$CAPTURE_PERF_CLIENT" \
  --arg capture_perf_server "$CAPTURE_PERF_SERVER" \
  --arg capture_pcap "$CAPTURE_PCAP" \
  --slurpfile scenario_doc "$SCENARIO_PATH" \
  --slurpfile chain_doc "$PROFILE_OUT_DIR/chain.json" \
  '{
    scenario_id: $scenario_id,
    campaign: $campaign,
    executed_at_utc: $generated_at,
    result_dir: $result_dir,
    chain_profile: $chain_profile,
    status: $status,
    runs_requested: $runs_requested,
    runs_effective: $runs_effective,
    client_exit_code: $client_exit_code,
    capture_perf_client_effective: $capture_perf_client,
    capture_perf_server_effective: $capture_perf_server,
    capture_pcap_effective: $capture_pcap,
    scenario: $scenario_doc[0],
    chain: $chain_doc[0],
    outputs: {
      bench_csv: $bench_csv,
      perf_client_csv: $perf_client_csv,
      perf_server_csv: $perf_server_csv,
      server_log: $server_log,
      pcap_file: $pcap_file
    }
  }' > "$META_JSON"

if [[ "$NEED_SUDO" == "true" ]]; then
  sudo -n chown "$USER:$USER" \
    "$BENCH_CSV" \
    "$PERF_CLIENT_CSV" \
    "$PERF_SERVER_CSV" \
    "$SERVER_LOG" \
    "$PCAP_FILE" \
    "$META_JSON" 2>/dev/null || true
fi

if [[ "$STATUS" == "completed" ]]; then
  echo ">>> OK: $SCENARIO_ID"
  echo ">>> bench: $BENCH_CSV"
  echo ">>> perf_client: $PERF_CLIENT_CSV"
  echo ">>> perf_server: $PERF_SERVER_CSV"
  echo ">>> pcap: $PCAP_FILE"
  echo ">>> meta: $META_JSON"
else
  echo ">>> ERROR: scenario terminó con estado '$STATUS' (exit code $CLIENT_EXIT_CODE)" >&2
  echo ">>> bench parcial: $BENCH_CSV" >&2
  echo ">>> pcap parcial: $PCAP_FILE" >&2
  echo ">>> meta: $META_JSON" >&2
  exit 1
fi
