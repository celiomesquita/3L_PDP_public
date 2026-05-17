# Batch benchmark runner for 3L-PDP.
#
# Runs BRKGA and/or ALNS on every instance in 3L_PDP_instances/ for a
# configurable number of seeds, appending one CSV row per run to results.csv.
# Already-completed (instance, method, seed) triples are skipped, so the
# script is safe to interrupt and restart.
#
# Usage (from project root):
#   julia --threads auto --project=. src/run_benchmark.jl [method] [time_limit] [n_seeds]
#
# Arguments (all optional, positional):
#   method      : brkga | alns | both   (default: both)
#   time_limit  : seconds per run       (default: 300)
#   n_seeds     : number of seeds       (default: 5)
#
# Output:
#   results/results.csv   — one row per (instance, method, seed)
#
# CSV columns:
#   instance, method, seed, obj, time_s

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")
include("alns.jl")
include("post_opt.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")
const CSV_PATH      = joinpath(RESULTS_DIR, "results.csv")

# ── scaled time limits matching Männel & Bortfeldt (2016) Table 7 ─────────────
# inst_name format: "NNN_LAYOUT_BOX_IDX"
function scaled_time_limit(inst_name::String, default_limit::Float64)::Float64
    parts = split(inst_name, "_")
    length(parts) < 3 && return default_limit
    n_req = tryparse(Int, parts[1]);  isnothing(n_req) && return default_limit
    n_box = tryparse(Int, parts[3]);  isnothing(n_box) && return default_limit
    if     n_req <= 50  && n_box == 2; return  120.0   # 2 min
    elseif n_req <= 50  && n_box == 3; return  300.0   # 5 min
    elseif n_req <= 75  && n_box == 2; return  240.0   # 4 min
    elseif n_req <= 75  && n_box == 3; return  600.0   # 10 min
    elseif n_req <= 100 && n_box == 2; return  480.0   # 8 min
    else;                              return 1200.0   # 20 min (100 req, 3 box)
    end
end

# ── argument parsing ───────────────────────────────────────────────────────────
function parse_args()
    args       = ARGS
    method     = length(args) >= 1 ? lowercase(args[1]) : "both"
    time_limit = length(args) >= 2 ? parse(Float64, args[2]) : 300.0
    n_seeds    = length(args) >= 3 ? parse(Int, args[3])     : 5
    method in ("brkga", "alns", "both") ||
        error("method must be brkga | alns | both")
    return method, time_limit, n_seeds
end

# ── load already-completed runs from CSV ──────────────────────────────────────
function load_done(csv_path::String)::Set{Tuple{String,String,Int}}
    done = Set{Tuple{String,String,Int}}()
    isfile(csv_path) || return done
    for line in eachline(csv_path)
        startswith(line, "instance") && continue   # header
        parts = split(line, ",")
        length(parts) >= 3 || continue
        inst   = strip(parts[1])
        meth   = strip(parts[2])
        seed   = parse(Int, strip(parts[3]))
        push!(done, (inst, meth, seed))
    end
    return done
end

# ── CSV writer ─────────────────────────────────────────────────────────────────
function append_result(csv_path, inst_name, method, seed, obj, elapsed, pack_calls, pack_feasible)
    open(csv_path, "a") do io
        @printf(io, "%s,%s,%d,%.5f,%.1f,%d,%d\n",
                inst_name, method, seed, obj, elapsed, pack_calls, pack_feasible)
    end
end

# ── run one BRKGA job ──────────────────────────────────────────────────────────
# Returns (post_opt_ttd, total_elapsed).
# After the BRKGA time budget, the best chromosome is decoded to routes and
# post-optimized via Or-opt + 2-opt (post_opt.jl).  The reported objective is
# the total travel distance of the post-optimized routes — not the BRKGA
# fitness (which includes peak-only packing penalty).
function run_brkga_job(inst::Instance, seed::Int, time_limit::Float64)::Tuple{Float64,Float64}
    pdp  = PDPInstance(inst)
    n    = pdp.n
    chromosome_size = n   # one gene per request: vehicle assignment only

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

    best     = Inf
    best_chr = copy(get_best_chromosome(brkga_data))
    t_start  = time()
    gen      = 0
    while gen < MAX_GENERATIONS && (time() - t_start) < time_limit
        evolve!(brkga_data, 1)
        gen += 1
        f = get_best_fitness(brkga_data)
        if f < best
            best     = f
            best_chr = copy(get_best_chromosome(brkga_data))
        end
    end

    # ── post-optimization ────────────────────────────────────────────────────
    routes = _chromosome_to_pdp_routes(best_chr, pdp)
    post_optimize!(routes, inst, pdp.dist)
    ttd = total_ttd(routes, pdp.dist, n)

    elapsed = time() - t_start
    return ttd, elapsed
end

# ── run one ALNS job ───────────────────────────────────────────────────────────
function run_alns_job(inst::Instance, seed::Int, time_limit::Float64)::NTuple{4,Any}
    best, elapsed, n_calls, n_feasible = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=time_limit, seed=seed)
    end
    return best, elapsed, n_calls, n_feasible
end

# ── main ───────────────────────────────────────────────────────────────────────
function main()
    method, time_limit, n_seeds = parse_args()
    methods = method == "both" ? ["brkga", "alns"] : [method]

    # Ensure output directory and CSV header exist
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    if !isfile(CSV_PATH)
        open(CSV_PATH, "w") do io
            println(io, "instance,method,seed,obj,time_s,pack_calls,pack_feasible")
        end
    end

    done = load_done(CSV_PATH)

    # Collect and sort all instance files
    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(INSTANCES_DIR)))
    n_inst  = length(inst_files)
    n_total = n_inst * length(methods) * n_seeds
    counter = 0

    println("Benchmark runner")
    println("  Instances : $n_inst")
    println("  Methods   : $(join(methods, ", "))")
    println("  Seeds     : 1..$n_seeds")
    println("  Time/run  : $(time_limit)s")
    println("  Total runs: $n_total  (skipping already-done)")
    println("  Output    : $CSV_PATH")
    println()

    for inst_file in inst_files
        inst_name = replace(inst_file, ".txt" => "")
        inst_path = joinpath(INSTANCES_DIR, inst_file)
        inst      = parse_instance(inst_path)

        for meth in methods
            for seed in 1:n_seeds
                counter += 1
                key = (inst_name, meth, seed)
                if key in done
                    println("  [$counter/$n_total]  SKIP  $inst_name  $meth  seed=$seed")
                    continue
                end

                print("  [$counter/$n_total]  $inst_name  $meth  seed=$seed  ... ")
                flush(stdout)
                t0 = time()

                obj_val, elapsed, n_calls, n_feasible = if meth == "brkga"
                    best, el = run_brkga_job(inst, seed, time_limit)
                    (best, el, 0, 0)
                else
                    run_alns_job(inst, seed, time_limit)
                end

                @printf("obj=%.2f  %.1fs  calls=%d  pce=%.3f\n",
                        obj_val, elapsed, n_calls,
                        n_calls > 0 ? n_feasible/n_calls : 0.0)
                append_result(CSV_PATH, inst_name, meth, seed, obj_val, elapsed, n_calls, n_feasible)
                push!(done, key)
            end
        end
    end

    println("\nDone. Results saved to $CSV_PATH")
end

main()
