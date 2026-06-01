# 3L-PDP — experiment reproduction package

Anonymous source code and benchmark data to reproduce the computational experiments  
for a manuscript on real-time certified routing for the Three-Dimensional Loading  
Pickup and Delivery Problem (3L-PDP). Under double-blind review (2026).

---

## Contents

```
├── Project.toml / Manifest.toml     Julia environment
├── 3L_PDP_instances/                54 M&B benchmark instances
├── 3L_PDP_instances_hetero/         270 synthetic heterogeneous instances
├── src/                             Solvers and experiment drivers
└── scripts/                         Batch launchers (Windows PowerShell)
```

All experiment outputs are written to `results/` at runtime (not shipped with this repository).

---

## Requirements

- **Julia 1.12+**
- Packages: `BrkgaMpIpr`, `JuMP`, `HiGHS`, `MHLib` (via `Project.toml`)

```powershell
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

**Reference hardware** (paper §5): Intel Core Ultra 7 155H, 64 GiB RAM, Windows 11,  
memetic solver `--threads 18,2` (18 BRKGA + 2 ALNS/control threads), **300 s** per run,  
solver seeds **1–5** on M&B, seed **1** on heterogeneous instances.

Adjust thread counts to your machine; keep the time limit and seed lists unchanged for comparison.

---

## Experiment map

| Study | Command | Primary output |
|-------|---------|----------------|
| Metaheuristic pilot (6 inst. × 3 seeds) | `.\scripts\launch_metaheuristic_comparison.ps1` | `results/metaheuristic_comparison.csv` |
| M&B memetic benchmark (54 × 5 × 3 variants) | `.\scripts\launch_memetic_table2.ps1` | `results/memetic_benchmark_3lpdp*.csv` |
| Hetero policies PC5 / PC7 (270 × 1 seed) | `.\scripts\launch_memetic_hetero.ps1` | `results/memetic_benchmark_3lpdp_h.csv`, `_d_h.csv`, `_c.csv` |
| WPL latency | `julia --project=. src/measure_wpl.jl` | `results/wpl_results.csv` |
| Oracle completeness | `julia --project=. src/run_oracle_completeness_study.jl` | `results/oracle_completeness.csv` |
| Memetic oracle panel | `julia --threads 18,2 --project=. src/run_memetic_oracle_panel.jl 300 1` | `results/memetic_oracle_panel.csv` |
| MIP formulation check ($n{=}4$) | `julia --project=. src/main.jl mip 050_CLUS_2_1.txt 1 4` | stdout (optimal ≈ 258.28) |
| Summaries | `julia --project=. src/gen_tables.jl` | `results/tables/*.txt` |

All memetic drivers **resume** from existing CSV rows after interruption.

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
