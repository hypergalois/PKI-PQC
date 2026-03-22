# TLS 1.3 PQC Migration Lab with OpenSSL and OQS Provider

This repository contains a local TLS 1.3 laboratory for studying post-quantum migration strategies in certificate hierarchies and key exchange.

The project focuses on practical comparisons between different combinations of:

- ML-DSA and SLH-DSA certificate hierarchies
- depth-2 and depth-3 PKI topologies
- classical, hybrid, and pure-PQC TLS groups

The repository includes the code and automation required to:

- generate certificate chains from declarative profiles
- launch OpenSSL `s_server` instances with the OQS provider
- run benchmark campaigns with a custom C client
- collect per-handshake metrics, PCAP traces, and `perf` data

The data analysis notebooks, final paper, and short report are intentionally not included here. This repository is the experimental and reproducible execution layer of the work.

## Main goals

The lab is designed to study questions such as:

- What is the practical impact of ML-DSA vs SLH-DSA in TLS server authentication?
- How does the position of each algorithm in the certificate hierarchy affect the handshake?
- What changes when moving from depth-2 to depth-3 chains?
- How do classical, hybrid, and pure-PQC key exchange groups compare?
- Which migration strategies appear operationally plausible, and which look too expensive?

## Repository structure

```text
bench/
  TLS benchmarking client in C

oqs-provider/
  Local OpenSSL + oqsprovider build

pki_factory/
  PKI generation scripts and generated chain material

profiles/
  Declarative JSON profiles for:
  - chains
  - scenarios
  - campaign lists

runner/
  Scripts to launch one scenario or a full campaign list

results/
  Per-scenario outputs:
  - bench CSV
  - perf CSV
  - server logs
  - PCAP traces
  - meta JSON

analysis/
  Optional helper scripts for summarizing runs
```

## Experimental components

### 1. PKI Factory

Certificate chains are generated from JSON chain profiles stored in:

```text
profiles/chains/
```

Supported topologies:

- depth-2: `root -> leaf`
- depth-3: `root -> intermediate -> leaf`

Generated output is written to:

```text
pki_factory/output/<profile_id>/
```

Each generated profile includes:

- certificates and keys
- CSRs
- `chain.json`
- `meta.json`
- `verify.txt`

### 2. TLS benchmark client

The benchmark client is implemented in:

```text
bench/tls_bench_client.c
```

It opens a fresh TCP connection for each run and records per-handshake metrics such as:

- elapsed time
- success/failure
- TLS BIO byte counters
- observed peer chain length
- observed peer chain size in DER bytes

### 3. Scenario runner

Scenarios are defined in:

```text
profiles/scenarios/
```

Each scenario specifies:

- TLS group
- chain profile
- host / port / SNI
- number of runs
- whether to capture PCAP
- whether to collect `perf` data

The main execution script is:

```bash
./runner/run_scenario.sh <scenario.json>
```

Campaign lists are defined in:

```text
profiles/lists/
```

and can be executed with:

```bash
./runner/run_scenario_list.sh <listfile>
```

## Requirements

Typical requirements are:

- Linux
- GCC
- `jq`
- `perf`
- `tcpdump`
- a local OpenSSL build with `oqsprovider`

The repository assumes that the local OpenSSL binary is available at:

```text
oqs-provider/.local/bin/openssl
```

## Build

Compile the benchmark client with:

```bash
gcc -O2 -Wall -Ioqs-provider/.local/include bench/tls_bench_client.c \
  -o bench/tls_bench_client \
  -Loqs-provider/.local/lib64 \
  -Wl,-rpath,"$PWD/oqs-provider/.local/lib64" \
  -lssl -lcrypto
```

## Generate PKI profiles

Example:

```bash
./pki_factory/scripts/gen_chain.sh profiles/chains/slh_root__ml_int__ml_leaf.json
```

This generates all certificate material for that profile under:

```text
pki_factory/output/slh_root__ml_int__ml_leaf/
```

## Run a single scenario

Example:

```bash
./runner/run_scenario.sh profiles/scenarios/x25519mlkem768__slh_root__ml_int__ml_leaf.json
```

You can override the number of runs at execution time:

```bash
RUNS_OVERRIDE=50 ./runner/run_scenario.sh \
  profiles/scenarios/x25519mlkem768__slh_root__ml_int__ml_leaf.json
```

You can also force server-side `perf` collection:

```bash
RUNS_OVERRIDE=50 CAPTURE_PERF_SERVER_OVERRIDE=true \
  ./runner/run_scenario.sh \
  profiles/scenarios/x25519mlkem768__slh_root__ml_int__ml_leaf.json
```

## Run a campaign list

Example:

```bash
RUNS_OVERRIDE=50 ./runner/run_scenario_list.sh profiles/lists/campaign_A.list
```

Available campaign lists include:

- `campaign_A.list`
- `campaign_B_core.list`
- `campaign_B_full.list`
- `campaign_C.list`
- `campaign_D.list`

## Outputs

Each scenario execution creates a timestamped directory under `results/` containing files such as:

- `bench_<scenario>.csv`
- `perf_client_<scenario>.csv`
- `perf_server_<scenario>.csv`
- `server_<scenario>.log`
- `pcap_<scenario>.pcap`
- `meta_<scenario>.json`

These outputs are intended to support later statistical analysis and reporting.

## Example workflow

1. Generate PKI profiles
2. Build the benchmark client
3. Run selected scenarios or campaign lists
4. Collect CSV, PCAP, and `perf` outputs
5. Analyze results outside this repository

## License

MIT License.
