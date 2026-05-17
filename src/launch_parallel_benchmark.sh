#!/usr/bin/env bash
# launch_parallel_benchmark.sh
#
# Launches N_WORKERS Julia processes in parallel, each running a round-robin
# slice of the (instance × method × seed) benchmark matrix, then merges all
# per-worker CSVs into results/results.csv.
#
# Usage (from project root):
#   bash src/launch_parallel_benchmark.sh [method] [time_limit] [n_seeds] [n_workers]
#
# Defaults: alns  300  5  15
#
# Each worker writes to: results/results_worker_N.csv
# Logs:                  results/logs/worker_N.log
# Final merged output:   results/results.csv

set -euo pipefail

JULIA="/c/Users/celio/AppData/Local/Programs/Julia-1.12.5/bin/julia.exe"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PROJECT_ROOT/src/run_benchmark_parallel.jl"
RESULTS_DIR="$PROJECT_ROOT/results"
LOGS_DIR="$RESULTS_DIR/logs"
MERGED_CSV="$RESULTS_DIR/results.csv"

METHOD="${1:-alns}"
TIME_LIMIT="${2:-300}"
N_SEEDS="${3:-5}"
N_WORKERS="${4:-15}"

TOTAL_JOBS=$(( 54 * N_SEEDS ))   # instances × seeds (per method)
JOBS_PER_WORKER=$(( (TOTAL_JOBS + N_WORKERS - 1) / N_WORKERS ))

echo "========================================"
echo "  3L-PDP Parallel Benchmark Launcher"
echo "========================================"
echo "  Method      : $METHOD"
echo "  Time/run    : ${TIME_LIMIT}s"
echo "  Seeds       : 1..$N_SEEDS"
echo "  Workers     : $N_WORKERS  (--threads 1 each)"
echo "  Jobs/worker : ~$JOBS_PER_WORKER"
echo "  Est. runtime: ~$(( TIME_LIMIT * JOBS_PER_WORKER / 60 )) min"
echo "  Logs dir    : $LOGS_DIR"
echo "========================================"
echo

mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

# ── Launch all workers in background ─────────────────────────────────────────
declare -a PIDS
for (( wid=0; wid<N_WORKERS; wid++ )); do
    LOG="$LOGS_DIR/worker_${wid}.log"
    "$JULIA" --threads 1 --project="$PROJECT_ROOT" "$SCRIPT" \
        "$METHOD" "$TIME_LIMIT" "$N_SEEDS" "$wid" "$N_WORKERS" \
        > "$LOG" 2>&1 &
    PIDS[$wid]=$!
    echo "  Launched worker $wid  (PID ${PIDS[$wid]})  →  $LOG"
done

echo
echo "All $N_WORKERS workers running. Waiting for completion..."
echo "(tail -f $LOGS_DIR/worker_0.log  to monitor worker 0)"
echo

# ── Wait for all workers and collect exit codes ───────────────────────────────
ALL_OK=true
for (( wid=0; wid<N_WORKERS; wid++ )); do
    if wait "${PIDS[$wid]}"; then
        echo "  Worker $wid: OK"
    else
        echo "  Worker $wid: FAILED (exit $?)"
        ALL_OK=false
    fi
done

echo
if [ "$ALL_OK" = false ]; then
    echo "ERROR: one or more workers failed — check logs in $LOGS_DIR"
    exit 1
fi

# ── Merge worker CSVs into results.csv ───────────────────────────────────────
echo "Merging worker CSVs into $MERGED_CSV ..."

# Write header once
echo "instance,method,seed,obj,time_s" > "$MERGED_CSV"

for (( wid=0; wid<N_WORKERS; wid++ )); do
    WCSV="$RESULTS_DIR/results_worker_${wid}.csv"
    if [ -f "$WCSV" ]; then
        tail -n +2 "$WCSV" >> "$MERGED_CSV"
    else
        echo "  WARNING: $WCSV not found — worker $wid produced no output"
    fi
done

# Sort by (instance, method, seed) for readability; keep header on top
HEADER=$(head -1 "$MERGED_CSV")
BODY=$(tail -n +2 "$MERGED_CSV" | sort)
{ echo "$HEADER"; echo "$BODY"; } > "${MERGED_CSV}.tmp" && mv "${MERGED_CSV}.tmp" "$MERGED_CSV"

N_ROWS=$(tail -n +2 "$MERGED_CSV" | wc -l)
echo "  Merged $N_ROWS result rows → $MERGED_CSV"
echo
echo "Done. Run  julia --project=. src/gen_tables.jl  to regenerate LaTeX tables."
