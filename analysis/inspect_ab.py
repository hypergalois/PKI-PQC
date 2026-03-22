#!/usr/bin/env python3
import csv
import json
from pathlib import Path

REPO = Path.home() / "pki-pqc-lab"

FILES = [
    REPO / "analysis" / "outputs" / "campaign_A_summary.csv",
    REPO / "analysis" / "outputs" / "campaign_B_full_summary.csv",
]

def read_csv(path: Path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def main():
    for path in FILES:
        print("=" * 100)
        print(path.name)
        print("=" * 100)
        rows = read_csv(path)
        for r in rows:
            print(
                f"{r['scenario_id']}\n"
                f"  campaign={r['campaign']} runs={r['runs']} success={r['success_rate']}\n"
                f"  elapsed_mean_ms={r['elapsed_mean_ms']} p95={r['elapsed_p95_ms']}\n"
                f"  bytes_read_mean={r['bytes_read_mean']} bytes_written_mean={r['bytes_written_mean']}\n"
                f"  chain_len_unique={r['chain_len_unique']} chain_bytes_unique={r['chain_bytes_unique']}\n"
                f"  served_chain_der_bytes={r['served_chain_der_bytes']}\n"
                f"  root={r['root_alg']}({r['root_der_bytes']}) "
                f"intermediate={r['intermediate_alg']}({r['intermediate_der_bytes']}) "
                f"leaf={r['leaf_alg']}({r['leaf_der_bytes']})\n"
            )

if __name__ == "__main__":
    main()
