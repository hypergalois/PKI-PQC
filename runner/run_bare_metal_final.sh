#!/usr/bin/env bash
set -euo pipefail

cd ~/tls-pqc-lab

FAST_RUNS=10000
SLOW_RUNS=300

FAST_SCENARIOS=(
  profiles/scenarios/x25519__leaf_mldsa65.json
  profiles/scenarios/x25519mlkem768__leaf_mldsa65.json
  profiles/scenarios/x25519mlkem768__ml_root__ml_leaf.json
  profiles/scenarios/x25519mlkem768__ml_root__ml_int__ml_leaf.json
  profiles/scenarios/x25519mlkem768__slh_root__ml_leaf.json
  profiles/scenarios/x25519mlkem768__slh_root__ml_int__ml_leaf.json
  profiles/scenarios/mlkem768__ml_root__ml_leaf.json
  profiles/scenarios/mlkem768__slh_root__ml_int__ml_leaf.json
)

SLOW_SCENARIOS=(
  profiles/scenarios/x25519__leaf_slhdsashake192s.json
  profiles/scenarios/x25519mlkem768__leaf_slhdsashake192s.json
  profiles/scenarios/x25519mlkem768__ml_root__slh_leaf.json
  profiles/scenarios/x25519mlkem768__ml_root__slh_int__slh_leaf.json
  profiles/scenarios/x25519mlkem768__slh_root__slh_leaf.json
  profiles/scenarios/x25519mlkem768__slh_root__slh_int__slh_leaf.json
  profiles/scenarios/x25519mlkem768__slh_root__ml_int__slh_leaf.json
  profiles/scenarios/x25519mlkem768__ml_root__ml_int__slh_leaf.json
  profiles/scenarios/mlkem768__slh_root__slh_leaf.json
)

echo "============================================================"
echo "PKI generation sanity"
echo "============================================================"
./pki_factory/scripts/gen_chain.sh profiles/chains/ml_root__ml_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__slh_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__ml_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/ml_root__slh_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/ml_root__ml_int__ml_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__ml_int__ml_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__slh_int__slh_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/ml_root__slh_int__slh_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__ml_int__slh_leaf.json
./pki_factory/scripts/gen_chain.sh profiles/chains/ml_root__ml_int__slh_leaf.json

echo "============================================================"
echo "FAST scenarios (N=${FAST_RUNS}) with SERVER PERF"
echo "============================================================"
for s in "${FAST_SCENARIOS[@]}"; do
  RUNS_OVERRIDE=${FAST_RUNS} \
  CAPTURE_PERF_SERVER_OVERRIDE=true \
  ./runner/run_scenario.sh "$s"
done

echo "============================================================"
echo "SLOW scenarios (N=${SLOW_RUNS}) with SERVER PERF"
echo "============================================================"
for s in "${SLOW_SCENARIOS[@]}"; do
  RUNS_OVERRIDE=${SLOW_RUNS} \
  CAPTURE_PERF_SERVER_OVERRIDE=true \
  ./runner/run_scenario.sh "$s"
done

echo "============================================================"
echo "Summaries"
echo "============================================================"
python3 analysis/summarize_list.py profiles/lists/campaign_A.list campaign_A
python3 analysis/summarize_list.py profiles/lists/campaign_B_full.list campaign_B_full
python3 analysis/summarize_list.py profiles/lists/campaign_C.list campaign_C
python3 analysis/summarize_list.py profiles/lists/campaign_D.list campaign_D

echo "============================================================"
echo "Done"
echo "CSV outputs:"
ls -1 analysis/outputs/*_summary.csv