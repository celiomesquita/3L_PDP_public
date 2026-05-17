# 2C-SP vs 3C-SP ALNS quality comparison  — parallel-worker version
#
# Runs the ALNS solver twice per instance — once with the full 3C-SP oracle
# and once with 2C-SP only — using the same seeds and scaled time limits as
# the main benchmark.  The _USE_3CSP flag in packing.jl controls which branch
# is active; it is safe to flip between sequential jobs within one worker.
#
# Usage (launched by launch_comparison.ps1, N workers in parallel):
#   julia --threads auto --project=. src/run_comparison_2csp.jl \
#         [n_seeds] [worker_id] [n_workers]
#
# Output:
#   results/comparison_worker_{worker_id}.csv
# Merged by launcher into:
#   results/comparison_2csp_vs_3csp.csv

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("alns.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")

# Fixed 5-minute operational budget for all instance sizes.
# This mirrors the T_op = 300 s used in the RTCR analysis (§5.6) and
# answers the question: "within a single dispatch window, which oracle
# produces better routes?"
function scaled_time_limit(::String)::Float64
    return 300.0
end

# oracle ∈ "3csp" | "2csp" | "1csp"
# Returns (obj, pack_calls, pack_feasible)
function run_job(inst::Instance, seed::Int, tl::Float64, oracle::String)::NTuple{3,Any}
    _USE_MERGE[] = (oracle != "1csp")
    _USE_3CSP[]  = (oracle == "3csp")
    best, _, n_calls, n_feasible = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=tl, seed=seed)
    end
    _USE_MERGE[] = true   # restore defaults
    _USE_3CSP[]  = true
    return best, n_calls, n_feasible
end

function load_done(csv_path::String)::Set{Tuple{String,Int,String}}
    done = Set{Tuple{String,Int,String}}()
    isfile(csv_path) || return done
    for line in eachline(csv_path)
        startswith(line, "instance") && continue
        parts = split(line, ",")
        length(parts) >= 3 || continue
        push!(done, (strip(parts[1]), parse(Int, strip(parts[2])), strip(parts[3])))
    end
    return done
end

function main()
    n_seeds   = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 3
    worker_id = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 0
    n_workers = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 1

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    csv_path = joinpath(RESULTS_DIR, "comparison_worker_$(worker_id).csv")

    done = load_done(csv_path)
    if !isfile(csv_path)
        open(csv_path, "w") do io
            println(io, "instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible")
        end
    end

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(INSTANCES_DIR)))

    # Jobs: for each instance × seed × oracle.
    # Order: 3csp first, then 2csp, then 1csp — prior 3csp/2csp runs are skipped.
    all_jobs = [(f, s, o)
                for f in inst_files
                for s in 1:n_seeds
                for o in ["3csp", "2csp", "1csp"]]
    my_jobs  = [j for (i, j) in enumerate(all_jobs) if (i-1) % n_workers == worker_id]

    n_my   = length(my_jobs)
    n_skip = count(j -> (replace(j[1],".txt"=>""), j[2], j[3]) in done, my_jobs)
    n_todo = n_my - n_skip

    println("Worker $worker_id/$n_workers — $n_my jobs ($n_todo to run, $n_skip done)")
    println("  seeds=1..$n_seeds  threads=$(Threads.nthreads())")
    println()
    flush(stdout)

    for (counter, (inst_file, seed, oracle)) in enumerate(my_jobs)
        inst_name = replace(inst_file, ".txt" => "")
        key = (inst_name, seed, oracle)
        if key in done
            println("  [$counter/$n_my]  SKIP  $inst_name  seed=$seed  $oracle")
            flush(stdout)
            continue
        end

        inst = parse_instance(joinpath(INSTANCES_DIR, inst_file))
        tl   = scaled_time_limit(inst_name)
        print("  [$counter/$n_my]  $inst_name  seed=$seed  $oracle  tl=$(tl)s  ... ")
        flush(stdout)
        t0  = time()
        obj, n_calls, n_feasible = run_job(inst, seed, tl, oracle)
        elapsed = round(time() - t0; digits=1)
        pce = n_calls > 0 ? n_feasible/n_calls : 0.0
        @printf("obj=%.2f  %.1fs  calls=%d  pce=%.3f\n", obj, elapsed, n_calls, pce)
        flush(stdout)

        open(csv_path, "a") do io
            @printf(io, "%s,%d,%s,%.5f,%.0f,%d,%d\n",
                    inst_name, seed, oracle, obj, tl, n_calls, n_feasible)
        end
        push!(done, key)
    end

    println("\nWorker $worker_id done.")
    flush(stdout)
end

main()
