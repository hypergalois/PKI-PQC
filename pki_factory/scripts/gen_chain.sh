#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OPENSSL_BIN="$REPO_ROOT/oqs-provider/.local/bin/openssl"
JQ_BIN="${JQ_BIN:-jq}"

if [[ $# -ne 1 ]]; then
  echo "Uso: $0 <profile.json>" >&2
  exit 1
fi

PROFILE_PATH="$1"
if [[ "$PROFILE_PATH" != /* ]]; then
  PROFILE_PATH="$REPO_ROOT/$PROFILE_PATH"
fi

if [[ ! -f "$PROFILE_PATH" ]]; then
  echo "ERROR: profile no encontrado: $PROFILE_PATH" >&2
  exit 1
fi

if [[ ! -x "$OPENSSL_BIN" ]]; then
  echo "ERROR: openssl OQS no encontrado en: $OPENSSL_BIN" >&2
  exit 1
fi

command -v "$JQ_BIN" >/dev/null 2>&1 || {
  echo "ERROR: jq no está disponible" >&2
  exit 1
}

PROFILE_ID="$("$JQ_BIN" -r '.profile_id' "$PROFILE_PATH")"
DEPTH="$("$JQ_BIN" -r '.depth' "$PROFILE_PATH")"

ROOT_ALG="$("$JQ_BIN" -r '.root.sig_alg' "$PROFILE_PATH")"
ROOT_CN="$("$JQ_BIN" -r '.root.subject_cn' "$PROFILE_PATH")"

INT_ALG="$("$JQ_BIN" -r '.intermediate.key_alg // empty' "$PROFILE_PATH")"
INT_CN="$("$JQ_BIN" -r '.intermediate.subject_cn // empty' "$PROFILE_PATH")"

LEAF_ALG="$("$JQ_BIN" -r '.leaf.key_alg' "$PROFILE_PATH")"
LEAF_CN="$("$JQ_BIN" -r '.leaf.subject_cn' "$PROFILE_PATH")"
LEAF_SAN="$("$JQ_BIN" -r '.leaf.san_dns' "$PROFILE_PATH")"

OUT_DIR="$REPO_ROOT/pki_factory/output/$PROFILE_ID"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/certs" "$OUT_DIR/csr" "$OUT_DIR/tmp"

der_size() {
  local cert="$1"
  "$OPENSSL_BIN" x509 -in "$cert" -outform DER | wc -c | awk '{print $1}'
}

write_int_ext() {
  cat > "$OUT_DIR/tmp/int_ext.cnf" <<'EOT'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOT
}

write_leaf_ext() {
  cat > "$OUT_DIR/tmp/leaf_ext.cnf" <<EOT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:${LEAF_SAN}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOT
}

echo ">>> Generando profile: $PROFILE_ID"
echo ">>> Salida: $OUT_DIR"

write_leaf_ext
if [[ "$DEPTH" == "3" ]]; then
  write_int_ext
fi

# Root autofirmada: aquí usamos -addext, no -extfile
"$OPENSSL_BIN" req -new -x509 \
  -provider default -provider oqsprovider \
  -newkey "$ROOT_ALG" \
  -keyout "$OUT_DIR/certs/root.key" \
  -out "$OUT_DIR/certs/root.crt" \
  -nodes \
  -subj "/CN=${ROOT_CN}" \
  -days 3650 \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

# Intermediate (solo depth 3)
if [[ "$DEPTH" == "3" ]]; then
  "$OPENSSL_BIN" req -new \
    -provider default -provider oqsprovider \
    -newkey "$INT_ALG" \
    -keyout "$OUT_DIR/certs/intermediate.key" \
    -out "$OUT_DIR/csr/intermediate.csr" \
    -nodes \
    -subj "/CN=${INT_CN}"

  "$OPENSSL_BIN" x509 -req \
    -provider default -provider oqsprovider \
    -in "$OUT_DIR/csr/intermediate.csr" \
    -CA "$OUT_DIR/certs/root.crt" \
    -CAkey "$OUT_DIR/certs/root.key" \
    -CAcreateserial \
    -CAserial "$OUT_DIR/certs/root.srl" \
    -out "$OUT_DIR/certs/intermediate.crt" \
    -days 2000 \
    -extfile "$OUT_DIR/tmp/int_ext.cnf"
fi

# Leaf
"$OPENSSL_BIN" req -new \
  -provider default -provider oqsprovider \
  -newkey "$LEAF_ALG" \
  -keyout "$OUT_DIR/certs/server.key" \
  -out "$OUT_DIR/csr/server.csr" \
  -nodes \
  -subj "/CN=${LEAF_CN}" \
  -addext "subjectAltName=DNS:${LEAF_SAN}"

if [[ "$DEPTH" == "3" ]]; then
  "$OPENSSL_BIN" x509 -req \
    -provider default -provider oqsprovider \
    -in "$OUT_DIR/csr/server.csr" \
    -CA "$OUT_DIR/certs/intermediate.crt" \
    -CAkey "$OUT_DIR/certs/intermediate.key" \
    -CAcreateserial \
    -CAserial "$OUT_DIR/certs/intermediate.srl" \
    -out "$OUT_DIR/certs/server.crt" \
    -days 825 \
    -extfile "$OUT_DIR/tmp/leaf_ext.cnf"

  cat "$OUT_DIR/certs/intermediate.crt" > "$OUT_DIR/certs/served_chain.pem"

  if ! VERIFY_OUTPUT="$("$OPENSSL_BIN" verify \
      -provider default -provider oqsprovider \
      -CAfile "$OUT_DIR/certs/root.crt" \
      -untrusted "$OUT_DIR/certs/served_chain.pem" \
      "$OUT_DIR/certs/server.crt" 2>&1)"; then
    printf '%s\n' "$VERIFY_OUTPUT" > "$OUT_DIR/verify.txt"
    echo "ERROR: verify falló para $PROFILE_ID" >&2
    exit 1
  fi
else
  "$OPENSSL_BIN" x509 -req \
    -provider default -provider oqsprovider \
    -in "$OUT_DIR/csr/server.csr" \
    -CA "$OUT_DIR/certs/root.crt" \
    -CAkey "$OUT_DIR/certs/root.key" \
    -CAcreateserial \
    -CAserial "$OUT_DIR/certs/root.srl" \
    -out "$OUT_DIR/certs/server.crt" \
    -days 825 \
    -extfile "$OUT_DIR/tmp/leaf_ext.cnf"

  : > "$OUT_DIR/certs/served_chain.pem"

  if ! VERIFY_OUTPUT="$("$OPENSSL_BIN" verify \
      -provider default -provider oqsprovider \
      -CAfile "$OUT_DIR/certs/root.crt" \
      "$OUT_DIR/certs/server.crt" 2>&1)"; then
    printf '%s\n' "$VERIFY_OUTPUT" > "$OUT_DIR/verify.txt"
    echo "ERROR: verify falló para $PROFILE_ID" >&2
    exit 1
  fi
fi

printf '%s\n' "$VERIFY_OUTPUT" > "$OUT_DIR/verify.txt"

ROOT_DER="$(der_size "$OUT_DIR/certs/root.crt")"
LEAF_DER="$(der_size "$OUT_DIR/certs/server.crt")"

if [[ "$DEPTH" == "3" ]]; then
  INT_DER="$(der_size "$OUT_DIR/certs/intermediate.crt")"
  SERVED_CHAIN_LEN=2
  SERVED_CHAIN_DER_BYTES=$((LEAF_DER + INT_DER))
else
  INT_DER=0
  SERVED_CHAIN_LEN=1
  SERVED_CHAIN_DER_BYTES="$LEAF_DER"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
OPENSSL_VERSION="$("$OPENSSL_BIN" version | tr -d '\n')"

"$JQ_BIN" -n \
  --arg profile_id "$PROFILE_ID" \
  --argjson depth "$DEPTH" \
  --arg root_alg "$ROOT_ALG" \
  --arg root_cn "$ROOT_CN" \
  --arg int_alg "$INT_ALG" \
  --arg int_cn "$INT_CN" \
  --arg leaf_alg "$LEAF_ALG" \
  --arg leaf_cn "$LEAF_CN" \
  --arg leaf_san "$LEAF_SAN" \
  --argjson root_der "$ROOT_DER" \
  --argjson int_der "$INT_DER" \
  --argjson leaf_der "$LEAF_DER" \
  --argjson served_chain_len "$SERVED_CHAIN_LEN" \
  --argjson served_chain_der_bytes "$SERVED_CHAIN_DER_BYTES" \
  --arg verify_output "$VERIFY_OUTPUT" \
  '{
    profile_id: $profile_id,
    depth: $depth,
    root: {
      algorithm: $root_alg,
      subject_cn: $root_cn,
      der_bytes: $root_der
    },
    intermediate: (
      if $int_alg == "" then null else
      {
        algorithm: $int_alg,
        subject_cn: $int_cn,
        der_bytes: $int_der
      }
      end
    ),
    leaf: {
      algorithm: $leaf_alg,
      subject_cn: $leaf_cn,
      san_dns: $leaf_san,
      der_bytes: $leaf_der
    },
    served_chain: {
      len: $served_chain_len,
      der_bytes: $served_chain_der_bytes
    },
    verify_output: $verify_output
  }' > "$OUT_DIR/chain.json"

"$JQ_BIN" -n \
  --arg profile_id "$PROFILE_ID" \
  --arg source_profile "$PROFILE_PATH" \
  --arg generated_at "$GENERATED_AT" \
  --arg openssl_version "$OPENSSL_VERSION" \
  --arg output_dir "$OUT_DIR" \
  '{
    profile_id: $profile_id,
    source_profile: $source_profile,
    generated_at_utc: $generated_at,
    openssl_version: $openssl_version,
    output_dir: $output_dir
  }' > "$OUT_DIR/meta.json"

echo ">>> OK: $PROFILE_ID"
echo ">>> chain.json: $OUT_DIR/chain.json"
echo ">>> meta.json : $OUT_DIR/meta.json"
