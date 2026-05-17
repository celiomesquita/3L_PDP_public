# tune_brkga.jl
#
# Random-search hyperparameter tuning for the BRKGA solver.
#
# Evaluates random configurations of BRKGA parameters on a small proxy set
# of hard instances (050_CPCD) and saves all results to results/tune_brkga.csv.
# At the end prints the top-5 configurations ranked by mean ttd.
#
# NOTE: the benchmark runner (run_benchmark.jl) uses run_brkga_job(), which
# does NOT include warm/hard restarts. This script uses restarts. If tuning
# shows restarts help significantly, update run_benchmark.jl accordingly.
#
# Usage (from project root):
#   julia --threads auto --project=. src/tune_brkga.jl [n_trials] [time_limit_s]
#
# Arguments (optional, positional):
#   n_trials       : random configurations to evaluate  (default: 80)
#   time_limit_s   : seconds per instance per run       (default: 45)
#
# Runtime estimate (defaults): 80 × 4 instances × 2 seeds × 45 s ≈ 8 h
# The script is safe to interrupt and restart: already-evaluated
# configurations are detected by their parameter key and skipped.

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")
include("post_opt.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")
const TUNE_CSV      = joinpath(RESULTS_DIR, "tune_brkga.csv")

# ── proxy instance set ─────────────────────────────────────────────────────────
# Pure-cluster (CPCD) instances are the hardest and show the largest variance
# between configurations — most discriminative for hyperparameter search.
const PROXY_INSTANCES = [
    "050_CPCD_2_1.txt",
    "050_CPCD_2_2.txt",
    "050_CPCD_3_1.txt",
    "050_CPCD_3_2.txt",
]

const TUNE_SEEDS = [1, 2]   # 2 seeds per configuration (variance estimate)

# ── parameter space ────────────────────────────────────────────────────────────
struct BrkgaConfig
    elite_pct    :: Float64   # fraction of elite individuals
    mutants_pct  :: Float64   # fraction of mutants per generation
    warm_after   :: Int       # stagnant generations before warm restart
    warm_max     :: Int       # warm restarts before a hard reset
    perturb_rate :: Float64   # fraction of genes randomised in warm restart
end

function random_config(rng::AbstractRNG)::BrkgaConfig
    BrkgaConfig(
        rand(rng, [0.10, 0.15, 0.20, 0.25]),
        rand(rng, [0.05, 0.10, 0.15, 0.20]),
        rand(rng, [300, 400, 500, 600, 800, 1000]),
        rand(rng, [1, 2, 3]),
        rand(rng, [0.10, 0.15, 0.20, 0.25, 0.30, 0.35]),
    )
end

function config_key(cfg::BrkgaConfig)::String
    @sprintf("%.2f,%.2f,%d,%d,%.2f",
             cfg.elite_pct, cfg.mutants_pct,
             cfg.warm_after, cfg.warm_max, cfg.perturb_rate)
end

# ── parameterised BRKGA runner with warm/hard restarts ────────────────────────
function run_brkga_tuning(inst::Instance, seed::Int,
                           time_limit::Float64, cfg::BrkgaConfig)::Float64
    pdp = PDPInstance(inst)
    n   = pdp.n

    params = BrkgaParams()
    params.population_size             = POP_SIZE       # fixed: 256
    params.elite_percentage            = cfg.elite_pct
    params.mutants_percentage          = cfg.mutants_pct
    params.num_elite_parents           = NUM_ELITE_PAR
    params.total_parents               = TOTAL_PARENTS
    params.bias_type                   = BIAS           # fixed: LOGINVERSE
    params.num_independent_populations = N_POPULATIONS
    params.pr_number_pairs             = 0
    params.pr_minimum_distance         = 0.15
    params.pr_type                     = BrkgaMpIpr.DIRECT
    params.pr_selection                = BrkgaMpIpr.BESTSOLUTION
    params.alpha_block_size            = 1.0
    params.pr_percentage               = 0.35

    brkga_data = build_brkga(pdp, decode!, BrkgaMpIpr.MINIMIZE, seed, n, params)
    BrkgaMpIpr.initialize!(brkga_data)

    warm_after   = cfg.warm_after
    warm_max     = cfg.warm_max
    perturb_rate = cfg.perturb_rate
    reset_after  = (warm_max + 1) * warm_after

    best        = Inf
    best_chr    = copy(get_best_chromosome(brkga_data))
    stagnant    = 0
    cycle_warms = 0
    t_start     = time()
    gen         = 0

    while gen < MAX_GENERATIONS && (time() - t_start) < time_limit
        evolve!(brkga_data, 1)
        gen += 1
        f = get_best_fitness(brkga_data)
        if f < best
            best        = f
            best_chr    = copy(get_best_chromosome(brkga_data))
            stagnant    = 0
            cycle_warms = 0
        else
            stagnant += 1
            if stagnant >= reset_after
                reset!(brkga_data)
                BrkgaMpIpr.initialize!(brkga_data)
                inject_chromosome!(brkga_data, best_chr, 1, 1, best)
                stagnant    = 0
                cycle_warms = 0
            elseif stagnant % warm_after == 0 && cycle_warms < warm_max
                perturbed = copy(best_chr)
                for i in eachindex(perturbed)
                    rand() < perturb_rate && (perturbed[i] = rand())
                end
                inject_chromosome!(brkga_data, perturbed, 1, 2)
                cycle_warms += 1
                stagnant     = 0
            end
        end
    end

    routes = _chromosome_to_pdp_routes(best_chr, pdp)
    post_optimize!(routes, inst, pdp.dist)
    return total_ttd(routes, pdp.dist, n)
end

# ── evaluate one configuration over all proxy instances and seeds ──────────────
function evaluate_config(cfg::BrkgaConfig,
                          instances::Vector{Tuple{String,Instance}},
                          seeds::Vector{Int},
                          time_limit::Float64)::Float64
    total = 0.0
    count = 0
    for (name, inst) in instances
        for seed in seeds
            ttd = run_brkga_tuning(inst, seed, time_limit, cfg)
            total += ttd
            count += 1
            @printf("      %-22s  seed=%d  ttd=%.2f\n", name, seed, ttd)
            flush(stdout)
        end
    end
    return total / count
end

# ── CSV helpers ────────────────────────────────────────────────────────────────
function ensure_csv_header(path::String)
    isfile(path) && return
    open(path, "w") do io
        println(io, "trial,elite_pct,mutants_pct,warm_after,warm_max,perturb_rate,mean_ttd")
    end
end

function append_trial(path::String, trial::Int, cfg::BrkgaConfig, mean_ttd::Float64)
    open(path, "a") do io
        @printf(io, "%d,%.2f,%.2f,%d,%d,%.2f,%.5f\n",
                trial,
                cfg.elite_pct, cfg.mutants_pct,
                cfg.warm_after, cfg.warm_max, cfg.perturb_rate,
                mean_ttd)
    end
end

# ── load already-completed configs from CSV (resumable) ────────────────────────
function load_done(path::String)::Tuple{Set{String}, Int, Float64, Union{BrkgaConfig,Nothing}}
    done      = Set{String}()
    n_done    = 0
    best_mean = Inf
    best_cfg  = nothing

    isfile(path) || return done, 0, Inf, nothing

    for line in eachline(path)
        startswith(line, "trial") && continue
        parts = split(line, ",")
        length(parts) >= 7 || continue
        cfg = BrkgaConfig(
            parse(Float64, parts[2]),
            parse(Float64, parts[3]),
            parse(Int,     parts[4]),
            parse(Int,     parts[5]),
            parse(Float64, parts[6]),
        )
        mean_ttd = parse(Float64, parts[7])
        push!(done, config_key(cfg))
        n_done += 1
        if mean_ttd < best_mean
            best_mean = mean_ttd
            best_cfg  = cfg
        end
    end
    return done, n_done, best_mean, best_cfg
end

# ── top-5 report ───────────────────────────────────────────────────────────────
function print_top5(path::String)
    rows = Tuple{Float64,BrkgaConfig}[]
    for line in eachline(path)
        startswith(line, "trial") && continue
        parts = split(line, ",")
        length(parts) >= 7 || continue
        cfg = BrkgaConfig(
            parse(Float64, parts[2]),
            parse(Float64, parts[3]),
            parse(Int,     parts[4]),
            parse(Int,     parts[5]),
            parse(Float64, parts[6]),
        )
        push!(rows, (parse(Float64, parts[7]), cfg))
    end
    isempty(rows) && return
    sort!(rows; by = x -> x[1])
    println("\nTop-5 configurations (lower mean ttd = better):")
    println("  Rank   mean_ttd  elite  mutants  warm_after  warm_max  perturb")
    for (i, (m, c)) in enumerate(rows[1:min(5, length(rows))])
        @printf("  %4d  %9.4f  %5.2f   %6.2f  %10d  %8d   %6.2f\n",
                i, m, c.elite_pct, c.mutants_pct,
                c.warm_after, c.warm_max, c.perturb_rate)
    end
end

# ── main ───────────────────────────────────────────────────────────────────────
function main()
    n_trials   = length(ARGS) >= 1 ? parse(Int,     ARGS[1]) : 80
    time_limit = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 45.0

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    ensure_csv_header(TUNE_CSV)

    done_keys, n_done, best_mean, best_cfg = load_done(TUNE_CSV)

    # load proxy instances
    instances = Tuple{String,Instance}[]
    for fn in PROXY_INSTANCES
        path = joinpath(INSTANCES_DIR, fn)
        if !isfile(path)
            println("WARNING: $fn not found — skipping.")
            continue
        end
        push!(instances, (replace(fn, ".txt" => ""), parse_instance(path)))
    end
    isempty(instances) && error("No proxy instances found in $INSTANCES_DIR")

    est_h = n_trials * length(instances) * length(TUNE_SEEDS) * time_limit / 3600

    println("=" ^ 60)
    println("BRKGA Hyperparameter Tuning  (Random Search)")
    println("=" ^ 60)
    println("  Proxy instances : $(length(instances))")
    for (name, _) in instances; println("    $name"); end
    println("  Seeds / config  : $(TUNE_SEEDS)")
    println("  Time / instance : $(time_limit) s")
    println("  New trials      : $n_trials")
    @printf("  Est. runtime    : %.1f h\n", est_h)
    println("  Output          : $TUNE_CSV")
    if n_done > 0
        @printf("  Resuming        : %d trials already done (best mean ttd = %.4f)\n",
                n_done, best_mean)
    end
    println()

    rng       = MersenneTwister(2025)
    generated = 0
    trial_num = n_done

    while generated < n_trials
        cfg = random_config(rng)
        key = config_key(cfg)
        key in done_keys && continue   # skip duplicates / already-done
        push!(done_keys, key)

        generated += 1
        trial_num += 1

        @printf("\n[Trial %d / %d]\n", trial_num, n_done + n_trials)
        @printf("  elite=%.2f  mutants=%.2f  warm_after=%d  warm_max=%d  perturb=%.2f\n",
                cfg.elite_pct, cfg.mutants_pct,
                cfg.warm_after, cfg.warm_max, cfg.perturb_rate)
        flush(stdout)

        mean_ttd = evaluate_config(cfg, instances, TUNE_SEEDS, time_limit)
        append_trial(TUNE_CSV, trial_num, cfg, mean_ttd)

        is_best = mean_ttd < best_mean
        @printf("  → mean ttd = %.4f%s\n", mean_ttd, is_best ? "  *** NEW BEST ***" : "")

        if is_best
            best_mean = mean_ttd
            best_cfg  = cfg
        end
    end

    println("\n" * "=" ^ 60)
    println("TUNING COMPLETE")
    @printf("Best mean ttd : %.4f\n", best_mean)
    if !isnothing(best_cfg)
        println("Best config:")
        @printf("  elite_pct    = %.2f\n", best_cfg.elite_pct)
        @printf("  mutants_pct  = %.2f\n", best_cfg.mutants_pct)
        @printf("  warm_after   = %d\n",   best_cfg.warm_after)
        @printf("  warm_max     = %d\n",   best_cfg.warm_max)
        @printf("  perturb_rate = %.2f\n", best_cfg.perturb_rate)
        println()
        println("To apply: update the constants in src/brkga.jl and")
        println("add restart logic to run_brkga_job() in src/run_benchmark.jl.")
    end

    print_top5(TUNE_CSV)
    println("\nFull results: $TUNE_CSV")
end

main()
