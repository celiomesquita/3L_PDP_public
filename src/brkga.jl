# BRKGA solver for 3L-PDP using BrkgaMpIpr.jl
#
# Architecture:
#   - Chromosome: 3n float keys in [0,1)
#       genes 1..n      → rank of pickup  p_r  (position in vehicle route)
#       genes n+1..2n   → rank of delivery d_r  (position in vehicle route)
#       genes 2n+1..3n  → vehicle assignment (maps request r to vehicle k)
#   - Decoder: chromosome → interleaved PDP routes (pickup before delivery,
#              arbitrary interleaving otherwise) → packing check → penalised cost
#   - Packing: only the PEAK co-loading state on each route is checked; requests
#              in that state are passed to pack_route in their delivery order.
#   - Fitness:  F = TravelCost + ω × unplaced_items   (minimise)
#   - Parallel evaluation: BrkgaMpIpr calls the decoder; thread-safety is
#     guaranteed because each call allocates all working state locally.
#
# Usage (via main.jl):
#   julia --threads auto --project=. src/main.jl brkga 050_CLUS_2_1.txt

using BrkgaMpIpr
using Printf

include("types.jl")
include("utils.jl")
include("packing.jl")

# ── constants ─────────────────────────────────────────────────────────────────
const PENALTY_WEIGHT = 1e6   # ω: penalty per unplaced item  (>> max travel cost)

# ── BRKGA hyper-parameters (tunable) ─────────────────────────────────────────
const POP_SIZE         = 256    # population size P
const ELITE_PCT        = 0.20   # fraction of elite individuals
const MUTANTS_PCT      = 0.15   # fraction of mutants per generation
const NUM_ELITE_PAR    = 1      # elite parents per crossover
const TOTAL_PARENTS    = 2      # total parents per crossover
const BIAS             = LOGINVERSE  # gene-inheritance bias toward elite parent
const N_POPULATIONS    = 1      # independent sub-populations
const MAX_GENERATIONS  = 100_000  # large; time_limit (300 s) is the effective stop
const SEED             = 42

# ── instance wrapper (BrkgaMpIpr requires AbstractInstance) ──────────────────
struct PDPInstance <: AbstractInstance
    inst::Instance
    n::Int               # number of requests
    K::Int               # number of vehicles
    dist::Matrix{Float64} # precomputed distance matrix
end

function PDPInstance(inst::Instance)
    PDPInstance(inst, n_requests(inst), inst.max_routes, distance_matrix(inst))
end

# ── nearest-neighbour tour construction ───────────────────────────────────────
"""
    _nn_tour(reqs, n, C) -> Vector{Int}

Build a pickup-delivery tour for the given requests using nearest-neighbour.
At each step the closest unvisited pickup OR the closest pending delivery is
chosen.  Returns a signed-integer route: +r = pickup of r, -r = delivery of r.
Runs in O(|reqs|²) — fast for typical route lengths of 5–15 requests.
"""
function _nn_tour(reqs::Vector{Int}, n::Int, C::Matrix{Float64})::Vector{Int}
    unvisited = Set(reqs)
    pending   = Set{Int}()
    route     = Int[]
    cur       = 1    # depot index in distance matrix

    while !isempty(unvisited) || !isempty(pending)
        best_v = 0
        best_c = Inf
        for r in unvisited               # consider pickups
            c = C[cur, r + 1]
            c < best_c && (best_c = c; best_v = r)
        end
        for r in pending                 # consider eligible deliveries
            c = C[cur, r + n + 1]
            c < best_c && (best_c = c; best_v = -r)
        end
        push!(route, best_v)
        if best_v > 0
            delete!(unvisited, best_v)
            push!(pending, best_v)
            cur = best_v + 1
        else
            delete!(pending, -best_v)
            cur = (-best_v) + n + 1
        end
    end
    return route
end

# ── decoder ───────────────────────────────────────────────────────────────────
"""
    decode!(chromosome, pdp_inst, rewrite) -> Float64

Map a chromosome to a 3L-PDP solution and return its fitness (travel cost +
penalty for packing violations).

Chromosome layout (n genes):
  gene r  — vehicle assignment for request r  (maps to vehicle min(K, ⌊K·gene⌋+1))

Route construction: for each vehicle, a nearest-neighbour tour is built over
its assigned requests, respecting pickup-before-delivery precedence.  NN
routing produces much shorter routes than random-rank ordering and allows the
BRKGA to focus its evolution on vehicle assignment (the high-level clustering
decision) rather than wasting budget on low-level node orderings.

Packing: the peak co-loading state on each vehicle is checked; requests in
that state are passed to pack_route sorted by delivery order.  All working
state is allocated locally so the function is thread-safe.
"""
function decode!(chromosome::Array{Float64,1},
                 pdp_inst::PDPInstance,
                 rewrite::Bool)::Float64

    inst = pdp_inst.inst
    n    = pdp_inst.n
    K    = pdp_inst.K
    C    = pdp_inst.dist   # (2n+1)×(2n+1), index 1=depot, 2..n+1=pickups

    # ── step 1: assign requests to vehicles ──────────────────────────────────
    veh_reqs = [Int[] for _ in 1:K]
    for r in 1:n
        k = min(K, floor(Int, chromosome[r] * K) + 1)
        push!(veh_reqs[k], r)
    end

    travel_cost = 0.0
    unplaced    = 0

    for k in 1:K
        reqs = veh_reqs[k]
        isempty(reqs) && continue

        # ── step 2: build route via nearest-neighbour ─────────────────────
        route = _nn_tour(reqs, n, C)

        # ── step 3: travel cost ───────────────────────────────────────────
        prev = 1
        for v in route
            next = v > 0 ? v + 1 : -v + n + 1
            travel_cost += C[prev, next]
            prev = next
        end
        travel_cost += C[prev, 1]

        # ── step 4: packing feasibility of peak co-loading state ─────────
        delivery_pos = Dict{Int,Int}()
        for (pos, v) in enumerate(route)
            v < 0 && (delivery_pos[-v] = pos)
        end

        loaded      = Int[]
        peak_loaded = Int[]
        for v in route
            if v > 0
                push!(loaded, v)
                if length(loaded) > length(peak_loaded)
                    peak_loaded = copy(loaded)
                end
            else
                filter!(x -> x != -v, loaded)
            end
        end

        sort!(peak_loaded; by = r -> delivery_pos[r])
        unplaced += pack_route(peak_loaded, inst)
    end

    return travel_cost + PENALTY_WEIGHT * unplaced
end

# ── main solver ───────────────────────────────────────────────────────────────
"""
    solve_brkga(inst; max_generations, seed, time_limit) -> Nothing

Run the parallel BRKGA on a 3L-PDP instance and print the best solution found.
"""
function solve_brkga(inst::Instance;
                     max_generations::Int     = MAX_GENERATIONS,
                     seed::Int                = SEED,
                     time_limit::Float64      = 300.0)

    pdp_inst = PDPInstance(inst)
    n        = pdp_inst.n
    chromosome_size = n   # one gene per request: vehicle assignment

    params = BrkgaParams()
    params.population_size           = POP_SIZE
    params.elite_percentage          = ELITE_PCT
    params.mutants_percentage        = MUTANTS_PCT
    params.num_elite_parents         = NUM_ELITE_PAR
    params.total_parents             = TOTAL_PARENTS
    params.bias_type                 = BIAS
    params.num_independent_populations = N_POPULATIONS
    params.pr_number_pairs           = 0
    params.pr_minimum_distance       = 0.15
    params.pr_type                   = BrkgaMpIpr.DIRECT
    params.pr_selection              = BrkgaMpIpr.BESTSOLUTION
    params.alpha_block_size          = 1.0
    params.pr_percentage             = 0.35

    println("Building BRKGA  |  n=$n  K=$(pdp_inst.K)  " *
            "chromosome=$chromosome_size genes  pop=$POP_SIZE  " *
            "threads=$(Threads.nthreads())")

    brkga_data = build_brkga(pdp_inst, decode!, BrkgaMpIpr.MINIMIZE, seed,
                             chromosome_size, params)
    BrkgaMpIpr.initialize!(brkga_data)

    WARM_AFTER   = 500   # stagnant gens → warm restart (perturb 20% of genes)
    WARM_MAX     = 2     # warm restarts per hard-reset cycle before giving up
    RESET_AFTER  = (WARM_MAX + 1) * WARM_AFTER   # gens before hard reset

    best          = Inf
    best_chr      = nothing
    stagnant      = 0
    cycle_warms   = 0   # warm restarts in current hard-reset cycle
    n_warms       = 0
    n_resets      = 0
    t_start     = time()
    gen         = 0

    while gen < max_generations && (time() - t_start) < time_limit
        evolve!(brkga_data, 1)
        gen += 1
        fitness = get_best_fitness(brkga_data)

        if fitness < best
            best        = fitness
            best_chr    = copy(get_best_chromosome(brkga_data))
            stagnant    = 0
            cycle_warms = 0
            elapsed     = round(time() - t_start; digits=1)
            @printf("  gen %5d  |  fitness = %.4f  |  %.1f s\n", gen, best, elapsed)
        else
            stagnant += 1
            if stagnant >= RESET_AFTER
                # Hard restart: randomise all, reinject incumbent at elite pos 1
                n_resets   += 1
                cycle_warms = 0
                reset!(brkga_data)
                BrkgaMpIpr.initialize!(brkga_data)
                inject_chromosome!(brkga_data, best_chr, 1, 1, best)
                stagnant = 0
                @printf("  gen %5d  |  HARD RESET #%d  (best=%.4f)\n",
                        gen, n_resets, best)
            elseif stagnant % WARM_AFTER == 0 && cycle_warms < WARM_MAX
                # Warm restart: inject perturbed incumbent
                n_warms     += 1
                cycle_warms += 1
                stagnant     = 0   # reset counter within the cycle
                perturbed = copy(best_chr)
                for i in eachindex(perturbed)
                    rand() < 0.15 && (perturbed[i] = rand())
                end
                inject_chromosome!(brkga_data, perturbed, 1, 2)
                @printf("  gen %5d  |  warm      #%d  (best=%.4f)\n",
                        gen, n_warms, best)
            end
        end
    end

    elapsed = round(time() - t_start; digits=1)
    println("\nBRKGA finished: $(gen) generations  $(n_warms) warm  " *
            "$(n_resets) hard resets  $(elapsed) s")
    println("Best fitness   : $(round(best; digits=4))")

    best_chr = get_best_chromosome(brkga_data)

    # ── post-processing (requires PDPSolution from alns.jl) ───────────────────
    if @isdefined(PDPSolution)
        sol = PDPSolution(pdp_inst.inst)
        sol.routes  = _chromosome_to_pdp_routes(best_chr, pdp_inst)
        sol.obj_val = _travel_cost(sol)
        println("Post-process start  ttd = $(round(sol.obj_val; digits=2))")
        _improve_delivery_order!(sol)
        _or_opt_between_routes!(sol)
        println("Post-process done   ttd = $(round(sol.obj_val; digits=2))")
        n = pdp_inst.n
        println("\nBest solution routes (post-processed):")
        for (k, route) in enumerate(sol.routes)
            isempty(route) && continue
            seq = join([(v > 0 ? "p$v" : "d$(-v)") for v in route], "→")
            println("  Vehicle $k: depot→$(seq)→depot")
        end
    else
        _print_brkga_solution(best_chr, pdp_inst)
    end
end

# ── chromosome → ALNS-format signed-int routes ───────────────────────────────
"""
    _chromosome_to_pdp_routes(chr, pdp) -> Vector{Vector{Int}}

Decode a BRKGA chromosome into the signed-integer route format used by the
ALNS solver:  +r = pickup of request r,  -r = delivery of request r.
"""
function _chromosome_to_pdp_routes(chr::Vector{Float64},
                                    pdp::PDPInstance)::Vector{Vector{Int}}
    n = pdp.n; K = pdp.K
    veh_reqs = [Int[] for _ in 1:K]
    for r in 1:n
        k = min(K, floor(Int, chr[r] * K) + 1)
        push!(veh_reqs[k], r)
    end
    result = [Int[] for _ in 1:K]
    for k in 1:K
        isempty(veh_reqs[k]) && continue
        result[k] = _nn_tour(veh_reqs[k], n, pdp.dist)
    end
    return result
end

# ── solution printer ──────────────────────────────────────────────────────────
function _print_brkga_solution(chromosome::Vector{Float64}, pdp_inst::PDPInstance)
    n = pdp_inst.n
    K = pdp_inst.K

    routes = [Int[] for _ in 1:K]
    for r in 1:n
        k = min(K, floor(Int, chromosome[2n + r] * K) + 1)
        push!(routes[k], r)
    end

    println("\nBest solution routes (interleaved PDP order):")
    for k in 1:K
        isempty(routes[k]) && continue
        reqs = routes[k]

        node_seq = Tuple{Float64,Bool,Int}[]
        for r in reqs
            p_rank = chromosome[r]
            d_rank = chromosome[n + r]
            d_rank = d_rank > p_rank ? d_rank : p_rank + 1e-9
            push!(node_seq, (p_rank, false, r))
            push!(node_seq, (d_rank, true,  r))
        end
        sort!(node_seq; by = x -> x[1])

        seq_str = join([(is_del ? "d$r" : "p$r") for (_, is_del, r) in node_seq], "→")
        println("  Vehicle $k: depot→$(seq_str)→depot")
    end
end
