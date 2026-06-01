# Benchmark the memetic BRKGA+ALNS hybrid on the full instance set.
#
# Runs the memetic solver on every (instance, seed) pair and appends one CSV
# row per run.  Already-completed (instance, seed) pairs are skipped so the
# script is safe to interrupt and resume.
#
# Usage (from project root):
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl [time_limit] [seeds] [variant] [instances] [csv_path] [inst_dir]
#
# Arguments (all optional, positional):
#   time_limit  wall-clock budget in seconds            (default: 300)
#   seeds       comma-separated seed list               (default: 1,2,3,4,5)
#   variant     3lpdp | 3lpdp_h | 3lpdp_d | 3lpdp_s | 3lpdp_c   (default: 3lpdp)
#               3lpdp / 3lpdp_h — standard packing (PC1–PC4), baseline
#               3lpdp_d         — density stacking (PC5)
#               3lpdp_s         — structural stacking (PC6, McKee)
#               3lpdp_c         — combined structural stacking (PC7, McKee + Twede)
#   instances   comma-separated .txt filenames, or "auto" to scan inst_dir
#                                                       (default: auto from inst_dir)
#   csv_path    output CSV path                         (default: results/memetic_benchmark_<variant>.csv)
#   inst_dir    directory containing instance .txt files (default: 3L_PDP_instances)
#
# Examples (M&B benchmark):
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl 300 1,2,3,4,5 3lpdp_d
#
# Examples (heterogeneous benchmark):
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl 300 1 3lpdp_h auto results\memetic_benchmark_3lpdp_h.csv 3L_PDP_instances_hetero
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl 300 1 3lpdp_d auto results\memetic_benchmark_3lpdp_d_h.csv 3L_PDP_instances_hetero
#   julia --threads 18,2 --project=. src\run_memetic_benchmark.jl 300 1 3lpdp_c auto results\memetic_benchmark_3lpdp_c.csv 3L_PDP_instances_hetero

using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")
include("alns.jl")

const DEFAULT_INST_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR      = joinpath(@__DIR__, "..", "results")

const ALL_INSTANCES = [
    "050_RAND_2_1.txt", "050_RAND_2_2.txt", "050_RAND_2_3.txt",
    "050_RAND_2_4.txt", "050_RAND_2_5.txt",
    "050_RAND_3_1.txt", "050_RAND_3_2.txt", "050_RAND_3_3.txt",
    "050_RAND_3_4.txt", "050_RAND_3_5.txt",
    "050_CLUS_2_1.txt", "050_CLUS_2_2.txt", "050_CLUS_2_3.txt",
    "050_CLUS_2_4.txt", "050_CLUS_2_5.txt",
    "050_CLUS_3_1.txt", "050_CLUS_3_2.txt", "050_CLUS_3_3.txt",
    "050_CLUS_3_4.txt", "050_CLUS_3_5.txt",
    "050_CPCD_2_1.txt", "050_CPCD_2_2.txt", "050_CPCD_2_3.txt",
    "050_CPCD_2_4.txt", "050_CPCD_2_5.txt",
    "050_CPCD_3_1.txt", "050_CPCD_3_2.txt", "050_CPCD_3_3.txt",
    "050_CPCD_3_4.txt", "050_CPCD_3_5.txt",
    "075_RAND_2_1.txt", "075_RAND_2_2.txt", "075_RAND_2_3.txt",
    "075_RAND_3_1.txt", "075_RAND_3_2.txt", "075_RAND_3_3.txt",
    "075_CLUS_2_1.txt", "075_CLUS_2_2.txt", "075_CLUS_2_3.txt",
    "075_CLUS_3_1.txt", "075_CLUS_3_2.txt", "075_CLUS_3_3.txt",
    "075_CPCD_2_1.txt", "075_CPCD_2_2.txt", "075_CPCD_2_3.txt",
    "075_CPCD_3_1.txt", "075_CPCD_3_2.txt", "075_CPCD_3_3.txt",
    "100_RAND_2_1.txt", "100_RAND_3_1.txt",
    "100_CLUS_2_1.txt", "100_CLUS_3_1.txt",
    "100_CPCD_2_1.txt", "100_CPCD_3_1.txt",
]

const MB2018_V4 = Dict(
    "050_RAND_2_1" => 1635.72, "050_RAND_2_2" => 1506.50, "050_RAND_2_3" => 1526.49,
    "050_RAND_2_4" => 1540.53, "050_RAND_2_5" => 1487.54,
    "050_CLUS_2_1" => 1071.01, "050_CLUS_2_2" => 1036.82, "050_CLUS_2_3" => 1092.75,
    "050_CLUS_2_4" => 1229.84, "050_CLUS_2_5" => 1320.13,
    "050_CPCD_2_1" => 1347.40, "050_CPCD_2_2" => 1270.08, "050_CPCD_2_3" => 1201.01,
    "050_CPCD_2_4" => 1318.11, "050_CPCD_2_5" => 1452.44,
    "050_RAND_3_1" => 1591.50, "050_RAND_3_2" => 1463.68, "050_RAND_3_3" => 1553.59,
    "050_RAND_3_4" => 1507.59, "050_RAND_3_5" => 1513.57,
    "050_CLUS_3_1" => 1026.93, "050_CLUS_3_2" => 1009.62, "050_CLUS_3_3" => 1075.38,
    "050_CLUS_3_4" => 1213.93, "050_CLUS_3_5" => 1300.73,
    "050_CPCD_3_1" => 1353.83, "050_CPCD_3_2" => 1273.55, "050_CPCD_3_3" => 1220.64,
    "050_CPCD_3_4" => 1317.87, "050_CPCD_3_5" => 1434.08,
    "075_RAND_2_1" => 2097.80, "075_RAND_2_2" => 2052.71, "075_RAND_2_3" => 2099.16,
    "075_CLUS_2_1" => 1429.87, "075_CLUS_2_2" => 1385.28, "075_CLUS_2_3" => 1454.94,
    "075_CPCD_2_1" => 2185.09, "075_CPCD_2_2" => 2184.20, "075_CPCD_2_3" => 2265.27,
    "075_RAND_3_1" => 2135.84, "075_RAND_3_2" => 2031.04, "075_RAND_3_3" => 2052.43,
    "075_CLUS_3_1" => 1448.22, "075_CLUS_3_2" => 1400.21, "075_CLUS_3_3" => 1481.37,
    "075_CPCD_3_1" => 2243.73, "075_CPCD_3_2" => 2265.49, "075_CPCD_3_3" => 2239.72,
    "100_RAND_2_1" => 3991.39, "100_RAND_3_1" => 4044.72,
    "100_CLUS_2_1" => 4130.58, "100_CLUS_3_1" => 4149.49,
    "100_CPCD_2_1" => 4272.27, "100_CPCD_3_1" => 4320.01,
)

const CSV_HEADER = join([
    "instance", "variant", "seed", "time_limit_s",
    "threads_default", "threads_interactive",
    "ttd", "fitness", "time_s", "feasible",
    "max_loaded_volume_pct", "delta_v4_pct",
    "alns_produced", "injected", "rejected",
], ",")

# ── CLI ───────────────────────────────────────────────────────────────────────

function parse_cli()
    time_limit = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 300.0
    seeds      = length(ARGS) >= 2 ? [parse(Int, s) for s in split(ARGS[2], ",")] : [1,2,3,4,5]
    variant    = length(ARGS) >= 3 ? ARGS[3] : "3lpdp"
    variant in ("3lpdp", "3lpdp_h", "3lpdp_d", "3lpdp_s", "3lpdp_c") ||
        error("Unknown variant \"$variant\". Choose: 3lpdp | 3lpdp_h | 3lpdp_d | 3lpdp_s | 3lpdp_c")
    inst_dir   = length(ARGS) >= 6 ? ARGS[6] : DEFAULT_INST_DIR
    instances  = if length(ARGS) >= 4 && ARGS[4] != "auto"
        collect(split(ARGS[4], ","))
    else
        sort(filter(f -> endswith(f, ".txt"), readdir(inst_dir)))
    end
    csv_path   = length(ARGS) >= 5 ? ARGS[5] :
                     joinpath(RESULTS_DIR, "memetic_benchmark_$(variant).csv")
    return time_limit, seeds, variant, instances, csv_path, inst_dir
end

# ── packing variant flags ─────────────────────────────────────────────────────

function set_variant!(variant::String)
    if variant in ("3lpdp", "3lpdp_h")
        _USE_DENSITY[] = false
        _USE_SS[]      = false
    elseif variant == "3lpdp_d"
        _USE_DENSITY[] = true
        _USE_SS[]      = false
    elseif variant in ("3lpdp_s", "3lpdp_c")
        _USE_DENSITY[] = false
        _USE_SS[]      = true
    end
end

# ── resume support ────────────────────────────────────────────────────────────

function load_done_pairs(csv_path::String)::Set{Tuple{String,Int}}
    done = Set{Tuple{String,Int}}()
    isfile(csv_path) || return done
    open(csv_path) do io
        readline(io)   # skip header
        for line in eachline(io)
            parts = split(line, ",")
            length(parts) >= 3 && push!(done, (parts[1], parse(Int, parts[3])))
        end
    end
    return done
end

# ── helpers ───────────────────────────────────────────────────────────────────

function req_volumes(inst::Instance)
    [sum(b.l * b.w * b.h for b in inst.requests[r].boxes)
     for r in 1:length(inst.requests)]
end

function route_ttd(routes::Vector{Vector{Int}}, pdp::PDPInstance)::Float64
    n = pdp.n; C = pdp.dist; ttd = 0.0
    for route in routes
        prev = 1
        for v in route
            nxt = v > 0 ? v + 1 : -v + n + 1
            ttd += C[prev, nxt]; prev = nxt
        end
        ttd += C[prev, 1]
    end
    return ttd
end

function max_loaded_vol_pct(routes::Vector{Vector{Int}}, inst::Instance)::Float64
    vvol  = inst.Lv * inst.Wv * inst.Hv
    rvols = req_volumes(inst)
    best  = 0
    for route in routes
        loaded = 0
        for v in route
            if v > 0; loaded += rvols[v]; best = max(best, loaded)
            else;     loaded -= rvols[-v]
            end
        end
    end
    return 100.0 * best / vvol
end

# ── memetic runner ────────────────────────────────────────────────────────────

function run_memetic(inst::Instance, seed::Int, time_limit::Float64)
    Random.seed!(seed)
    pdp    = PDPInstance(inst)
    n_elite = max(1, floor(Int, POP_SIZE * ELITE_PCT))

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

    inject_ch  = Channel{PDPSolution}(10)
    n_produced = Threads.Atomic{Int}(0)
    alns_task  = Threads.@spawn :interactive begin
        try
            t_alns = time(); s = 0; slice = 30.0
            while (time() - t_alns) < time_limit
                remaining = time_limit - (time() - t_alns)
                remaining < 2.0 && break
                _, _, _, _, sol = redirect_stdout(devnull) do
                    solve_alns(inst; time_limit=min(slice, remaining),
                               seed=seed + s, return_solution=true,
                               verbose=false)
                end
                if packing_feasible(sol) && isopen(inject_ch)
                    put!(inject_ch, copy(sol))
                    Threads.atomic_add!(n_produced, 1)
                end
                s += 1; slice = 60.0
            end
        catch err
            println("[ALNS producer error] ", err)
        finally
            close(inject_ch)
        end
    end

    t0 = time(); best_fit = Inf; best_chr = nothing
    n_injected = 0; n_rejected = 0; inject_slot = 1
    last_inject_t = t0; last_improve_t = t0

    while (time() - t0) < time_limit
        evolve!(brkga, 10)
        fit = get_best_fitness(brkga)
        if fit < best_fit
            best_fit = fit
            best_chr = copy(get_best_chromosome(brkga))
            last_improve_t = time()
        end
        now      = time()
        periodic = (now - last_inject_t)  >= 30.0
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
            last_inject_t  = now
            last_improve_t = now
        end
    end

    t_grace = time()
    while !istaskdone(alns_task) && (time() - t_grace) < 10.0; sleep(0.2); end

    chr      = isnothing(best_chr) ? get_best_chromosome(brkga) : best_chr
    routes   = _chromosome_to_pdp_routes(chr, pdp)
    ttd      = route_ttd(routes, pdp)
    vol_pct  = max_loaded_vol_pct(routes, inst)
    feasible = best_fit < PENALTY_WEIGHT

    return (ttd=ttd, fitness=best_fit, elapsed=time()-t0, feasible=feasible,
            vol_pct=vol_pct, routes=routes, produced=n_produced[],
            injected=n_injected, rejected=n_rejected)
end

# ── CSV append ────────────────────────────────────────────────────────────────

function append_row(csv_path::String, inst_name::String, variant::String,
                    seed::Int, time_limit::Float64, res)
    ref   = get(MB2018_V4, inst_name, NaN)
    delta = isnan(ref) ? NaN : (res.ttd - ref) / ref * 100.0
    open(csv_path, "a") do io
        @printf(io, "%s,%s,%d,%.1f,%d,%d,%.5f,%.5f,%.2f,%s,%.2f,%.4f,%d,%d,%d\n",
                inst_name, variant, seed, time_limit,
                Threads.nthreads(:default), Threads.nthreads(:interactive),
                res.ttd, res.fitness, res.elapsed, string(res.feasible),
                res.vol_pct, delta, res.produced, res.injected, res.rejected)
    end
end

# ── main ──────────────────────────────────────────────────────────────────────

function main()
    time_limit, seeds, variant, instances, csv_path, inst_dir = parse_cli()
    set_variant!(variant)

    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    if !isfile(csv_path)
        open(csv_path, "w") do io; println(io, CSV_HEADER); end
    end

    done = load_done_pairs(csv_path)
    total = length(instances) * length(seeds)
    n_skip = count(p -> p in done, [(replace(f, ".txt"=>""), s)
                                     for f in instances for s in seeds])

    println("Memetic benchmark  variant=$variant  time_limit=$(time_limit)s")
    println("  seeds=$(join(seeds, ","))  instances=$(length(instances))")
    println("  inst_dir=$inst_dir")
    println("  threads default=$(Threads.nthreads(:default)) interactive=$(Threads.nthreads(:interactive))")
    println("  output=$csv_path")
    println("  runs: $total total, $n_skip already done, $(total - n_skip) to run")
    println()
    flush(stdout)

    completed = 0
    for inst_file in instances
        inst_name = replace(inst_file, ".txt" => "")
        inst      = parse_instance(joinpath(inst_dir, inst_file))
        for seed in seeds
            if (inst_name, seed) in done
                println("  SKIP  $inst_name  seed=$seed  (already in CSV)")
                continue
            end
            @printf("  RUN   %-24s  seed=%d  ... ", inst_name, seed); flush(stdout)
            res = run_memetic(inst, seed, time_limit)
            append_row(csv_path, inst_name, variant, seed, time_limit, res)
            completed += 1
            @printf("ttd=%.2f  feasible=%s  vol=%.1f%%  injected=%d  (%d/%d done)\n",
                    res.ttd, string(res.feasible), res.vol_pct, res.injected,
                    completed, total - n_skip)
            flush(stdout)
        end
    end
    println("\nDone. Results written to $csv_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
