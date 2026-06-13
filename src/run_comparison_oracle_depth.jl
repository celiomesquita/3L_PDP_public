# Packing-oracle depth study (Table V) — parallel-worker version.
#
# Runs ALNS on every benchmark instance under 1C-SP / 2C-SP / 3C-SP at a fixed
# T_op = 300 s, with configurable seeds and optional vehicle-height overrides.
#
# Usage:
#   julia --threads auto --project=. src/run_comparison_oracle_depth.jl \
#         [n_seeds] [worker_id] [n_workers] [inst_dir] [Hv_list]
#
# Examples:
#   # M&B instances, file Hv=30 only (same as legacy comparison):
#   julia --threads auto --project=. src/run_comparison_oracle_depth.jl 3 0 5
#
#   # Two truck heights: Hv=30 (3.0 m) and Hv=36 (3.6 m, dm units); see launch_comparison_height.sh
#   julia --threads auto --project=. src/run_comparison_oracle_depth.jl \
#         3 0 5 3L_PDP_instances 30,36
#
# Output:
#   results/comparison_oracle_depth_worker_{worker_id}.csv
#   (column Hv present only when Hv_list is supplied)

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("alns.jl")

const DEFAULT_INST_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR      = joinpath(@__DIR__, "..", "results")

function scaled_time_limit(::String)::Float64
    300.0
end

function with_hv(inst::Instance, Hv::Int)::Instance
    Instance(inst.max_routes, inst.Q, inst.Lv, inst.Wv, Hv, inst.depot, inst.requests)
end

function run_job(inst::Instance, seed::Int, tl::Float64, oracle::String)::NTuple{3,Any}
    _USE_MERGE[] = (oracle != "1csp")
    _USE_3CSP[]  = (oracle == "3csp")
    best, _, n_calls, n_feasible = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=tl, seed=seed)
    end
    _USE_MERGE[] = true
    _USE_3CSP[]  = true
    return best, n_calls, n_feasible
end

function parse_args()
    n_seeds   = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 3
    worker_id = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 0
    n_workers = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 1
    inst_dir  = length(ARGS) >= 4 ? ARGS[4] : DEFAULT_INST_DIR
    if !isabspath(inst_dir)
        inst_dir = joinpath(@__DIR__, "..", inst_dir)
    end
    hv_list = Int[]
    if length(ARGS) >= 5 && !isempty(strip(ARGS[5]))
        hv_list = [parse(Int, strip(s)) for s in split(ARGS[5], ",")]
        all(h -> h > 0, hv_list) || error("Hv_list must contain positive integers")
    end
    return n_seeds, worker_id, n_workers, inst_dir, hv_list
end

function job_key(inst_name::String, seed::Int, oracle::String, Hv::Union{Int,Nothing})
    Hv === nothing ? (inst_name, seed, oracle) : (inst_name, seed, oracle, Hv)
end

function load_done(csv_path::String, multi_hv::Bool)
    done = Set{Any}()
    isfile(csv_path) || return done
    for line in eachline(csv_path)
        startswith(line, "instance") && continue
        parts = split(line, ",")
        length(parts) >= 3 || continue
        inst   = strip(parts[1])
        seed   = parse(Int, strip(parts[2]))
        oracle = strip(parts[3])
        if multi_hv && length(parts) >= 4
            Hv = parse(Int, strip(parts[4]))
            push!(done, (inst, seed, oracle, Hv))
        else
            push!(done, (inst, seed, oracle))
        end
    end
    return done
end

function main()
    n_seeds, worker_id, n_workers, inst_dir, hv_list = parse_args()
    multi_hv = !isempty(hv_list)

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    csv_path = joinpath(RESULTS_DIR, "comparison_oracle_depth_worker_$(worker_id).csv")
    done = load_done(csv_path, multi_hv)

    if !isfile(csv_path)
        open(csv_path, "w") do io
            if multi_hv
                println(io, "instance,seed,oracle,Hv,obj,time_limit_s,pack_calls,pack_feasible")
            else
                println(io, "instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible")
            end
        end
    end

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(inst_dir)))

    all_jobs = Tuple{String,Int,String,Union{Int,Nothing}}[]
    for f in inst_files
        for s in 1:n_seeds
            for o in ["3csp", "2csp", "1csp"]
                if multi_hv
                    for Hv in hv_list
                        push!(all_jobs, (f, s, o, Hv))
                    end
                else
                    push!(all_jobs, (f, s, o, nothing))
                end
            end
        end
    end

    my_jobs = [j for (i, j) in enumerate(all_jobs) if (i - 1) % n_workers == worker_id]
    n_my    = length(my_jobs)
    n_skip  = count(j -> begin
        inst_name = replace(j[1], ".txt" => "")
        job_key(inst_name, j[2], j[3], j[4]) in done
    end, my_jobs)
    n_todo  = n_my - n_skip

    hv_msg = multi_hv ? join(hv_list, ",") : "file default"
    println("Worker $worker_id/$n_workers — $n_my jobs ($n_todo to run, $n_skip done)")
    println("  inst_dir=$inst_dir  Hv=$hv_msg  seeds=1..$n_seeds  threads=$(Threads.nthreads())")
    println()
    flush(stdout)

    for (counter, (inst_file, seed, oracle, Hv_override)) in enumerate(my_jobs)
        inst_name = replace(inst_file, ".txt" => "")
        key = job_key(inst_name, seed, oracle, Hv_override)
        if key in done
            hv_s = Hv_override === nothing ? "" : "  Hv=$Hv_override"
            println("  [$counter/$n_my]  SKIP  $inst_name  seed=$seed  $oracle$hv_s")
            flush(stdout)
            continue
        end

        inst = parse_instance(joinpath(inst_dir, inst_file))
        Hv_override !== nothing && (inst = with_hv(inst, Hv_override))
        tl = scaled_time_limit(inst_name)
        hv_s = Hv_override === nothing ? "" : "  Hv=$(inst.Hv)"
        print("  [$counter/$n_my]  $inst_name  seed=$seed  $oracle$hv_s  tl=$(tl)s  ... ")
        flush(stdout)

        t0 = time()
        obj, n_calls, n_feasible = run_job(inst, seed, tl, oracle)
        elapsed = round(time() - t0; digits=1)
        pce = n_calls > 0 ? n_feasible / n_calls : 0.0
        @printf("obj=%.2f  %.1fs  calls=%d  pce=%.3f\n", obj, elapsed, n_calls, pce)
        flush(stdout)

        open(csv_path, "a") do io
            if multi_hv
                @printf(io, "%s,%d,%s,%d,%.5f,%.0f,%d,%d\n",
                        inst_name, seed, oracle, inst.Hv, obj, tl, n_calls, n_feasible)
            else
                @printf(io, "%s,%d,%s,%.5f,%.0f,%d,%d\n",
                        inst_name, seed, oracle, obj, tl, n_calls, n_feasible)
            end
        end
        push!(done, key)
    end

    println("\nWorker $worker_id done.")
    flush(stdout)
end

main()
