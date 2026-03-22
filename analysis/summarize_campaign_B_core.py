#!/usr/bin/env python3
import csv
import json
import math
from pathlib import Path
from statistics import mean, median, StatisticsError

REPO = Path.home() / "pki-pqc-lab"

SCENARIOS = [
    "x25519mlkem768__ml_root__ml_int__ml_leaf",
    "x25519mlkem768__slh_root__ml_int__ml_leaf",
    "x25519mlkem768__slh_root__slh_int__slh_leaf",
]

def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    d0 = sorted_vals[f] * (c - k)
    d1 = sorted_vals[c] * (k - f)
    return d0 + d1

def read_bench_csv(path: Path):
    rows = []
    if not path.exists():
        return rows
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "run_id": int(row["run_id"]),
                "elapsed_ms": float(row["elapsed_ms"]),
                "success": int(row["success"]),
                "ssl_error": int(row["ssl_error"]),
                "bytes_read": int(row["bytes_read"]),
                "bytes_written": int(row["bytes_written"]),
                "chain_len": int(row["chain_len"]),
                "chain_bytes": int(row["chain_bytes"]),
            })
    return rows

def parse_perf_task_clock(path: Path):
    if not path.exists():
        return None
    with path.open() as f:
        for line in f:
            if "task-clock" not in line:
                continue
            parts = line.strip().split(",")
            if len(parts) >= 3 and parts[2] == "task-clock":
                raw = parts[0].strip()
                try:
                    return float(raw)
                except ValueError:
                    return raw
    return None

def is_valid_run_dir(run_dir: Path, scenario_id: str):
    meta_path = run_dir / f"meta_{scenario_id}.json"
    bench_path = run_dir / f"bench_{scenario_id}.csv"

    if not meta_path.exists() or not bench_path.exists():
        return False

    try:
        with meta_path.open() as f:
            meta = json.load(f)
    except Exception:
        return False

    status = meta.get("status", "completed")
    if status != "completed":
        return False

    bench = read_bench_csv(bench_path)
    return len(bench) > 0

def latest_valid_run_dir(scenario_id: str) -> Path:
    base = REPO / "results" / "campaign_B" / scenario_id
    if not base.exists():
        raise FileNotFoundError(f"No directory for {scenario_id}")

    runs = sorted([p for p in base.iterdir() if p.is_dir()], reverse=True)
    for run_dir in runs:
        if is_valid_run_dir(run_dir, scenario_id):
            return run_dir

    raise FileNotFoundError(f"No valid completed runs found for {scenario_id}")

def scenario_summary(scenario_id: str):
    run_dir = latest_valid_run_dir(scenario_id)
    bench_path = run_dir / f"bench_{scenario_id}.csv"
    meta_path = run_dir / f"meta_{scenario_id}.json"
    perf_path = run_dir / f"perf_client_{scenario_id}.csv"

    bench = read_bench_csv(bench_path)
    with meta_path.open() as f:
        meta = json.load(f)

    if not bench:
        raise StatisticsError(f"No bench rows for {scenario_id}")

    elapsed = sorted(r["elapsed_ms"] for r in bench)
    success = [r["success"] for r in bench]
    bytes_read_vals = [r["bytes_read"] for r in bench]
    bytes_written_vals = [r["bytes_written"] for r in bench]
    chain_len_vals = [r["chain_len"] for r in bench]
    chain_bytes_vals = [r["chain_bytes"] for r in bench]

    task_clock = parse_perf_task_clock(perf_path)

    return {
        "scenario_id": scenario_id,
        "run_dir": str(run_dir),
        "runs": len(bench),
        "success_rate": mean(success),
        "elapsed_mean_ms": mean(elapsed),
        "elapsed_median_ms": median(elapsed),
        "elapsed_p95_ms": percentile(elapsed, 0.95),
        "elapsed_p99_ms": percentile(elapsed, 0.99),
        "elapsed_min_ms": min(elapsed),
        "elapsed_max_ms": max(elapsed),
        "bytes_read_mean": mean(bytes_read_vals),
        "bytes_written_mean": mean(bytes_written_vals),
        "chain_len_unique": sorted(set(chain_len_vals)),
        "chain_bytes_unique": sorted(set(chain_bytes_vals)),
        "served_chain_der_bytes": meta["chain"]["served_chain"]["der_bytes"],
        "root_alg": meta["chain"]["root"]["algorithm"],
        "intermediate_alg": meta["chain"]["intermediate"]["algorithm"],
        "leaf_alg": meta["chain"]["leaf"]["algorithm"],
        "perf_task_clock_raw": task_clock,
        "pcap_file": meta["outputs"]["pcap_file"],
    }

def main():
    summaries = [scenario_summary(s) for s in SCENARIOS]

    out_dir = REPO / "analysis" / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)

    json_out = out_dir / "campaign_B_core_summary.json"
    csv_out = out_dir / "campaign_B_core_summary.csv"

    with json_out.open("w") as f:
        json.dump(summaries, f, indent=2)

    fieldnames = [
        "scenario_id",
        "runs",
        "success_rate",
        "elapsed_mean_ms",
        "elapsed_median_ms",
        "elapsed_p95_ms",
        "elapsed_p99_ms",
        "elapsed_min_ms",
        "elapsed_max_ms",
        "bytes_read_mean",
        "bytes_written_mean",
        "chain_len_unique",
        "chain_bytes_unique",
        "served_chain_der_bytes",
        "root_alg",
        "intermediate_alg",
        "leaf_alg",
        "perf_task_clock_raw",
        "run_dir",
        "pcap_file",
    ]

    with csv_out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in summaries:
            row = row.copy()
            row["chain_len_unique"] = ";".join(map(str, row["chain_len_unique"]))
            row["chain_bytes_unique"] = ";".join(map(str, row["chain_bytes_unique"]))
            writer.writerow(row)

    print(f"OK: {json_out}")
    print(f"OK: {csv_out}")

if __name__ == "__main__":
    main()
