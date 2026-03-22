#!/usr/bin/env python3
import csv
import json
import math
import sys
from pathlib import Path
from statistics import mean, median, StatisticsError

REPO = Path.home() / "pki-pqc-lab"


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


def parse_number(raw: str):
    raw = raw.strip()
    if raw == "" or raw == "<not supported>":
        return None
    try:
        if any(ch in raw for ch in [".", "e", "E"]):
            return float(raw)
        return int(raw)
    except ValueError:
        return raw


def safe_div(a, b):
    if a is None or b is None or b == 0:
        return None
    return a / b


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


def parse_perf_csv(path: Path):
    perf = {
        "task-clock": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "cycles": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "instructions": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "branches": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "branch-misses": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "cache-references": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
        "cache-misses": {"value": None, "unit": None, "runtime": None, "pct": None, "metric": None, "metric_unit": None},
    }

    if not path.exists():
        return perf

    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue

            parts = line.split(",")
            if len(parts) < 3:
                continue

            event = parts[2].strip()
            if event not in perf:
                continue

            raw_value = parts[0].strip() if len(parts) > 0 else ""
            raw_unit = parts[1].strip() if len(parts) > 1 else ""
            raw_runtime = parts[3].strip() if len(parts) > 3 else ""
            raw_pct = parts[4].strip() if len(parts) > 4 else ""
            raw_metric = parts[5].strip() if len(parts) > 5 else ""
            raw_metric_unit = parts[6].strip() if len(parts) > 6 else ""

            perf[event] = {
                "value": parse_number(raw_value),
                "unit": raw_unit if raw_unit else None,
                "runtime": parse_number(raw_runtime),
                "pct": parse_number(raw_pct),
                "metric": parse_number(raw_metric),
                "metric_unit": raw_metric_unit if raw_metric_unit else None,
            }

    return perf


def scenario_id_from_list_entry(entry: str) -> str:
    return Path(entry).stem


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


def latest_valid_run_dir(scenario_id: str, campaign_hint: str | None = None) -> Path:
    candidates = []

    if campaign_hint:
        hinted = REPO / "results" / f"campaign_{campaign_hint}" / scenario_id
        if hinted.exists():
            candidates.extend([p for p in hinted.iterdir() if p.is_dir()])

    if not candidates:
        for base in sorted((REPO / "results").glob(f"campaign_*/{scenario_id}")):
            if base.exists():
                candidates.extend([p for p in base.iterdir() if p.is_dir()])

    candidates = sorted(candidates, reverse=True)

    for run_dir in candidates:
        if is_valid_run_dir(run_dir, scenario_id):
            return run_dir

    raise FileNotFoundError(f"No valid completed runs found for {scenario_id}")


def scenario_summary(scenario_id: str, campaign_hint: str | None = None):
    run_dir = latest_valid_run_dir(scenario_id, campaign_hint=campaign_hint)
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

    chain = meta["chain"]
    perf = parse_perf_csv(perf_path)

    task_clock = perf["task-clock"]["value"]
    task_clock_unit = perf["task-clock"]["unit"]
    cpu_utilized = perf["task-clock"]["metric"]

    cycles = perf["cycles"]["value"]
    cycles_ghz = perf["cycles"]["metric"]

    instructions = perf["instructions"]["value"]
    ipc = perf["instructions"]["metric"]
    if ipc is None:
        ipc = safe_div(instructions, cycles)

    branches = perf["branches"]["value"]
    branches_rate_msec = perf["branches"]["metric"]

    branch_misses = perf["branch-misses"]["value"]
    branch_miss_rate_pct = perf["branch-misses"]["metric"]
    if branch_miss_rate_pct is None:
        tmp = safe_div(branch_misses, branches)
        branch_miss_rate_pct = None if tmp is None else tmp * 100

    cache_references = perf["cache-references"]["value"]
    cache_refs_rate_msec = perf["cache-references"]["metric"]

    cache_misses = perf["cache-misses"]["value"]
    cache_miss_rate_pct = perf["cache-misses"]["metric"]
    if cache_miss_rate_pct is None:
        tmp = safe_div(cache_misses, cache_references)
        cache_miss_rate_pct = None if tmp is None else tmp * 100

    summary = {
        "scenario_id": scenario_id,
        "campaign": meta.get("campaign"),
        "status": meta.get("status"),
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
        "served_chain_der_bytes": chain["served_chain"]["der_bytes"],
        "root_alg": chain["root"]["algorithm"],
        "root_der_bytes": chain["root"]["der_bytes"],
        "intermediate_alg": None if chain["intermediate"] is None else chain["intermediate"]["algorithm"],
        "intermediate_der_bytes": None if chain["intermediate"] is None else chain["intermediate"]["der_bytes"],
        "leaf_alg": chain["leaf"]["algorithm"],
        "leaf_der_bytes": chain["leaf"]["der_bytes"],
        "perf_task_clock_raw": task_clock,
        "perf_task_clock_unit": task_clock_unit,
        "perf_cpu_utilized": cpu_utilized,
        "perf_cycles": cycles,
        "perf_cycles_ghz": cycles_ghz,
        "perf_instructions": instructions,
        "perf_ipc": ipc,
        "perf_branches": branches,
        "perf_branches_rate_msec": branches_rate_msec,
        "perf_branch_misses": branch_misses,
        "perf_branch_miss_rate_pct": branch_miss_rate_pct,
        "perf_cache_references": cache_references,
        "perf_cache_refs_rate_msec": cache_refs_rate_msec,
        "perf_cache_misses": cache_misses,
        "perf_cache_miss_rate_pct": cache_miss_rate_pct,
        "run_dir": str(run_dir),
        "pcap_file": meta["outputs"]["pcap_file"],
    }
    return summary


def load_listfile(listfile: Path):
    entries = []
    with listfile.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(line)
    return entries


def main():
    if len(sys.argv) not in (2, 3):
        print("Uso: summarize_list.py <listfile> [output_prefix]", file=sys.stderr)
        sys.exit(1)

    listfile = Path(sys.argv[1])
    if not listfile.is_absolute():
        listfile = REPO / listfile

    if not listfile.exists():
        print(f"ERROR: listfile no encontrado: {listfile}", file=sys.stderr)
        sys.exit(1)

    output_prefix = sys.argv[2] if len(sys.argv) == 3 else listfile.stem

    entries = load_listfile(listfile)
    scenario_ids = [scenario_id_from_list_entry(e) for e in entries]

    campaign_hint = None
    if listfile.stem.startswith("campaign_"):
        suffix = listfile.stem.replace("campaign_", "")
        if suffix in ("A", "B", "C", "D"):
            campaign_hint = suffix

    summaries = [scenario_summary(s, campaign_hint=campaign_hint) for s in scenario_ids]

    out_dir = REPO / "analysis" / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)

    json_out = out_dir / f"{output_prefix}_summary.json"
    csv_out = out_dir / f"{output_prefix}_summary.csv"

    with json_out.open("w") as f:
        json.dump(summaries, f, indent=2)

    fieldnames = [
        "scenario_id",
        "campaign",
        "status",
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
        "root_der_bytes",
        "intermediate_alg",
        "intermediate_der_bytes",
        "leaf_alg",
        "leaf_der_bytes",
        "perf_task_clock_raw",
        "perf_task_clock_unit",
        "perf_cpu_utilized",
        "perf_cycles",
        "perf_cycles_ghz",
        "perf_instructions",
        "perf_ipc",
        "perf_branches",
        "perf_branches_rate_msec",
        "perf_branch_misses",
        "perf_branch_miss_rate_pct",
        "perf_cache_references",
        "perf_cache_refs_rate_msec",
        "perf_cache_misses",
        "perf_cache_miss_rate_pct",
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