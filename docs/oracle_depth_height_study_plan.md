# Packing oracle depth × truck height — home resume plan

Repeat of **Table V** (ALNS only, **300 s** per run, **3 seeds** per instance) under two compartment heights to study stacking / merge depth.

| Real height | `Hv` in solver | Role |
|-------------|----------------|------|
| **3.0 m** | **30** | M&B baseline (file default; dm units) |
| **3.6 m** | **36** | +20% compartment height |

Convention: instance dimensions are in **decimeters** (`H_m = Hv/10`). Box sizes and routing coordinates are unchanged; only `Hv` is overridden for the taller case.

---

## 1. Before you start

- [ ] Open a terminal in the project root: `~/Documents/GitHub/3L_PDP`
- [ ] Confirm Julia works: `julia --version`
- [ ] **Do not delete** partial results unless you want a full rerun:
  - `results/comparison_oracle_depth_worker_0.csv` … `worker_3.csv`
- [ ] Launch: **3 seeds, 20 workers, Hv 30,36** (22-thread machine: 1 Julia thread per worker)

---

## 2. Check how much is already done

```bash
cd ~/Documents/GitHub/3L_PDP

# Lines per worker CSV (subtract 1 for header); sum across workers ≈ completed jobs
for f in results/comparison_oracle_depth_worker_*.csv; do
  [ -f "$f" ] && echo "$(basename "$f"): $(($(wc -l < "$f") - 1)) jobs"
done
```

**Target:** **972** completed rows in total (54 instances × 3 seeds × 3 oracles × 2 heights).

Rough remaining time (if most runs use the full budget):

```text
remaining_jobs × 300 s ÷ 20 workers  ≈  hours left
```

Example: 400 jobs left → `400 × 300 / 20 / 3600` ≈ **1.7 hours**.

---

## 3. Resume the experiment

**Windows (recommended on this machine):**
```powershell
cd C:\Users\celio\Documents\GitHub\3L_PDP
.\scripts\launch_comparison_height.ps1 -NSeeds 3 -NWorkers 20 -HvList "30,36"
```

**Git Bash / Linux:**
```bash
bash scripts/launch_comparison_height.sh 3 20 30,36
```

- **20 workers × 1 thread** avoids oversubscription on a 22-logical-CPU host (ALNS still uses internal `@threads` only within each process).
- Changing **worker count** reshuffles job partitions; only change it on a **fresh** run (or keep the same count when resuming).
- Finished `(instance, seed, oracle, Hv)` tuples are **skipped** automatically.
- Logs (new each launch): `results/logs_oracle_depth_height/worker_*.log`

Monitor one worker:

```bash
tail -f results/logs_oracle_depth_height/worker_0.log
```

Workers run as **background Julia processes** (no need for 20 terminal tabs). On Windows, prefer one hidden launch:

```powershell
powershell -NoProfile -WindowStyle Hidden -File scripts/start_height_workers_hidden.ps1
```

Monitor in **one** terminal: `Get-Content results\logs_oracle_depth_height\worker_0.log -Tail 5 -Wait`

Stop all workers: `.\scripts\stop_height_study.ps1`

You can **close extra empty Cursor terminal tabs**; that does not stop Julia unless you kill the `julia` processes.

---

## 4. When all workers finish

The launcher merges CSVs if it exits cleanly:

- `results/comparison_oracle_depth_height.csv`

If you stopped the launcher early but workers finished, merge manually:

```bash
echo "instance,seed,oracle,Hv,obj,time_limit_s,pack_calls,pack_feasible" > results/comparison_oracle_depth_height.csv
for w in $(seq 0 19); do
  f="results/comparison_oracle_depth_worker_${w}.csv"
  [ -f "$f" ] && tail -n +2 "$f" >> results/comparison_oracle_depth_height.csv
done
wc -l results/comparison_oracle_depth_height.csv   # expect 973 (header + 972)
```

---

## 5. Analyze results

```bash
julia --project=. src/analyze_comparison_height.jl
```

**Outputs:**

- Printed tables per height (TTD by 1C / 2C / 3C-SP, advantages, win counts)
- Cross-height comparison (2.5 m vs 3.0 m for 3C-SP TTD)
- `latex/tables/ablation_3oracle_height.tex` (summary table with heights in metres)

**What to compare (stacking / merge depth):**
- Per height: mean **TTD** for **1C-SP**, **2C-SP**, **3C-SP**; **Adv2v1%** and **Adv3v2%** (how much merge depth shortens routes).
- Across heights: same metrics at **Hv=30 (3.0 m)** vs **Hv=36 (3.6 m)** — if taller bays help vertical merges, **2C/3C** should gain more over **1C** at 3.6 m.

**Hypothesis:** taller compartment → more vertical stacking via 2C/3C merges → **lower TTD**, especially 2C-SP vs 1C-SP.

---

## 6. Troubleshooting

| Issue | Fix |
|--------|-----|
| `bash\r: No such file or directory` | Script had CRLF; should be fixed. Or run: `sed -i 's/\r$//' scripts/launch_comparison_height.sh` |
| `julia not found` | `export JULIA=/path/to/julia` or install Julia and retry |
| Want to rerun one job | Remove that row from the relevant `comparison_oracle_depth_worker_*.csv` and restart |
| Full clean rerun | Remove `results/comparison_oracle_depth_worker_*.csv` and `comparison_oracle_depth_height.csv`, then launch again |

---

## 7. Experiment matrix (reference)

| Dimension | Value |
|-----------|--------|
| Instances | 54 (`3L_PDP_instances/`) |
| Method | ALNS only |
| Oracles | `1csp`, `2csp`, `3csp` |
| Seeds | 1, 2, 3 |
| Time limit | 300 s per run |
| Heights | Hv 30 (3.0 m), Hv 36 (3.6 m) |
| **Total runs** | **972** |

---

## 8. Optional: lighter load next time

- Fewer workers on a busy machine: e.g. `bash scripts/launch_comparison_height.sh 3 2 30,36` — **only if starting fresh** or you accept uneven resume.
- Smoke test (not in launcher): single instance via `run_comparison_oracle_depth.jl` with manual args.

---

*Scripts: `scripts/launch_comparison_height.ps1`, `scripts/launch_comparison_height.sh`, `src/run_comparison_oracle_depth.jl`, `src/analyze_comparison_height.jl`*
