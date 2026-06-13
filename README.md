# 3L-PDP — experiment reproduction package

Anonymous source code and benchmark data to reproduce the computational experiments  
for a manuscript on real-time certified routing for the Three-Dimensional Loading  
Pickup and Delivery Problem (3L-PDP). Under double-blind review (2026).

The **manuscript** describes methods and policies in solver-agnostic language.  
This README is the **implementation companion**: function names, thread layout,  
oracle flags, and file naming used in the code.

---

## Contents

```
├── Project.toml / Manifest.toml     Julia environment
├── 3L_PDP_instances/                54 M&B benchmark instances
├── 3L_PDP_instances_hetero/         270 synthetic heterogeneous instances
├── src/                             Solvers and experiment drivers
├── scripts/                         Batch launchers (Windows PowerShell)
├── docs/                            Study design notes (CoG–SP, height ablation)
└── latex/tables/                    Optional LaTeX fragments from analyze_*.jl
```

All experiment outputs are written to `results/` at runtime (not shipped with this repository).

---

## Requirements

- **Julia 1.12+** (paper experiments: **1.12.5** on Windows 11)
- Packages: `BrkgaMpIpr`, `JuMP`, `HiGHS`, `MHLib` (via `Project.toml`)

```powershell
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

**Reference hardware** (paper §5): Intel Core Ultra 7 155H (16 cores, 22 logical threads),  
64 GiB RAM, Windows 11.

**Reference thread layout** for memetic and panel runs:

```powershell
julia --threads 18,2 --project=. src/run_memetic_benchmark.jl
```

| Pool | Count | Role |
|------|-------|------|
| `:default` | 18 | BRKGA population evaluation (`BrkgaMpIpr` parallel decoder calls) |
| `:interactive` | 2 | Background ALNS producer (`Threads.@spawn :interactive` in `run_memetic_benchmark.jl`) |

ALNS repair operators additionally use `Threads.@threads` inside each ALNS thread  
(batch size `K_CHECK = 20`; see below).

Adjust thread counts to your machine; keep **300 s** time limits and **seed lists**  
unchanged when comparing to published tables.

---

## Implementation details (paper companion)

### Software stack

| Component | Package / module | Role |
|-----------|------------------|------|
| Metaheuristic core | `BrkgaMpIpr.jl` | Parallel BRKGA (`evolve!`, biased crossover) |
| Local search | `MHLib.jl` | ALNS destroy/repair framework |
| MIP sanity check | `JuMP` + `HiGHS` | Small-instance formulation check (`src/main.jl mip`, `src/model.jl`) |
| Packing oracle | `src/packing.jl` | Layer/SP heuristic (`pack_route` and helpers) |

### Instance file naming (M&B)

Files follow **`NNN_LAYOUT_BOX_IDX.txt`** (basename without `.txt` is the instance id):

| Token | Values | Meaning |
|-------|--------|---------|
| `NNN` | `050`, `075`, `100` | Number of requests |
| `LAYOUT` | `RAND`, `CLUS`, `CPCD` | Geography class |
| `BOX` | `2`, `3` | Average boxes per request |
| `IDX` | `1`–`5` (varies by class) | Replicate index within class |

Example: `050_CLUS_2_1.txt` → instance **050_CLUS_2_1** ($n=50$, clustered, 2 boxes/request).

Heterogeneous instances add a material seed suffix: **`NNN_TYPE_BOX_IDX_H{1..5}.txt`**.  
See `3L_PDP_instances_hetero/README.md`.

### Packing oracle — `pack_route`

**Entry point:** `pack_route(route_ids, inst)` in `packing.jl`.

- **Input:** `route_ids` in **delivery order** (index 1 = delivered first at the door).
- **Output:** `0` if the Layer/SP certificate accepts the route; otherwise total box count  
  (penalty proxy for BRKGA fitness).
- **Counters:** `reset_pack_counters!()` / `get_pack_counts()` — atomic call and feasible counts  
  (PCE instrumentation).

**Internal pipeline (names in source):**

| Symbol | Role |
|--------|------|
| `_pack_2d_height` | Shelf-based **first-fit decreasing (FFD)** in $W_v \times H_v$; fragile boxes on top shelves (PC3) |
| `_make_layers` | Greedy depth layers per request |
| `_depth_1csp` | 1C-SP independent depth per request |
| `_depth_2csp` | 2C-SP savings for one adjacent request pair |
| `_depth_3csp` | 3C-SP savings for one adjacent triple |
| `pack_route` | Weight check → optional PC5/PC6 pre-filters → 1C depths → DP over 2C/3C merges |

**Runtime flags** (`Ref{Bool}` globals in `packing.jl`):

| Flag | Default | Effect |
|------|---------|--------|
| `_USE_MERGE` | `true` | `false` → 1C-SP only (no 2C/3C DP) |
| `_USE_3CSP` | `true` | `false` → 2C-SP only (skip triple merges) |
| `_USE_DENSITY` | `false` | `true` → PC5 density ordering pre-filter (3L-PDP-D) |
| `_USE_SS` | `false` | `true` → PC6 McKee BCT pre-filter (3L-PDP-S) |
| `_USE_COG_SP` | `false` | `true` → CoG–SP cross-section packer (`packing_cog_sp.jl`; PC2 off) |

**Oracle tags** used in experiment drivers:

| Tag | `_USE_MERGE` | `_USE_3CSP` | Notes |
|-----|--------------|-------------|-------|
| `1csp` | `false` | `true` | Strict per-request depth (M&B-like 1D ordering) |
| `2csp` | `true` | `false` | Pair merges only |
| `3csp` | `true` | `true` | Full 3C-SP (default production oracle) |
| `3csp_cog` | (as `3csp`) | | CoG–SP instead of shelf PC2 (`_USE_COG_SP[] = true`) |
| `3csp_pc5` | | | 3C-SP + PC5 density pre-filter (hetero hard panel) |

Set via `set_oracle!` in `run_memetic_oracle_panel.jl`, inline in `run_comparison_2csp.jl`,  
or per-job in `run_comparison_cog_sp.jl` / `run_comparison_pc5_cog_hetero.jl`.

**PC7 (3L-PDP-C)** on heterogeneous instances uses the same `pack_route` pre-filters with  
combined BCT from `req_bct` (McKee + Twede cargo term); memetic variant `3lpdp_c` in  
`run_memetic_benchmark.jl`.

### How BRKGA and ALNS call the oracle

| Solver | Packing invocation | Implementation |
|--------|-------------------|----------------|
| **BRKGA** | **Peak-state** (peak-by-volume co-loading) per vehicle | `decode!` in `brkga.jl`: sort loaded requests by delivery rank → `pack_route` → if infeasible, `_repair_pack` (all $k!$ orders for $k \le 5$, else pairwise transpositions) |
| **ALNS** | **Per-candidate** at each pickup | `repair_topk!` / regret repair: batches of up to **`K_CHECK = 20`** candidates evaluated with **`Threads.@threads`**; each candidate copies routes locally then calls `pack_route` on the current loaded set |
| **ALNS feasibility** | Every pickup along the route | `_route_packing_ok` → repeated `pack_route` on loaded sets (stricter than BRKGA peak-only check) |

Memetic hybrid (`run_memetic_benchmark.jl`): BRKGA runs on the default thread pool; ALNS  
runs in a `:interactive` task, pushes feasible `PDPSolution`s through a `Channel`, and  
`inject_chromosome!` inserts them into the BRKGA elite (first slice 30 s, then 60 s).

### BRKGA parameters (`brkga.jl`)

| Constant | Value | Meaning |
|----------|-------|---------|
| `POP_SIZE` | **96** | Population size $P$ |
| `ELITE_PCT` | 0.20 | Elite fraction |
| `MUTANTS_PCT` | 0.15 | Mutants per generation |
| `PENALTY_WEIGHT` | `1e6` | $\omega$ for unplaced items |
| `MAX_REPAIR_PERMUTE` | 5 | Full permutation repair for peak load $\le 5$ |
| Chromosome | $3n$ keys | Pickup rank, delivery rank, vehicle assignment |

> **Note:** The manuscript §5 may cite a larger population (e.g. 256) for a specific table run.  
> This repository’s default is `POP_SIZE = 96` in `brkga.jl`. Override only if you are  
> deliberately matching a frozen release commit documented alongside the paper.

### ALNS parameters (`alns.jl`)

- Destroy: random, worst-cost, Shaw/related, segment, tour removal (MHLib operators).
- Repair: greedy top-$K$, regret-2, regret-3 with parallel packing batches (`K_CHECK = 20`).
- Objective: travel distance; infeasible packing → move rejected (`packing_feasible`).

### Memetic benchmark variants (`run_memetic_benchmark.jl`)

| CLI `variant` | `_USE_DENSITY` | `_USE_SS` | Policy |
|---------------|----------------|-----------|--------|
| `3lpdp` / `3lpdp_h` | off | off | Baseline PC1–PC4 |
| `3lpdp_d` | on | off | PC5 density ordering |
| `3lpdp_s` | off | on | PC6 structural (McKee BCT) |
| `3lpdp_c` | off | off | PC7 via `req_bct` on hetero instances |

CSV columns (append row):  
`instance, variant, seed, time_limit_s, n_default_threads, n_interactive_threads, ttd, fitness, elapsed_s, feasible, max_loaded_volume_pct, delta_v4_pct, alns_produced, alns_injected, alns_rejected`.

### MIP formulation check

```powershell
julia --project=. src/main.jl mip 050_CLUS_2_1.txt 1 4
```

- Model: `src/model.jl` (JuMP + HiGHS).
- Sub-instance: first **4** requests of `050_CLUS_2_1` ($n=4$, 10 items).
- Expected optimum: **258.28** (154 s on reference laptop in paper).

### Literature baselines (not implemented in this repo)

The paper contrasts our sufficient 3C-SP certificate with tree-search packers from the literature:

| Reference | Parameter | Typical setting |
|-----------|-----------|-----------------|
| Männel & Bortfeldt (2016) | `maxApCalls` | 3000 recursive placements (200 when fragility forces it) |
| Wei et al. (2014) | `maxCallTime` | $\max(n,\,100 \cdot (1 - VI/V_k))$ adaptive time budget |

These caps apply to **published M&B LNS** results, not to `pack_route`.

### WPL measurement

`src/measure_wpl.jl` times repeated `pack_route` calls on decoded routes (empirical  
$p99$ latency reported in the paper).

### Oracle completeness study

`src/run_oracle_completeness_study.jl` — when 3C-SP rejects a route, searches delivery  
permutations (factorial for small $k$, transpositions for larger) to detect false negatives.

---

## Experiment map

| Study | Command | Primary output |
|-------|---------|----------------|
| Metaheuristic pilot (6 inst. × 3 seeds) | `.\scripts\launch_metaheuristic_comparison.ps1` | `results/metaheuristic_comparison.csv` |
| M&B memetic benchmark (54 × 5 × 3 variants) | `.\scripts\launch_memetic_table2.ps1` | `results/memetic_benchmark_3lpdp*.csv` |
| Hetero policies PC5 / PC7 (270 × 1 seed) | `.\scripts\launch_memetic_hetero.ps1` | `results/memetic_benchmark_3lpdp_h.csv`, `_d_h.csv`, `_c.csv` |
| ALNS 1C/2C/3C ablation | `.\scripts\launch_comparison.ps1` | `results/comparison_2csp_vs_3csp.csv` |
| Oracle depth × $H_v$ (30 vs 36) | `.\scripts\launch_comparison_height.ps1` | `results/comparison_oracle_depth_height.csv` |
| CoG–SP vs shelf PC2 (homogeneous) | `.\scripts\start_cog_sp_workers_hidden.ps1` then `.\scripts\stop_cog_sp_study.ps1 -MergeCsv` | `results/comparison_oracle_cog_sp.csv` |
| PC5 vs CoG–SP (hardest 20% hetero) | `.\scripts\start_pc5_cog_hetero_workers_hidden.ps1` then `.\scripts\stop_pc5_cog_hetero_study.ps1 -MergeCsv` | `results/comparison_pc5_cog_hetero.csv` |
| WPL latency | `julia --project=. src/measure_wpl.jl` | `results/wpl_results.csv` |
| Oracle completeness | `julia --project=. src/run_oracle_completeness_study.jl` | `results/oracle_completeness.csv` |
| Memetic oracle panel | `julia --threads 18,2 --project=. src/run_memetic_oracle_panel.jl 300 1` | `results/memetic_oracle_panel.csv` |
| 2C vs 3C post-hoc on saved chromosomes | `julia --project=. src/ablation_3csp.jl` | `results/ablation_3csp.csv` |
| MIP formulation check ($n{=}4$) | `julia --project=. src/main.jl mip 050_CLUS_2_1.txt 1 4` | stdout (optimal ≈ 258.28) |
| Summaries | `julia --project=. src/gen_tables.jl` | `results/tables/*.txt` |

**LaTeX table fragments** (optional): after merging worker CSVs, run the `analyze_comparison*.jl`  
scripts; they write to `latex/tables/` (create the folder if missing).

**Hardest 20% hetero panel:** `julia --project=. src/select_hardest_hetero_instances.jl`  
refreshes `3L_PDP_instances_hetero/hardest_hetero_top20pct.txt` from  
`results/memetic_benchmark_3lpdp_h.csv` (seed 1 ranking). The PC5 vs CoG launcher runs this  
automatically.

**CoG–SP oracle ids:** `3csp` (shelf PC2) vs `3csp_cog` (CoG–SP, PC2 off); hetero hard panel:  
`3csp_pc5` vs `3csp_cog`.

All batch drivers **resume** from existing CSV rows after interruption.

---

## Quick start

```powershell
# Dependencies
julia --project=. -e "using Pkg; Pkg.instantiate()"

# Sanity check — one instance, 60 s
julia --threads 4,1 --project=. src/run_memetic_benchmark.jl 60 1 3lpdp 050_CLUS_2_1.txt results/smoke.csv

# Full M&B table (long run)
.\scripts\launch_memetic_table2.ps1

# Summarize completed runs
julia --project=. src/gen_tables.jl
```

---

## Stacking variants

Third argument to `run_memetic_benchmark.jl`:

| Variant | Policy |
|---------|--------|
| `3lpdp` / `3lpdp_h` | Baseline (PC1–PC4) |
| `3lpdp_d` | Density ordering (PC5) |
| `3lpdp_s` | McKee BCT stacking (PC6) |
| `3lpdp_c` | Combined McKee + Twede model (PC7) |

Hetero instances: append ECT per request; see `3L_PDP_instances_hetero/README.md`.

Regenerate hetero set from M&B bases:

```powershell
julia --project=. src/gen_hetero_instances.jl
```

---

## Expected outcomes (full rerun)

After completing the benchmark scripts, `gen_tables.jl` should report approximately:

- Mean ΔV4 vs. M&B (2018) V4: **+7.85%** (95% CI **+5.89% to +9.81%**, 54 instances)
- Hetero mean ΔBase: PC5 **+2.79%**, PC7 **+0.96%**
- Table I memetic pilot: mean TTD **≈ 1379.75**, ΔV4 **≈ +3.65%**

---

## External data citation

The 54 M&B instances are from:

> Männel, D., & Bortfeldt, A. (2016). *European Journal of Operational Research*, 254(3), 840–858.  
> Männel, D., & Bortfeldt, A. (2018). *Transportation Science*, 53(3), 840–864.

The 270 heterogeneous instances are synthetic derivatives distributed with this repository.

---

## Launcher notes

- Run PowerShell scripts from the **repository root**: `.\scripts\launch_*.ps1`
- Set `JULIA` if `julia` is not on PATH: `$env:JULIA = "C:\Path\To\julia.exe"`
- Memetic launchers always pass `--threads 18,2` to match the paper’s thread split.

---

## Reproducibility archive

Anonymous review bundle:  
<https://anonymous.4open.science/r/3L_PDP_public-F6F4/>

After acceptance, link a public repository and record a **commit hash** or **Zenodo DOI**  
next to the manuscript’s data-availability statement.
