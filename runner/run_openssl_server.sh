#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OPENSSL_BIN="$REPO_ROOT/oqs-provider/.local/bin/openssl"
OQS_PREFIX="$REPO_ROOT/oqs-provider/.local"
OQS_MODULES="$OQS_PREFIX/lib64/ossl-modules"

export PATH="$OQS_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$OQS_PREFIX/lib64:$OQS_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export OPENSSL_MODULES="$OQS_MODULES"

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Uso: $0 <profile_id> <tls_group> [port]" >&2
  exit 1
fi

PROFILE_ID="$1"
TLS_GROUP="$2"
PORT="${3:-4433}"

PROFILE_DIR="$REPO_ROOT/pki_factory/output/$PROFILE_ID"
CERT="$PROFILE_DIR/certs/server.crt"
KEY="$PROFILE_DIR/certs/server.key"
ROOT_CA="$PROFILE_DIR/certs/root.crt"
CHAIN="$PROFILE_DIR/certs/served_chain.pem"

if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "ERROR: profile generado no encontrado: $PROFILE_DIR" >&2
  exit 1
fi

ARGS=(
  "$OPENSSL_BIN" s_server
  -provider-path "$OQS_MODULES"
  -provider default
  -provider oqsprovider
  -accept "$PORT"
  -cert "$CERT"
  -key "$KEY"
  -CAfile "$ROOT_CA"
  -verify 1
  -tls1_3
  -groups "$TLS_GROUP"
  -quiet
)

if [[ -s "$CHAIN" ]]; then
  ARGS+=(-cert_chain "$CHAIN")
fi

exec "${ARGS[@]}"
