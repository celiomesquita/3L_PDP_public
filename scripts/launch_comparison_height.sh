#!/usr/bin/env bash
# launch_comparison_height.sh
#
# Table V packing-oracle depth study at T_op=300 s, 3 seeds per instance,
# repeated for two vehicle heights.
#
# Default Hv list: 30,36  ↔  3.0 m and 3.6 m (M&B dimensions in decimeters).
#
# Usage (from project root):
#   bash scripts/launch_comparison_height.sh [n_seeds] [n_workers] [Hv_list]
#
# Examples:
#   bash scripts/launch_comparison_height.sh
#   bash scripts/launch_comparison_height.sh 3 20 30,36
#
# With many workers, each Julia process uses 1 thread (override:
#   JULIA_THREADS_PER_WORKER=2 bash scripts/launch_comparison_height.sh 3 20 30,36
# ) to avoid oversubscribing the machine.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PROJECT_ROOT/src/run_comparison_oracle_depth.jl"
RESULTS_DIR="$PROJECT_ROOT/results"
LOGS_DIR="$RESULTS_DIR/logs_oracle_depth_height"
INST_DIR="3L_PDP_instances"

N_SEEDS="${1:-3}"
N_WORKERS="${2:-5}"
HV_LIST="${3:-30,36}"

JULIA="${JULIA:-julia}"
if ! command -v "$JULIA" >/dev/null 2>&1; then
    echo "ERROR: julia not found. Set JULIA=... or add Julia to PATH."
    exit 1
fi

TOTAL_JOBS=$(( 54 * N_SEEDS * 3 * $(echo "$HV_LIST" | tr ',' '\n' | wc -l) ))
JOBS_PER_WORKER=$(( (TOTAL_JOBS + N_WORKERS - 1) / N_WORKERS ))
EST_MIN=$(( 300 * JOBS_PER_WORKER / 60 ))

echo "========================================"
echo "  Oracle depth × truck height study"
echo "========================================"
echo "  Instances   : 54 ($INST_DIR)"
echo "  Oracles     : 1C-SP, 2C-SP, 3C-SP"
echo "  T_op        : 300 s (fixed)"
echo "  Seeds       : 1..$N_SEEDS"
echo "  Hv values   : $HV_LIST  (30=3.0 m, 36=3.6 m, dm units)"
echo "  Workers     : $N_WORKERS"
echo "  Jobs/worker : ~$JOBS_PER_WORKER  (total $TOTAL_JOBS)"
echo "  Est. serial : ~${EST_MIN} min per worker (wall time lower with parallelism)"
echo "  Logs        : $LOGS_DIR"
echo "========================================"
echo

mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

if [ "$N_WORKERS" -gt 1 ]; then
    THREADS_PER_WORKER="${JULIA_THREADS_PER_WORKER:-1}"
else
    THREADS_PER_WORKER="${JULIA_THREADS_PER_WORKER:-auto}"
fi
echo "  Julia threads/worker : $THREADS_PER_WORKER"
echo

declare -a PIDS
for (( wid=0; wid<N_WORKERS; wid++ )); do
    LOG="$LOGS_DIR/worker_${wid}.log"
    "$JULIA" --threads="$THREADS_PER_WORKER" --project="$PROJECT_ROOT" "$SCRIPT" \
        "$N_SEEDS" "$wid" "$N_WORKERS" "$INST_DIR" "$HV_LIST" \
        > "$LOG" 2>&1 &
    PIDS[$wid]=$!
    echo "  Worker $wid started (PID ${PIDS[$wid]}) → $LOG"
done

echo
echo "Waiting for workers..."
ALL_OK=true
for (( wid=0; wid<N_WORKERS; wid++ )); do
    if wait "${PIDS[$wid]}"; then
        echo "  Worker $wid: OK"
    else
        echo "  Worker $wid: FAILED"
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = false ]; then
    echo "One or more workers failed — check $LOGS_DIR"
    exit 1
fi

MERGED="$RESULTS_DIR/comparison_oracle_depth_height.csv"
echo "instance,seed,oracle,Hv,obj,time_limit_s,pack_calls,pack_feasible" > "$MERGED"
for (( wid=0; wid<N_WORKERS; wid++ )); do
    WCSV="$RESULTS_DIR/comparison_oracle_depth_worker_${wid}.csv"
    if [ -f "$WCSV" ]; then
        tail -n +2 "$WCSV" >> "$MERGED"
    fi
done
N_ROWS=$(tail -n +2 "$MERGED" | wc -l)
echo
echo "Merged $N_ROWS rows → $MERGED"
echo "Analyze:  julia --project=. src/analyze_comparison_height.jl"
