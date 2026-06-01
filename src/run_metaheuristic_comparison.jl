# Fair comparison of BRKGA, ALNS, and the memetic BRKGA+ALNS hybrid.
#
# Usage:
#   julia --threads 18,2 --project=. src/run_metaheuristic_comparison.jl [time_limit] [seeds] [instances] [csv_path]
#
# Examples:
#   julia --threads 18,2 --project=. src/run_metaheuristic_comparison.jl 300 42
#   julia --threads 18,2 --project=. src/run_metaheuristic_comparison.jl 120 1,2,3 050_RAND_2_1.txt,050_CLUS_2_1.txt

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")
include("alns.jl")

const INST_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR = joinpath(@__DIR__, "..", "results")

const DEFAULT_INSTANCES = [
    "050_RAND_2_1.txt",
    "050_RAND_3_1.txt",
    "050_CLUS_2_1.txt",
    "050_CLUS_3_1.txt",
    "050_CPCD_2_1.txt",
    "050_CPCD_3_1.txt",
]

const MB_V4 = Dict(
    "050_RAND_2_1" => 1635.72,
    "050_RAND_3_1" => 1591.50,
    "050_CLUS_2_1" => 1071.01,
    "050_CLUS_3_1" => 1026.93,
    "050_CPCD_2_1" => 1347.40,
    "050_CPCD_3_1" => 1353.83,
)

const CSV_HEADER = join([
    "instance", "method", "seed", "time_limit_s",
    "threads_default", "threads_interactive",
    "ttd", "fitness", "time_s", "feasible",
    "max_loaded_volume_pct", "delta_v4_pct",
    "pack_calls", "pack_feasible", "pce",
    "alns_produced", "injected", "rejected",
], ",")

function parse_cli()
    time_limit = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 300.0
    seeds = length(ARGS) >= 2 ? [parse(Int, s) for s in split(ARGS[2], ",")] : [42]
    instances = length(ARGS) >= 3 ? split(ARGS[3], ",") : DEFAULT_INSTANCES
    csv_path = length(ARGS) >= 4 ? ARGS[4] :
        joinpath(RESULTS_DIR, "metaheuristic_comparison.csv")
    methods = length(ARGS) >= 5 ? split(ARGS[5], ",") : ["brkga", "alns", "memetic"]
    return time_limit, seeds, instances, csv_path, methods
end

function req_volumes(inst::Instance)
    [sum(b.l * b.w * b.h for b in inst.requests[r].boxes)
     for r in 1:length(inst.requests)]
end

function route_ttd(routes::Vector{Vector{Int}}, pdp::PDPInstance)::Float64
    n = pdp.n
    C = pdp.dist
    ttd = 0.0
    for route in routes
        prev = 1
        for v in route
            nxt = v > 0 ? v + 1 : -v + n + 1
            ttd += C[prev, nxt]
            prev = nxt
        end
        ttd += C[prev, 1]
    end
    return ttd
end

function max_loaded_vol_pct(routes::Vector{Vector{Int}}, inst::Instance)::Float64
    vvol = inst.Lv * inst.Wv * inst.Hv
    rvols = req_volumes(inst)
    best = 0
    for route in routes
        loaded = 0
        for v in route
            if v > 0
                loaded += rvols[v]
                best = max(best, loaded)
            else
                loaded -= rvols[-v]
            end
        end
    end
    return 100.0 * best / vvol
end

function build_brkga_data(pdp::PDPInstance, seed::Int)
    params = BrkgaParams()
    params.population_size             = POP_SIZE
    params.elite_percentage            = ELITE_PCT
    params.mutants_percentage          = MUTANTS_PCT
    params.num_elite_parents           = NUM_ELITE_PAR
    params.total_parents               = TOTAL_PARENTS
    params.bias_type                   = BIAS
    params.num_independent_populations = N_POPULATIONS[]
    params.pr_number_pairs             = 0
    params.pr_minimum_distance         = 0.15
    params.pr_type                     = BrkgaMpIpr.DIRECT
    params.pr_selection                = BrkgaMpIpr.BESTSOLUTION
    params.alpha_block_size            = 1.0
    params.pr_percentage               = 0.35

    brkga = build_brkga(pdp, decode!, BrkgaMpIpr.MINIMIZE, seed, 3 * pdp.n, params)
    BrkgaMpIpr.initialize!(brkga)
    return brkga
end

function summarize_chr(chr::Vector{Float64}, pdp::PDPInstance, fitness::Float64)
    routes = _chromosome_to_pdp_routes(chr, pdp)
    ttd = route_ttd(routes, pdp)
    vol_pct = max_loaded_vol_pct(routes, pdp.inst)
    feasible = fitness < PENALTY_WEIGHT
    return ttd, vol_pct, feasible
end

function run_brkga_only(inst::Instance, seed::Int, time_limit::Float64)
    Random.seed!(seed)
    pdp = PDPInstance(inst)
    brkga = build_brkga_data(pdp, seed)
    t0 = time()
    best_fit = Inf
    best_chr = nothing

    while (time() - t0) < time_limit
        evolve!(brkga, 10)
        fit = get_best_fitness(brkga)
        if fit < best_fit
            best_fit = fit
            best_chr = copy(get_best_chromosome(brkga))
        end
    end

    chr = isnothing(best_chr) ? get_best_chromosome(brkga) : best_chr
    ttd, vol_pct, feasible = summarize_chr(chr, pdp, best_fit)
    return (ttd=ttd, fitness=best_fit, elapsed=time()-t0, feasible=feasible,
            vol_pct=vol_pct, pack_calls=0, pack_feasible=0, pce=0.0,
            produced=0, injected=0, rejected=0)
end

function run_alns_only(inst::Instance, seed::Int, time_limit::Float64)
    obj, elapsed, calls, feasible_calls, sol = redirect_stdout(devnull) do
        solve_alns(inst; time_limit=time_limit, seed=seed, return_solution=true)
    end
    vol_pct = max_loaded_vol_pct(sol.routes, inst)
    pce = calls > 0 ? feasible_calls / calls : 0.0
    return (ttd=obj, fitness=obj, elapsed=elapsed, feasible=packing_feasible(sol),
            vol_pct=vol_pct, pack_calls=calls, pack_feasible=feasible_calls, pce=pce,
            produced=0, injected=0, rejected=0)
end

function run_memetic(inst::Instance, seed::Int, time_limit::Float64)
    Random.seed!(seed)
    pdp = PDPInstance(inst)
    brkga = build_brkga_data(pdp, seed)
    n_elite = max(1, floor(Int, POP_SIZE * ELITE_PCT))

    inject_ch = Channel{PDPSolution}(10)
    n_produced = Threads.Atomic{Int}(0)
    alns_task = Threads.@spawn :interactive begin
        try
            t_alns = time()
            s = 0
            slice = 30.0
            while (time() - t_alns) < time_limit
                remaining = time_limit - (time() - t_alns)
                remaining < 2.0 && break
                _, _, _, _, sol = redirect_stdout(devnull) do
                    solve_alns(inst; time_limit=min(slice, remaining),
                               seed=seed + s, return_solution=true)
                end
                if packing_feasible(sol) && isopen(inject_ch)
                    put!(inject_ch, copy(sol))
                    Threads.atomic_add!(n_produced, 1)
                end
                s += 1
                slice = 60.0
            end
        catch err
            bt = catch_backtrace()
            println("[ALNS producer error]")
            showerror(stdout, err, bt)
            println()
            flush(stdout)
        finally
            close(inject_ch)
        end
    end

    t0 = time()
    best_fit = Inf
    best_chr = nothing
    n_injected = 0
    n_rejected = 0
    inject_slot = 1
    last_inject_t = t0
    last_improve_t = t0

    while (time() - t0) < time_limit
        evolve!(brkga, 10)
        fit = get_best_fitness(brkga)
        if fit < best_fit
            best_fit = fit
            best_chr = copy(get_best_chromosome(brkga))
            last_improve_t = time()
        end

        now = time()
        periodic = (now - last_inject_t) >= 30.0
        stagnant = (now - last_improve_t) >= 60.0
        first_waiting = n_injected == 0 && isready(inject_ch)
        if (periodic || stagnant || first_waiting) && isready(inject_ch)
            while isready(inject_ch)
                sol = take!(inject_ch)
                chr = alns_to_chromosome(sol, pdp)
                fit = decode!(chr, pdp, false)
                if fit < PENALTY_WEIGHT
                    inject_chromosome!(brkga, chr, 1, inject_slot, fit)
                    inject_slot = mod1(inject_slot + 1, n_elite)
                    n_injected += 1
                else
                    n_rejected += 1
                end
            end
            last_inject_t = now
            last_improve_t = now
        end
    end

    t_grace = time()
    while !istaskdone(alns_task) && (time() - t_grace) < 10.0
        sleep(0.2)
    end

    chr = isnothing(best_chr) ? get_best_chromosome(brkga) : best_chr
    ttd, vol_pct, feasible = summarize_chr(chr, pdp, best_fit)
    return (ttd=ttd, fitness=best_fit, elapsed=time()-t0, feasible=feasible,
            vol_pct=vol_pct, pack_calls=0, pack_feasible=0, pce=0.0,
            produced=n_produced[], injected=n_injected, rejected=n_rejected)
end

function append_result(csv_path::String, inst_name::String, method::String,
                       seed::Int, time_limit::Float64, res)
    ref = get(MB_V4, inst_name, NaN)
    delta = isnan(ref) ? NaN : (res.ttd - ref) / ref * 100.0
    open(csv_path, "a") do io
        @printf(io, "%s,%s,%d,%.1f,%d,%d,%.5f,%.5f,%.2f,%s,%.2f,%.4f,%d,%d,%.6f,%d,%d,%d\n",
                inst_name, method, seed, time_limit,
                Threads.nthreads(:default), Threads.nthreads(:interactive),
                res.ttd, res.fitness, res.elapsed, string(res.feasible),
                res.vol_pct, delta, res.pack_calls, res.pack_feasible, res.pce,
                res.produced, res.injected, res.rejected)
    end
end

function main()
    time_limit, seeds, instances, csv_path, methods = parse_cli()
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    if !isfile(csv_path)
        open(csv_path, "w") do io
            println(io, CSV_HEADER)
        end
    end

    println("Metaheuristic comparison")
    println("  time_limit=$(time_limit)s seeds=$(join(seeds, ","))  methods=$(join(methods, ","))")
    println("  threads default=$(Threads.nthreads(:default)) interactive=$(Threads.nthreads(:interactive))")
    println("  output=$csv_path")
    println()
    flush(stdout)

    all_runners = Dict("brkga" => run_brkga_only, "alns" => run_alns_only, "memetic" => run_memetic)
    for inst_file in instances
        inst_name = replace(inst_file, ".txt" => "")
        inst = parse_instance(joinpath(INST_DIR, inst_file))
        for seed in seeds
            for method in methods
                runner = all_runners[method]
                print("  $inst_name seed=$seed method=$method ... ")
                flush(stdout)
                res = runner(inst, seed, time_limit)
                append_result(csv_path, inst_name, method, seed, time_limit, res)
                @printf("ttd=%.2f feasible=%s vol=%.1f%% injected=%d\n",
                        res.ttd, string(res.feasible), res.vol_pct, res.injected)
                flush(stdout)
            end
        end
    end
end

main()

