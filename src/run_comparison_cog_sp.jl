# 3C-SP stability study: PC2 (3csp) vs CoG–SP (3csp_cog), no other merge depths.
# 54 instances × 3 seeds × 2 oracles = 324 runs at Hv=30 (3.0 m), ALNS 300 s.
#
# Usage:
#   julia --threads=1 --project=. src/run_comparison_cog_sp.jl [n_seeds] [worker_id] [n_workers] [inst_dir]

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("alns.jl")

const DEFAULT_INST_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR      = joinpath(@__DIR__, "..", "results")
# 3csp: 3C-SP + PC2 (shelf); 3csp_cog: 3C-SP + CoG–SP (PC2 off)
const ORACLES = ("3csp", "3csp_cog")

function scaled_time_limit(::String)::Float64
    300.0
end

function configure_oracle!(oracle::String)
    oracle in ORACLES || error("Unknown oracle: $oracle (expected 3csp or 3csp_cog)")
    _USE_MERGE[]   = true   # always 3C-SP merge DP
    _USE_3CSP[]    = true
    _USE_COG_SP[]  = oracle == "3csp_cog"
    _USE_DENSITY[] = false
    _USE_SS[]      = false
end

function reset_oracle_flags!()
    _USE_MERGE[]  = true
    _USE_3CSP[]   = true
    _USE_COG_SP[] = false
end

function run_job(inst::Instance, seed::Int, tl::Float64, oracle::String)::NTuple{3,Any}
    configure_oracle!(oracle)
    best, _, n_calls, n_feasible = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=tl, seed=seed)
    end
    reset_oracle_flags!()
    return best, n_calls, n_feasible
end

function main()
    n_seeds   = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 3
    worker_id = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 0
    n_workers = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 1
    inst_dir  = length(ARGS) >= 4 ? ARGS[4] : DEFAULT_INST_DIR
    if !isabspath(inst_dir)
        inst_dir = joinpath(@__DIR__, "..", inst_dir)
    end

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    csv_path = joinpath(RESULTS_DIR, "comparison_oracle_cog_sp_worker_$(worker_id).csv")
    done = Set{Tuple{String,Int,String}}()
    if isfile(csv_path)
        for line in eachline(csv_path)
            startswith(line, "instance") && continue
            parts = split(line, ",")
            length(parts) >= 3 || continue
            push!(done, (strip(parts[1]), parse(Int, strip(parts[2])), strip(parts[3])))
        end
    else
        open(csv_path, "w") do io
            println(io, "instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible")
        end
    end

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt", readdir(inst_dir)))
    all_jobs = Tuple{String,Int,String}[]
    for f in inst_files
        for s in 1:n_seeds
            for o in ORACLES
                push!(all_jobs, (f, s, o))
            end
        end
    end

    my_jobs = [j for (i, j) in enumerate(all_jobs) if (i - 1) % n_workers == worker_id]
    n_my = length(my_jobs)
    n_skip = count(j -> (replace(j[1], ".txt" => ""), j[2], j[3]) in done, my_jobs)
    println("3C-SP PC2 vs CoG–SP — worker $worker_id/$n_workers — $n_my jobs ($(n_my - n_skip) to run, $n_skip done)")
    println("  oracles=$(join(ORACLES, ", "))  inst_dir=$inst_dir  seeds=1..$n_seeds")
    flush(stdout)

    for (counter, (inst_file, seed, oracle)) in enumerate(my_jobs)
        inst_name = replace(inst_file, ".txt" => "")
        if (inst_name, seed, oracle) in done
            println("  [$counter/$n_my]  SKIP  $inst_name  seed=$seed  $oracle")
            flush(stdout)
            continue
        end
        inst = parse_instance(joinpath(inst_dir, inst_file))
        tl = scaled_time_limit(inst_name)
        print("  [$counter/$n_my]  $inst_name  seed=$seed  $oracle  tl=$(tl)s  ... ")
        flush(stdout)
        t0 = time()
        obj, n_calls, n_feasible = run_job(inst, seed, tl, oracle)
        elapsed = round(time() - t0; digits=1)
        pce = n_calls > 0 ? n_feasible / n_calls : 0.0
        @printf("obj=%.2f  %.1fs  calls=%d  pce=%.3f\n", obj, elapsed, n_calls, pce)
        flush(stdout)
        open(csv_path, "a") do io
            @printf(io, "%s,%d,%s,%.5f,%.0f,%d,%d\n",
                    inst_name, seed, oracle, obj, tl, n_calls, n_feasible)
        end
        push!(done, (inst_name, seed, oracle))
    end
    println("\nWorker $worker_id done.")
    flush(stdout)
end

main()
