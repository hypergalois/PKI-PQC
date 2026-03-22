#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Uso: $0 <listfile>" >&2
  exit 1
fi

LISTFILE="$1"
if [[ ! -f "$LISTFILE" ]]; then
  echo "ERROR: listfile no encontrado: $LISTFILE" >&2
  exit 1
fi

while IFS= read -r scenario; do
  [[ -z "$scenario" ]] && continue
  [[ "$scenario" =~ ^# ]] && continue
  echo "============================================================"
  echo ">>> Running: $scenario"
  ./runner/run_scenario.sh "$scenario"
  echo
done < "$LISTFILE"
