# PC5 vs CoG–SP on hardest 20% hetero instances (3C-SP merge fixed).
# 54 instances × 2 oracles × 1 ALNS seed = 108 runs (default list from select_hardest_hetero_instances.jl).
#
# Oracles:
#   3csp_pc5  — 3C-SP + shelf PC2 + PC5 density ordering (3L-PDP-D packing policy)
#   3csp_cog  — 3C-SP + CoG–SP (PC2 off), no PC5
#
# Usage:
#   julia --project=. src/select_hardest_hetero_instances.jl
#   julia --threads=1 --project=. src/run_comparison_pc5_cog_hetero.jl [solver_seed] [worker_id] [n_workers] [inst_dir] [instance_list]

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("alns.jl")

const DEFAULT_INST_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances_hetero")
const DEFAULT_LIST     = joinpath(@__DIR__, "..", "3L_PDP_instances_hetero", "hardest_hetero_top20pct.txt")
const RESULTS_DIR      = joinpath(@__DIR__, "..", "results")
const ORACLES = ("3csp_pc5", "3csp_cog")

function scaled_time_limit(::String)::Float64
    300.0
end

function configure_oracle!(oracle::String)
    oracle in ORACLES || error("Unknown oracle: $oracle")
    _USE_MERGE[]   = true
    _USE_3CSP[]    = true
    _USE_COG_SP[]  = oracle == "3csp_cog"
    _USE_DENSITY[] = oracle == "3csp_pc5"
    _USE_SS[]      = false
end

function reset_oracle_flags!()
    _USE_MERGE[]  = true
    _USE_3CSP[]   = true
    _USE_COG_SP[] = false
    _USE_DENSITY[] = false
    _USE_SS[]      = false
end

function run_job(inst::Instance, seed::Int, tl::Float64, oracle::String)::NTuple{3,Any}
    configure_oracle!(oracle)
    best, _, n_calls, n_feasible = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=tl, seed=seed)
    end
    reset_oracle_flags!()
    return best, n_calls, n_feasible
end

function load_instance_list(path::String)
    insts = String[]
    for line in eachline(path)
        s = strip(line)
        isempty(s) || startswith(s, "#") && continue
        name = strip(split(s, ",")[1])
        push!(insts, name)
    end
    return insts
end

function main()
    solver_seed = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1
    worker_id   = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 0
    n_workers   = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 1
    inst_dir    = length(ARGS) >= 4 ? ARGS[4] : DEFAULT_INST_DIR
    list_path   = length(ARGS) >= 5 ? ARGS[5] : DEFAULT_LIST
    if !isabspath(inst_dir)
        inst_dir = joinpath(@__DIR__, "..", inst_dir)
    end
    !isabspath(list_path) && (list_path = joinpath(@__DIR__, "..", list_path))
    isfile(list_path) || error("Missing instance list $list_path — run select_hardest_hetero_instances.jl first")

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    csv_path = joinpath(RESULTS_DIR, "comparison_pc5_cog_hetero_worker_$(worker_id).csv")
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

    inst_names = load_instance_list(list_path)
    inst_files = String[]
    for name in inst_names
        f = endswith(name, ".txt") ? name : name * ".txt"
        isfile(joinpath(inst_dir, f)) || error("Missing $(joinpath(inst_dir, f))")
        push!(inst_files, f)
    end

    all_jobs = Tuple{String,String}[]
    for f in inst_files
        for o in ORACLES
            push!(all_jobs, (f, o))
        end
    end

    my_jobs = [j for (i, j) in enumerate(all_jobs) if (i - 1) % n_workers == worker_id]
    n_my = length(my_jobs)
    n_skip = count(j -> (replace(j[1], ".txt" => ""), solver_seed, j[2]) in done, my_jobs)
    println("PC5 vs CoG–SP hetero (hardest 20%) — worker $worker_id/$n_workers — $n_my jobs ($(n_my - n_skip) run, $n_skip skip)")
    println("  $(length(inst_files)) instances  list=$list_path  ALNS seed=$solver_seed")
    flush(stdout)

    for (counter, (inst_file, oracle)) in enumerate(my_jobs)
        inst_name = replace(inst_file, ".txt" => "")
        if (inst_name, solver_seed, oracle) in done
            println("  [$counter/$n_my]  SKIP  $inst_name  $oracle")
            flush(stdout)
            continue
        end
        inst = parse_instance(joinpath(inst_dir, inst_file))
        tl = scaled_time_limit(inst_name)
        print("  [$counter/$n_my]  $inst_name  $oracle  tl=$(tl)s  ... ")
        flush(stdout)
        t0 = time()
        obj, n_calls, n_feasible = run_job(inst, solver_seed, tl, oracle)
        elapsed = round(time() - t0; digits=1)
        pce = n_calls > 0 ? n_feasible / n_calls : 0.0
        @printf("obj=%.2f  %.1fs  calls=%d  pce=%.3f\n", obj, elapsed, n_calls, pce)
        flush(stdout)
        open(csv_path, "a") do io
            @printf(io, "%s,%d,%s,%.5f,%.0f,%d,%d\n",
                    inst_name, solver_seed, oracle, obj, tl, n_calls, n_feasible)
        end
        push!(done, (inst_name, solver_seed, oracle))
    end
    println("\nWorker $worker_id done.")
    flush(stdout)
end

main()
