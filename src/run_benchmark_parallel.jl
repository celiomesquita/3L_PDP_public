# Parallel-worker benchmark runner for 3L-PDP.
#
# This script is meant to be launched by launch_parallel_benchmark.sh
# (N_WORKERS copies in parallel), not called directly.
# Each worker takes a round-robin slice of all (instance, method, seed) jobs
# and writes its results to its own CSV to avoid file-write races.
#
# Usage (called by launcher):
#   julia --threads 1 --project=. src/run_benchmark_parallel.jl \
#         [method] [time_limit] [n_seeds] [worker_id] [n_workers]
#
# Arguments (all optional, positional):
#   method     : brkga | alns | both   (default: alns)
#   time_limit : seconds per run       (default: 300)
#   n_seeds    : number of seeds       (default: 5)
#   worker_id  : 0-based worker index  (default: 0)
#   n_workers  : total workers         (default: 1)
#   use_density: 0|1                   (default: 0)
#   use_ss     : 0|1                   (default: 0)
#   inst_dir   : path to instances dir (default: 3L_PDP_instances)
#   csv_tag    : prefix tag for output CSV (default: "")
#
# Output:
#   results/results_{csv_tag}worker_{worker_id}.csv

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")
include("alns.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")

# ── argument parsing ───────────────────────────────────────────────────────────
function parse_args()
    args        = ARGS
    method      = length(args) >= 1 ? lowercase(args[1]) : "alns"
    time_limit  = length(args) >= 2 ? parse(Float64, args[2]) : 300.0
    n_seeds     = length(args) >= 3 ? parse(Int, args[3])     : 5
    worker_id   = length(args) >= 4 ? parse(Int, args[4])     : 0
    n_workers   = length(args) >= 5 ? parse(Int, args[5])     : 1
    use_density = length(args) >= 6 ? parse(Int, args[6]) != 0 : false
    use_ss      = length(args) >= 7 ? parse(Int, args[7]) != 0 : false
    inst_dir    = length(args) >= 8 && !isempty(args[8]) ?
                      args[8] : joinpath(@__DIR__, "..", "3L_PDP_instances")
    csv_tag     = length(args) >= 9 ? args[9] : ""
    method in ("brkga", "alns", "both") ||
        error("method must be brkga | alns | both")
    0 <= worker_id < n_workers ||
        error("worker_id must be in [0, n_workers)")
    use_density && use_ss && error("use_density and use_ss cannot both be true")
    return method, time_limit, n_seeds, worker_id, n_workers, use_density, use_ss,
           inst_dir, csv_tag
end

# ── load already-completed runs from this worker's CSV ────────────────────────
function load_done(csv_path::String)::Set{Tuple{String,String,Int}}
    done = Set{Tuple{String,String,Int}}()
    isfile(csv_path) || return done
    for line in eachline(csv_path)
        startswith(line, "instance") && continue
        parts = split(line, ",")
        length(parts) >= 3 || continue
        push!(done, (strip(parts[1]), strip(parts[2]), parse(Int, strip(parts[3]))))
    end
    return done
end

# ── CSV writer ─────────────────────────────────────────────────────────────────
function append_result(csv_path, inst_name, method, seed, obj, elapsed, t_first_feasible)
    open(csv_path, "a") do io
        @printf(io, "%s,%s,%d,%.5f,%.1f,%.2f\n",
                inst_name, method, seed, obj, elapsed, t_first_feasible)
    end
end

# ── run one BRKGA job ──────────────────────────────────────────────────────────
function run_brkga_job(inst::Instance, seed::Int, time_limit::Float64)::Tuple{Float64,Float64,Float64}
    pdp  = PDPInstance(inst)
    n    = pdp.n
    chromosome_size = n   # one gene per request: vehicle assignment

    params = BrkgaParams()
    params.population_size             = POP_SIZE
    params.elite_percentage            = ELITE_PCT
    params.mutants_percentage          = MUTANTS_PCT
    params.num_elite_parents           = NUM_ELITE_PAR
    params.total_parents               = TOTAL_PARENTS
    params.bias_type                   = BIAS
    params.num_independent_populations = N_POPULATIONS
    params.pr_number_pairs             = 0
    params.pr_minimum_distance         = 0.15
    params.pr_type                     = BrkgaMpIpr.DIRECT
    params.pr_selection                = BrkgaMpIpr.BESTSOLUTION
    params.alpha_block_size            = 1.0
    params.pr_percentage               = 0.35

    brkga_data = build_brkga(pdp, decode!, BrkgaMpIpr.MINIMIZE, seed,
                             chromosome_size, params)
    BrkgaMpIpr.initialize!(brkga_data)

    best               = Inf
    t_start            = time()
    t_first_feasible   = -1.0   # seconds to first zero-penalty solution
    gen                = 0

    WARM_AFTER  = 500
    WARM_MAX    = 2
    RESET_AFTER = (WARM_MAX + 1) * WARM_AFTER
    best_chr    = nothing
    stagnant    = 0
    cycle_warms = 0
    n_warms     = 0
    n_resets    = 0

    while gen < MAX_GENERATIONS && (time() - t_start) < time_limit
        evolve!(brkga_data, 1)
        gen += 1
        f = get_best_fitness(brkga_data)
        if f < best
            best        = f
            best_chr    = copy(get_best_chromosome(brkga_data))
            stagnant    = 0
            cycle_warms = 0
            # Record time to first feasible solution (fitness < PENALTY_WEIGHT)
            if t_first_feasible < 0.0 && f < PENALTY_WEIGHT
                t_first_feasible = time() - t_start
            end
        else
            stagnant += 1
            if stagnant >= RESET_AFTER
                n_resets   += 1; cycle_warms = 0
                reset!(brkga_data); BrkgaMpIpr.initialize!(brkga_data)
                inject_chromosome!(brkga_data, best_chr, 1, 1, best)
                stagnant = 0
            elseif stagnant % WARM_AFTER == 0 && cycle_warms < WARM_MAX
                n_warms += 1; cycle_warms += 1; stagnant = 0
                perturbed = copy(best_chr)
                for i in eachindex(perturbed); rand() < 0.20 && (perturbed[i] = rand()); end
                inject_chromosome!(brkga_data, perturbed, 1, 2)
            end
        end
    end

    # ── post-processing: decode best chromosome → PDPSolution → local search ──
    chr  = isnothing(best_chr) ? get_best_chromosome(brkga_data) : best_chr
    sol  = PDPSolution(inst)
    sol.routes  = _chromosome_to_pdp_routes(chr, pdp)
    sol.obj_val = _travel_cost(sol)
    _improve_delivery_order!(sol)
    _or_opt_between_routes!(sol)

    elapsed = time() - t_start
    # If post-processing produced a feasible solution but evolution never did,
    # credit t_first_feasible as the full elapsed time.
    t_ff = t_first_feasible < 0.0 ? elapsed : t_first_feasible
    return sol.obj_val, elapsed, t_ff
end

# ── run one ALNS job ───────────────────────────────────────────────────────────
# ALNS always maintains packing feasibility (repair rejects infeasible moves),
# so the initial constructed solution is already feasible → t_first_feasible ≈ 0.
function run_alns_job(inst::Instance, seed::Int, time_limit::Float64)::Tuple{Float64,Float64,Float64}
    best, elapsed, _, _ = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=time_limit, seed=seed)
    end
    return best, elapsed, 0.0
end

# ── scaled time limits matching Männel & Bortfeldt (2016) Table 7 ─────────────
function scaled_time_limit(inst_name::String, default_limit::Float64)::Float64
    parts = split(inst_name, "_")
    length(parts) < 3 && return default_limit
    n_req = tryparse(Int, parts[1]);  isnothing(n_req) && return default_limit
    n_box = tryparse(Int, parts[3]);  isnothing(n_box) && return default_limit
    if     n_req <= 50  && n_box == 2; return  120.0
    elseif n_req <= 50  && n_box == 3; return  300.0
    elseif n_req <= 75  && n_box == 2; return  240.0
    elseif n_req <= 75  && n_box == 3; return  600.0
    elseif n_req <= 100 && n_box == 2; return  480.0
    else;                              return 1200.0
    end
end

# ── main ───────────────────────────────────────────────────────────────────────
function main()
    method, time_limit, n_seeds, worker_id, n_workers, use_density, use_ss,
        inst_dir, csv_tag = parse_args()
    methods = method == "both" ? ["brkga", "alns"] : [method]

    if use_density; _USE_DENSITY[] = true; end
    if use_ss;      _USE_SS[]      = true; end

    base_prefix = use_density ? "density_worker_" :
                  use_ss      ? "ss_worker_"       :
                                "worker_"
    csv_prefix  = "results_$(csv_tag)$(base_prefix)"
    csv_path    = joinpath(RESULTS_DIR, "$(csv_prefix)$(worker_id).csv")
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    if !isfile(csv_path)
        open(csv_path, "w") do io
            println(io, "instance,method,seed,obj,time_s,t_first_feasible_s")
        end
    end

    done = load_done(csv_path)

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(inst_dir)))

    # Round-robin job assignment: worker w takes jobs where (job_index-1) % n_workers == w
    all_jobs = [(f, m, s) for f in inst_files for m in methods for s in 1:n_seeds]
    my_jobs  = [j for (i, j) in enumerate(all_jobs) if (i - 1) % n_workers == worker_id]

    n_my    = length(my_jobs)
    n_skip  = count(j -> (replace(j[1], ".txt" => ""), j[2], j[3]) in done, my_jobs)
    n_todo  = n_my - n_skip

    println("Worker $worker_id/$n_workers — $n_my jobs assigned ($n_todo to run, $n_skip already done)")
    println("  method=$(join(methods,",")), time_limit=$(time_limit)s, seeds=1..$n_seeds")
    println("  output: $csv_path")
    println()
    flush(stdout)

    for (counter, (inst_file, meth, seed)) in enumerate(my_jobs)
        inst_name = replace(inst_file, ".txt" => "")
        key = (inst_name, meth, seed)

        if key in done
            println("  [$counter/$n_my]  SKIP  $inst_name  $meth  seed=$seed")
            flush(stdout)
            continue
        end

        inst = parse_instance(joinpath(inst_dir, inst_file))

        print("  [$counter/$n_my]  $inst_name  $meth  seed=$seed  ... ")
        flush(stdout)

        tl = scaled_time_limit(inst_name, time_limit)
        obj_val, elapsed, t_ff = if meth == "brkga"
            run_brkga_job(inst, seed, tl)
        else
            run_alns_job(inst, seed, tl)
        end

        @printf("obj=%.2f  %.1fs  tff=%.1fs\n", obj_val, elapsed, t_ff)
        flush(stdout)
        append_result(csv_path, inst_name, meth, seed, obj_val, elapsed, t_ff)
        push!(done, key)
    end

    println("\nWorker $worker_id done.")
    flush(stdout)
end

main()
