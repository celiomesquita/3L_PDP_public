# BRKGA solver for 3L-PDP using BrkgaMpIpr.jl
#
# Architecture:
#   - Chromosome: 3n float keys in [0,1)
#       genes 1..n      → rank of pickup  p_r  (position in vehicle route)
#       genes n+1..2n   → rank of delivery d_r  (position in vehicle route)
#       genes 2n+1..3n  → vehicle assignment (maps request r to vehicle k)
#   - Decoder: chromosome → interleaved PDP routes (pickup before delivery,
#              arbitrary interleaving otherwise) → packing check → penalised cost
#   - Packing: the PEAK-BY-VOLUME co-loading state is checked (the state where the
#              most cargo volume is loaded simultaneously); if it fails, all k! orderings
#              (k≤5) or O(k²) transpositions are tried (delivery-order repair).
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
const PENALTY_WEIGHT       = 1e6  # ω: penalty per unplaced item  (>> max travel cost)
const MAX_REPAIR_PERMUTE   = 5    # try all k! delivery orderings for peak loads ≤ this
const GAP_PENALTY          = Ref(7.0)  # ω_gap: penalty per unit of (d_rank - p_rank) summed over requests
#
# Chromosome layout  (3n genes in [0,1)):
#   genes      1 ..  n   pickup  rank of request r  (position in vehicle sequence)
#   genes   n+1 .. 2n   delivery rank of request r  (clamped > pickup rank)
#   genes  2n+1 .. 3n   vehicle assignment  (maps r → vehicle k)

# ── BRKGA hyper-parameters (tunable) ─────────────────────────────────────────
const POP_SIZE         = 96     # population size P
const ELITE_PCT        = 0.20   # fraction of elite individuals
const MUTANTS_PCT      = 0.15   # fraction of mutants per generation
const NUM_ELITE_PAR    = 1      # elite parents per crossover
const TOTAL_PARENTS    = 2      # total parents per crossover
const BIAS             = LOGINVERSE  # gene-inheritance bias toward elite parent
const N_POPULATIONS    = Ref(1) # independent sub-populations
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

# ── delivery-order repair ─────────────────────────────────────────────────────
# Heap's algorithm: generate all permutations of arr[1..k] and test each with
# pack_route.  Returns true as soon as a feasible ordering is found (early exit).
function _try_perms!(arr::Vector{Int}, k::Int, inst::Instance)::Bool
    if k == 1
        return pack_route(arr, inst) == 0
    end
    _try_perms!(arr, k - 1, inst) && return true
    for i in 1:k-1
        if iseven(k)
            arr[i], arr[k] = arr[k], arr[i]
        else
            arr[1], arr[k] = arr[k], arr[1]
        end
        _try_perms!(arr, k - 1, inst) && return true
    end
    return false
end

"""
    _repair_pack(reqs, inst) -> Int

Try to find any delivery ordering of `reqs` that `pack_route` accepts.
For peak loads ≤ MAX_REPAIR_PERMUTE tries all k! orderings (Heap's algorithm).
For larger peaks tries all O(k²) single transpositions and the reverse order.
Returns 0 if a feasible ordering exists, otherwise total box count (penalty proxy).
"""
function _repair_pack(reqs::Vector{Int}, inst::Instance)::Int
    isempty(reqs) && return 0
    k     = length(reqs)
    n_box = sum(length(inst.requests[r].boxes) for r in reqs)
    arr   = copy(reqs)

    if k <= MAX_REPAIR_PERMUTE
        _try_perms!(arr, k, inst) && return 0
    else
        for i in 1:k, j in i+1:k
            arr[i], arr[j] = arr[j], arr[i]
            pack_route(arr, inst) == 0 && return 0
            arr[i], arr[j] = arr[j], arr[i]
        end
        reverse!(arr)
        pack_route(arr, inst) == 0 && return 0
    end
    return n_box
end

# ── decoder ───────────────────────────────────────────────────────────────────
"""
    decode!(chromosome, pdp_inst, rewrite) -> Float64

Map a 3n-gene chromosome to a 3L-PDP solution and return its fitness.

Chromosome layout:
  genes      1..n   pickup  ranks  → position of pickup  event in vehicle sequence
  genes   n+1..2n   delivery ranks → position of delivery event (clamped > pickup)
  genes  2n+1..3n   vehicle assignment → request r goes to vehicle k

Route construction: for each vehicle the pickup and delivery events are sorted
by their rank genes, giving an interleaved PDP sequence with p_r ≺ d_r guaranteed.

Packing: the peak co-loading state is checked with pack_route in the chromosome's
delivery order.  If that fails, _repair_pack tries alternative orderings before
counting a penalty.  All working state is allocated locally (thread-safe).
"""
function decode!(chromosome::Array{Float64,1},
                 pdp_inst::PDPInstance,
                 rewrite::Bool)::Float64

    inst = pdp_inst.inst
    n    = pdp_inst.n
    K    = pdp_inst.K
    C    = pdp_inst.dist   # (2n+1)×(2n+1), index 1=depot, 2..n+1=pickups

    # ── step 1: assign requests to vehicles (genes 2n+1..3n) ─────────────────
    veh_reqs = [Int[] for _ in 1:K]
    for r in 1:n
        k = min(K, floor(Int, chromosome[2n + r] * K) + 1)
        push!(veh_reqs[k], r)
    end

    travel_cost = 0.0
    unplaced    = 0
    gap_sum     = 0.0

    for r in 1:n
        p_rank = chromosome[r]
        d_rank = chromosome[n + r]
        d_rank = d_rank > p_rank ? d_rank : p_rank + 1e-9
        gap_sum += d_rank - p_rank
    end

    for k in 1:K
        reqs = veh_reqs[k]
        isempty(reqs) && continue

        # ── step 2: build interleaved route from rank genes ───────────────────
        # genes 1..n = pickup rank, genes n+1..2n = delivery rank (clamped)
        events = Vector{Tuple{Float64,Bool,Int}}(undef, 2 * length(reqs))
        idx = 0
        for r in reqs
            p_rank = chromosome[r]
            d_rank = chromosome[n + r]
            d_rank = d_rank > p_rank ? d_rank : p_rank + 1e-9
            idx += 1; events[idx] = (p_rank, false, r)
            idx += 1; events[idx] = (d_rank, true,  r)
        end
        sort!(events; by = x -> x[1])
        route = [is_del ? -r : r for (_, is_del, r) in events]

        # ── step 3: travel cost ───────────────────────────────────────────────
        prev = 1
        for v in route
            next = v > 0 ? v + 1 : -v + n + 1
            travel_cost += C[prev, next]
            prev = next
        end
        travel_cost += C[prev, 1]

        # ── step 4: packing feasibility at peak-by-volume state ─────────────────
        # Selects the co-loading state with maximum loaded volume (not max count).
        # More correct than peak-by-count: catches volume-overflow cases while
        # keeping O(1) packing calls per vehicle so BRKGA remains navigable.
        delivery_pos = Dict{Int,Int}()
        for (pos, v) in enumerate(route)
            v < 0 && (delivery_pos[-v] = pos)
        end

        loaded       = Int[]
        peak_loaded  = Int[]
        peak_vol     = 0
        loaded_vol   = 0
        req_vols_loc = [sum(b.l * b.w * b.h for b in inst.requests[r].boxes)
                        for r in 1:length(inst.requests)]
        for v in route
            if v > 0
                push!(loaded, v)
                loaded_vol += req_vols_loc[v]
                if loaded_vol > peak_vol
                    peak_vol    = loaded_vol
                    peak_loaded = copy(loaded)
                end
            else
                loaded_vol -= req_vols_loc[-v]
                filter!(x -> x != -v, loaded)
            end
        end

        sort!(peak_loaded; by = r -> delivery_pos[r])
        pen = pack_route(peak_loaded, inst)
        if pen > 0 && length(peak_loaded) > 1
            pen = _repair_pack(peak_loaded, inst)
        end
        unplaced += pen
    end

    return travel_cost + GAP_PENALTY[] * gap_sum + PENALTY_WEIGHT * unplaced
end

# ── ALNS warm-start conversion ────────────────────────────────────────────────
"""
    alns_to_chromosome(sol, pdp) -> Vector{Float64}

Convert an ALNS PDPSolution into a BRKGA chromosome.  Rank genes are derived
from each request's position in its vehicle route; vehicle-assignment genes
map vehicle index k to the centre of the k-th interval in [0,1).
Requires alns.jl to be loaded (PDPSolution must be defined).
"""
function alns_to_chromosome(sol, pdp::PDPInstance)::Vector{Float64}
    n    = pdp.n
    K    = pdp.K
    inst = pdp.inst
    chr  = rand(3 * n)   # random fallback for any unassigned request

    req_vols = [sum(b.l * b.w * b.h for b in inst.requests[r].boxes)
                for r in 1:length(inst.requests)]

    for (k, route) in enumerate(sol.routes)
        isempty(route) && continue
        m    = length(route)   # 2 × requests in this vehicle
        reqs = Int[]

        for (pos, v) in enumerate(route)
            r    = abs(v)
            rank = (pos - 0.5) / m
            if v > 0
                chr[r] = rank
                push!(reqs, r)
            else
                chr[n + r] = rank
            end
            chr[2n + r] = (k - 0.5) / K
        end

        # Verify BRKGA's peak-by-volume packing check on this route.
        # If it fails even after repair, reset these genes to random so we
        # don't inject an infeasible chromosome into the elite population.
        delivery_pos = Dict{Int,Int}()
        for (pos, v) in enumerate(route)
            v < 0 && (delivery_pos[-v] = pos)
        end

        loaded      = Int[]
        peak_loaded = Int[]
        peak_vol    = 0
        loaded_vol  = 0
        for v in route
            if v > 0
                push!(loaded, v)
                loaded_vol += req_vols[v]
                if loaded_vol > peak_vol
                    peak_vol    = loaded_vol
                    peak_loaded = copy(loaded)
                end
            else
                loaded_vol -= req_vols[-v]
                filter!(x -> x != -v, loaded)
            end
        end

        sort!(peak_loaded; by = r -> delivery_pos[r])
        pen = pack_route(peak_loaded, inst)
        pen > 0 && length(peak_loaded) > 1 && (pen = _repair_pack(peak_loaded, inst))

        if pen > 0
            for r in reqs
                chr[r]      = rand()
                chr[n + r]  = rand()
                chr[2n + r] = rand()
            end
        end
    end
    return chr
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
    chromosome_size = 3 * n   # pickup ranks + delivery ranks + vehicle assignment

    params = BrkgaParams()
    params.population_size           = POP_SIZE
    params.elite_percentage          = ELITE_PCT
    params.mutants_percentage        = MUTANTS_PCT
    params.num_elite_parents         = NUM_ELITE_PAR
    params.total_parents             = TOTAL_PARENTS
    params.bias_type                 = BIAS
    params.num_independent_populations = N_POPULATIONS[]
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
        k = min(K, floor(Int, chr[2n + r] * K) + 1)
        push!(veh_reqs[k], r)
    end
    result = [Int[] for _ in 1:K]
    for k in 1:K
        isempty(veh_reqs[k]) && continue
        reqs = veh_reqs[k]
        events = Tuple{Float64,Bool,Int}[]
        for r in reqs
            p_rank = chr[r]
            d_rank = chr[n + r]
            d_rank = d_rank > p_rank ? d_rank : p_rank + 1e-9
            push!(events, (p_rank, false, r))
            push!(events, (d_rank, true,  r))
        end
        sort!(events; by = x -> x[1])
        result[k] = [is_del ? -r : r for (_, is_del, r) in events]
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
