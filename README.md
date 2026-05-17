# 3L-PDP: Polynomial-Time Packing Oracle with Practical Stacking Constraints

Source code and heterogeneous benchmark instances for the paper
*"A polynomial-time packing oracle for the three-dimensional loading
pickup-and-delivery problem with practical stacking constraints"*
(under review, 2026).

---

## Repository contents

```
├── src/                        Julia source code
│   ├── main.jl                 Single-instance entry point (MIP / BRKGA / ALNS)
│   ├── brkga.jl                Parallel BRKGA solver
│   ├── alns.jl                 ALNS solver (ablation vehicle)
│   ├── packing.jl              3C-SP packing oracle
│   ├── model.jl                MIP formulation (HiGHS / JuMP)
│   ├── run_benchmark_parallel.jl  Per-worker benchmark runner
│   ├── launch_parallel_benchmark.sh  Parallel benchmark launcher
│   ├── gen_hetero_instances.jl  Heterogeneous instance generator
│   ├── gen_tables.jl           LaTeX table generator
│   ├── ablation_3csp.jl        Oracle depth ablation study
│   ├── measure_wpl.jl          Worst-Case Packing Latency (WPL) measurement
│   └── ...                     Analysis and utility scripts
└── instances_hetero/           270 heterogeneous benchmark instances (3L-PDP-H)
    └── README.md               Instance format and generation details
```

---

## Requirements

- **Julia 1.12** or later
- Julia packages (installed automatically via `Project.toml`):
  - `BrkgaMpIpr` — parallel BRKGA framework
  - `JuMP` + `HiGHS` — MIP exact solver
  - `MHLib` — metaheuristic utilities

Install dependencies from the project root:

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

---

## M&B benchmark instances

The 54 benchmark instances of Männel & Bortfeldt (2016, 2018) are **not
included** in this repository. They are available from the authors upon
request (see the original paper) or from the Electronic Companion of:

> Männel, D., & Bortfeldt, A. (2016). A hybrid algorithm for the vehicle
> routing problem with pickup and delivery and three-dimensional loading
> constraints. *European Journal of Operational Research*, 254(3), 840–858.

Place the downloaded instances in a directory named `3L_PDP_instances/`
at the project root before running any benchmark.

---

## Quick start — single instance

```bash
# Run BRKGA on one M&B instance (300 s, all threads):
julia --project=. --threads auto src/main.jl brkga 050_CLUS_2_1.txt

# Run ALNS on a larger instance:
julia --project=. src/main.jl alns 075_RAND_2_1.txt

# Validate MIP exact solution on a small subset (n ≤ 4 requests):
julia --project=. src/main.jl mip 050_CLUS_2_1.txt 1 4
```

---

## Full benchmark — parallel execution

The parallel launcher distributes the full (instance × seed) matrix across
`N_WORKERS` Julia processes.  Each worker writes its own CSV; the launcher
merges them into `results/results.csv`.

```bash
# Defaults: brkga, 300 s per run, 5 seeds, 15 workers
bash src/launch_parallel_benchmark.sh

# Custom: alns, 120 s, 3 seeds, 8 workers
bash src/launch_parallel_benchmark.sh alns 120 3 8
```

The launcher expects `julia` to be on your `PATH`.  If it is not, set the
`JULIA` variable at the top of `src/launch_parallel_benchmark.sh` to the
full path of your Julia executable.

Results are written to `results/results.csv`.
Run `julia --project=. src/gen_tables.jl` afterwards to regenerate the
LaTeX tables.

---

## Heterogeneous benchmark (3L-PDP-H)

The 270 instances in `instances_hetero/` are synthetic heterogeneous
variants of the 54 M&B instances.  Each base instance is perturbed with
5 random seeds (H1–H5), independently randomising per-request volumetric
density and ECT (edge-crush resistance) grade to break the
weight–volume correlation present in the M&B benchmark.

See [`instances_hetero/README.md`](instances_hetero/README.md) for the
full generation procedure and file format.

To regenerate the instances from the M&B base files:

```bash
julia --project=. src/gen_hetero_instances.jl
```

To run BRKGA on the heterogeneous benchmark:

```bash
bash src/launch_parallel_benchmark.sh brkga 300 1 8 0 0 instances_hetero
```

---

## Stacking variants

Two operational stacking constraints can be activated via flags passed to
the benchmark runner:

| Flag | Variant | Constraint |
|------|---------|------------|
| `use_density=1` | 3L-PDP-D (PC5) | Non-decreasing volumetric density in delivery order |
| `use_ss=1`      | 3L-PDP-S (PC6) | Cumulative compressive load ≤ BCT strength (McKee's formula) |

Example — run PC6 on the heterogeneous benchmark:

```bash
bash src/launch_parallel_benchmark.sh brkga 300 1 8 0 1 instances_hetero
```

---

## Citation

If you use this code or the 3L-PDP-H instances, please cite:

```
Anonymous (2026). A polynomial-time packing oracle for the
three-dimensional loading pickup-and-delivery problem with practical
stacking constraints. Under review.
```

and the original M&B benchmark:

```
Männel, D., & Bortfeldt, A. (2016). A hybrid algorithm for the vehicle
routing problem with pickup and delivery and three-dimensional loading
constraints. European Journal of Operational Research, 254(3), 840–858.

Männel, D., & Bortfeldt, A. (2018). Solving the three-dimensional loading
vehicle routing problem with pickup and delivery. Transportation Science,
53(3), 840–864.
```
