# ALNS solver for 3L-PDP using MHLib.jl (v0.1)
#
# Architecture:
#   - Solution: vector of K routes; each route is an ordered sequence of
#       signed integers:  +r = pickup of request r,  -r = delivery of request r.
#       Precedence (p_r before d_r) is always maintained.
#   - Objective: total travel distance (infeasible packing → move rejected)
#   - Destroy operators: random removal, worst-cost removal, Shaw/related removal,
#                        segment removal, tour removal (all requests from one route)
#   - Repair operators:  top-k analytical marginal cost + PARALLEL packing checks;
#                        regret-2 and regret-3 insertion (à la Ropke & Pisinger 2006)
#       Candidates are scored analytically, sorted ascending, then dispatched in
#       parallel batches of K_CHECK via Threads.@threads (each thread receives its
#       own route copy — fully thread-safe).  Cheapest feasible in the first
#       successful batch is committed; if the whole list is exhausted the request
#       is forced into an empty vehicle (or appended to vehicle 1).
#   - Packing check: all co-loading states (at every pickup event) are verified
#     using the Layer/SP heuristic, consistent with a strict accept/reject policy.
#   - Operator weights updated every segment via ALNS score scheme (σ1/σ2/σ3)
#
# Usage (via main.jl):
#   julia --threads auto --project=. src/main.jl alns 050_CLUS_2_1.txt

using MHLib
using MHLib.Schedulers
using MHLib.ALNSs
using Printf
using Random

include("types.jl")
include("utils.jl")
include("packing.jl")

# ── ALNS hyper-parameters (command-line defaults are set via MHLib settings) ──
# Override via ARGS before calling solve_alns, or accept MHLib defaults:
#   --mh_titer        max iterations          (default 100 — increase for real runs)
#   --mh_ttime        time limit in seconds   (default -1 = off)
#   --mh_alns_segment_size   operator-weight update frequency (default 100)

const K_CHECK = 20   # parallel batch size for packing checks in repair_topk!

# ── solution type ─────────────────────────────────────────────────────────────
"""
    PDPSolution

Represents one complete 3L-PDP solution: an assignment of requests to vehicles
with an interleaved pickup-delivery sequence per vehicle.

Fields:
- `inst`:     the problem instance
- `dist`:     precomputed distance matrix
- `routes`:   routes[k] = ordered vector of signed ints:
                +r  → visit pickup  node of request r
                -r  → visit delivery node of request r
- `obj_val`:  cached travel cost (Inf if packing-infeasible or unset)
"""
mutable struct PDPSolution <: Solution
    inst::Instance
    dist::Matrix{Float64}
    routes::Vector{Vector{Int}}
    obj_val::Float64
end

function PDPSolution(inst::Instance)
    K     = inst.max_routes
    dist  = distance_matrix(inst)
    routes = [Int[] for _ in 1:K]
    PDPSolution(inst, dist, routes, Inf)
end

# Required MHLib.Solution interface ────────────────────────────────────────────

MHLib.obj(sol::PDPSolution) = sol.obj_val

MHLib.is_better(a::PDPSolution, b::PDPSolution) = a.obj_val < b.obj_val

function MHLib.calc_objective(sol::PDPSolution)
    sol.obj_val = _travel_cost(sol)
end

function Base.copy!(dst::PDPSolution, src::PDPSolution)
    dst.inst    = src.inst
    dst.dist    = src.dist
    dst.routes  = deepcopy(src.routes)
    dst.obj_val = src.obj_val
    dst
end

Base.copy(sol::PDPSolution) = copy!(PDPSolution(sol.inst), sol)

MHLib.check(sol::PDPSolution) = nothing

# ── route utilities ────────────────────────────────────────────────────────────

"""
    _node_idx(v, n) -> Int

Map a route node value v to its distance-matrix index.
  v > 0  (pickup  of request v)   → v + 1
  v < 0  (delivery of request |v|) → |v| + n + 1
Depot is always index 1 and is never stored in routes.
"""
@inline _node_idx(v::Int, n::Int)::Int = v > 0 ? v + 1 : -v + n + 1

"""
    _route_cost(route, dist, n) -> Float64

Travel cost of one vehicle route (depot → nodes → depot).
"""
function _route_cost(route::Vector{Int}, dist::Matrix{Float64}, n::Int)::Float64
    isempty(route) && return 0.0
    cost = dist[1, _node_idx(route[1], n)]
    for i in 2:length(route)
        cost += dist[_node_idx(route[i-1], n), _node_idx(route[i], n)]
    end
    cost += dist[_node_idx(route[end], n), 1]
    return cost
end

# ── travel cost ───────────────────────────────────────────────────────────────
function _travel_cost(sol::PDPSolution)::Float64
    n    = n_requests(sol.inst)
    dist = sol.dist
    cost = 0.0
    for route in sol.routes
        cost += _route_cost(route, dist, n)
    end
    return cost
end

# ── packing check ─────────────────────────────────────────────────────────────
"""
    _route_packing_ok(route, inst) -> Bool

Return true if every co-loading state encountered along the route is
packing-feasible under the Layer/SP heuristic (PC1–PC4).

A new co-loading state arises at each pickup event.  At that point the
current loaded set is sorted in delivery order (nearest door = earliest
delivery position) and passed to pack_route.
"""
function _route_packing_ok(route::Vector{Int}, inst::Instance)::Bool
    isempty(route) && return true

    # Pre-compute delivery position of each request within this route.
    delivery_pos = Dict{Int,Int}()
    for (pos, v) in enumerate(route)
        v < 0 && (delivery_pos[-v] = pos)
    end

    loaded = Int[]
    for v in route
        if v > 0          # pickup: add to loaded set and verify packing
            push!(loaded, v)
            sorted = sort(loaded; by = r -> delivery_pos[r])
            pack_route(sorted, inst) == 0 || return false
        else              # delivery: remove from loaded set
            filter!(x -> x != -v, loaded)
        end
    end
    return true
end

"""
    packing_feasible(sol) -> Bool

Return true if every vehicle route in sol is packing-feasible.
"""
function packing_feasible(sol::PDPSolution)::Bool
    return all(_route_packing_ok(sol.routes[k], sol.inst)
               for k in eachindex(sol.routes))
end

# ── construction heuristic ────────────────────────────────────────────────────
"""
    construct!(sol, par, result)

Build an initial solution by round-robin assignment sorted by pickup distance,
using the paired (immediate-delivery) order p_r → d_r within each vehicle.
"""
function construct!(sol::PDPSolution, par::Int, result::Result)
    inst = sol.inst
    n    = n_requests(inst)
    K    = inst.max_routes
    C    = sol.dist

    for k in 1:K; empty!(sol.routes[k]); end

    # Sort requests by pickup distance from depot
    order = sortperm(1:n; by = r -> C[1, r + 1])

    # Assign round-robin; use paired order (pickup immediately followed by delivery)
    for (i, r) in enumerate(order)
        k = ((i - 1) % K) + 1
        push!(sol.routes[k], r, -r)
    end

    calc_objective(sol)
    result.changed = true
end

# ── destroy operators ─────────────────────────────────────────────────────────
"""
    destroy_random!(sol, par, result)

Remove a random subset of requests (both pickup and delivery nodes) from their
current routes.  The removed request IDs are stashed in a temporary extra
element appended to sol.routes for retrieval by the repair operator.
"""
function destroy_random!(sol::PDPSolution, par::Int, result::Result)
    n_total   = sum(length(r) for r in sol.routes) ÷ 2  # number of requests
    n_destroy = get_number_to_destroy(n_total)
    n_destroy == 0 && return

    removed = Int[]
    for _ in 1:n_destroy
        # Collect all requests still in routes
        present = Int[]
        for route in sol.routes, v in route
            v > 0 && push!(present, v)
        end
        isempty(present) && break
        r = present[rand(1:length(present))]
        push!(removed, r)
        for route in sol.routes
            filter!(v -> v != r && v != -r, route)
        end
    end

    sol.obj_val    = Inf
    result.changed = !isempty(removed)
    push!(sol.routes, removed)   # temporary stash; popped by repair
end

"""
    destroy_worst!(sol, par, result)

Remove the n_destroy requests whose removal saves the most travel distance.
Savings are approximated by the cost of the two-node detour (pickup + delivery).
"""
function destroy_worst!(sol::PDPSolution, par::Int, result::Result)
    n_total   = sum(length(r) for r in sol.routes) ÷ 2
    n_destroy = get_number_to_destroy(n_total)
    n_destroy == 0 && return

    dist = sol.dist
    n    = n_requests(sol.inst)

    # Compute removal savings for each request
    savings = Tuple{Float64,Int}[]
    for route in sol.routes
        m = length(route)
        for (idx, v) in enumerate(route)
            v <= 0 && continue          # process only pickup entries
            r  = v
            # Nodes adjacent to pickup
            prev_p = idx == 1 ? 1 : _node_idx(route[idx-1], n)
            this_p = _node_idx(r, n)
            next_p = idx == m ? 1 : _node_idx(route[idx+1], n)
            # Find delivery index
            didx = findfirst(x -> x == -r, route)
            prev_d = didx == 1 ? 1 : _node_idx(route[didx-1], n)
            this_d = _node_idx(-r, n)
            next_d = didx == m ? 1 : _node_idx(route[didx+1], n)
            # Saving: cost removed minus bypass edges
            # (handles adjacent pickup-delivery as a special case)
            if didx == idx + 1
                saving = dist[prev_p, this_p] + dist[this_p, this_d] +
                         dist[this_d, next_d] - dist[prev_p, next_d]
            else
                saving = dist[prev_p, this_p] + dist[this_p, next_p] -
                         dist[prev_p, next_p] +
                         dist[prev_d, this_d] + dist[this_d, next_d] -
                         dist[prev_d, next_d]
            end
            push!(savings, (saving, r))
        end
    end

    sort!(savings; rev=true)
    removed     = Int[]
    removed_set = Set{Int}()
    for (_, r) in savings
        r ∈ removed_set && continue
        push!(removed, r); push!(removed_set, r)
        length(removed) >= n_destroy && break
    end

    for route in sol.routes
        filter!(v -> abs(v) ∉ removed_set, route)
    end

    sol.obj_val    = Inf
    result.changed = !isempty(removed)
    push!(sol.routes, removed)
end

"""
    destroy_shaw!(sol, par, result)

Shaw/related removal: remove a geographically related group of requests.
The first request is chosen at random; subsequent requests are chosen
preferentially from those whose pickup node is closest to the pickup of any
already-removed request, with randomness parameter φ = 3.
"""
function destroy_shaw!(sol::PDPSolution, par::Int, result::Result)
    n_total   = sum(length(r) for r in sol.routes) ÷ 2
    n_destroy = get_number_to_destroy(n_total)
    n_destroy == 0 && return

    dist = sol.dist
    n    = n_requests(sol.inst)

    # Collect all present requests
    present = Int[]
    for route in sol.routes, v in route
        v > 0 && push!(present, v)
    end
    isempty(present) && return

    # Seed with one random request
    removed     = [present[rand(1:length(present))]]
    removed_set = Set{Int}(removed)

    while length(removed) < n_destroy
        cands = [r for r in present if r ∉ removed_set]
        isempty(cands) && break

        # Score each candidate by min pickup-to-pickup distance to any removed request
        # Pickup of request r is at distance-matrix index r+1
        scores = [(minimum(dist[rem + 1, r + 1] for rem in removed), r) for r in cands]
        sort!(scores)   # ascending: most related (closest) first

        # Randomised selection with φ = 3: bias toward front of sorted list
        idx = max(1, ceil(Int, rand()^3 * length(scores)))
        push!(removed,     scores[idx][2])
        push!(removed_set, scores[idx][2])
    end

    for route in sol.routes
        filter!(v -> abs(v) ∉ removed_set, route)
    end

    sol.obj_val    = Inf
    result.changed = !isempty(removed)
    push!(sol.routes, removed)
end

# ── repair operator ────────────────────────────────────────────────────────────
"""
    repair_greedy!(sol, par, result)

Reinsert each removed request at the cheapest packing-feasible (pickup_pos,
delivery_pos) pair across all vehicles, where delivery_pos ≥ pickup_pos.
"""
function repair_greedy!(sol::PDPSolution, par::Int, result::Result)
    isempty(sol.routes) && return
    removed = pop!(sol.routes)   # retrieve the pool appended by destroy
    isempty(removed) && return

    dist = sol.dist
    n    = n_requests(sol.inst)
    K    = sol.inst.max_routes

    for r in shuffle(removed)
        best_cost = Inf
        best_k    = 1
        best_pi   = 1   # insertion index for pickup  (+r)
        best_di   = 2   # insertion index for delivery (-r)

        for k in 1:K
            route      = sol.routes[k]
            m          = length(route)
            base_cost  = _route_cost(route, dist, n)  # cost before insertion

            for pi in 1:(m + 1)
                # Insert pickup at position pi
                insert!(route, pi, r)

                for di in (pi + 1):(m + 2)   # delivery must come after pickup
                    insert!(route, di, -r)

                    if _route_packing_ok(route, sol.inst)
                        # Compare MARGINAL cost: delta vs leaving route unchanged.
                        # This correctly rewards merging r into an occupied vehicle
                        # when the detour is cheaper than a new round-trip.
                        c = _route_cost(route, dist, n) - base_cost
                        if c < best_cost
                            best_cost = c
                            best_k    = k
                            best_pi   = pi
                            best_di   = di
                        end
                    end

                    deleteat!(route, di)
                end

                deleteat!(route, pi)
            end
        end

        # Commit best insertion
        insert!(sol.routes[best_k], best_pi, r)
        insert!(sol.routes[best_k], best_di, -r)
    end

    calc_objective(sol)
    result.changed = true
end

"""
    repair_topk!(sol, par, result)

Reinsert each removed request using analytical marginal-cost ranking with
parallel packing checks.

All (k, pi, di) triples are scored analytically and sorted ascending.
Candidates are then evaluated in batches of K_CHECK using Threads.@threads:
each thread works on its own copy of the relevant route, so the function is
fully thread-safe.  The cheapest feasible candidate in the first batch that
contains any feasible insertion is committed.  If no candidate in the entire
list is feasible, the request is forced into the first empty vehicle, or
appended to vehicle 1 as a last resort.

The analytical marginal cost decomposes as:
  cost_pickup   = dist[prev_p → pickup → next_p]  − dist[prev_p → next_p]
  cost_delivery = dist[prev_d → delivery → next_d] − dist[prev_d → next_d]
where prev_d / next_d are evaluated in the route that already contains the
pickup insertion.
"""
function repair_topk!(sol::PDPSolution, par::Int, result::Result)
    isempty(sol.routes) && return
    removed = pop!(sol.routes)
    isempty(removed) && return

    dist = sol.dist
    n    = n_requests(sol.inst)
    K    = sol.inst.max_routes

    for r in shuffle(removed)
        pu = r + 1       # distance-matrix index of pickup node
        de = r + n + 1   # distance-matrix index of delivery node

        # ── enumerate all (k, pi, di) with analytical cost ─────────────────
        candidates = Tuple{Float64,Int,Int,Int}[]   # (cost, k, pi, di)

        for k in 1:K
            route = sol.routes[k]
            m     = length(route)

            for pi in 1:(m + 1)
                prev_p = pi == 1     ? 1 : _node_idx(route[pi-1], n)
                next_p = pi == m + 1 ? 1 : _node_idx(route[pi],   n)
                cost_p = dist[prev_p, pu] + dist[pu, next_p] - dist[prev_p, next_p]

                for di in (pi + 1):(m + 2)
                    if di == pi + 1
                        # delivery immediately after pickup
                        prev_d = pu
                        next_d = pi <= m ? _node_idx(route[pi], n) : 1
                    else
                        # di-1 in modified route = original route[di-2] (since pi < di-1)
                        prev_d = _node_idx(route[di-2], n)
                        next_d = di - 1 <= m ? _node_idx(route[di-1], n) : 1
                    end
                    cost_d = dist[prev_d, de] + dist[de, next_d] - dist[prev_d, next_d]
                    push!(candidates, (cost_p + cost_d, k, pi, di))
                end
            end
        end

        sort!(candidates)   # ascending: cheapest first

        # ── parallel batch evaluation ────────────────────────────────────────
        # Sweep through candidates in batches of K_CHECK.  Within each batch
        # all packing checks run concurrently; threads never share route state
        # because each check operates on a locally allocated copy.
        inserted    = false
        batch_start = 1
        n_cands     = length(candidates)

        while !inserted && batch_start <= n_cands
            batch_end = min(batch_start + K_CHECK - 1, n_cands)
            sz        = batch_end - batch_start + 1
            feasible  = fill(false, sz)

            Threads.@threads for i in 1:sz
                _, k, pi, di  = candidates[batch_start + i - 1]
                route_copy    = copy(sol.routes[k])
                insert!(route_copy, pi, r)
                insert!(route_copy, di, -r)
                feasible[i]   = _route_packing_ok(route_copy, sol.inst)
            end

            # Commit cheapest feasible in this batch (candidates are sorted,
            # so the lowest index with feasible[i] == true is the best).
            for i in 1:sz
                if feasible[i]
                    _, k, pi, di = candidates[batch_start + i - 1]
                    insert!(sol.routes[k], pi, r)
                    insert!(sol.routes[k], di, -r)
                    inserted = true
                    break
                end
            end

            batch_start += K_CHECK
        end

        # ── last resort: first empty vehicle, or append to vehicle 1 ────────
        if !inserted
            placed = false
            for k in 1:K
                if isempty(sol.routes[k])
                    push!(sol.routes[k], r, -r)
                    placed = true
                    break
                end
            end
            placed || push!(sol.routes[1], r, -r)
        end
    end

    calc_objective(sol)
    result.changed = true
end

"""
    repair_regret!(sol, par, result; regret_k)

Regret-k insertion (Ropke & Pisinger 2006, adopted by Männel & Bortfeldt 2016):
at each step, select the uninserted request with the highest regret value —
the difference in analytical insertion cost between its best and 2nd (or 3rd)
best route — and insert it into its best position using parallel packing checks.

Regret-2: ρ₂(r) = Δf(r,k₂) − Δf(r,k₁)
Regret-3: ρ₃(r) = [Δf(r,k₂) − Δf(r,k₁)] + [Δf(r,k₃) − Δf(r,k₁)]

Regret is computed on analytical (un-packed) costs so that all uninserted
requests can be evaluated cheaply; actual insertion is still verified by the
parallel packing check from repair_topk!.
"""
function repair_regret!(sol::PDPSolution, par::Int, result::Result; regret_k::Int=2)
    isempty(sol.routes) && return
    removed = pop!(sol.routes)
    isempty(removed) && return

    dist = sol.dist
    n    = n_requests(sol.inst)
    K    = sol.inst.max_routes

    remaining = collect(removed)

    while !isempty(remaining)
        best_regret   = -Inf
        best_r        = remaining[1]
        best_cands    = Tuple{Float64,Int,Int,Int}[]

        for r in remaining
            pu = r + 1
            de = r + n + 1

            # Build full candidate list (same enumeration as repair_topk!)
            cands = Tuple{Float64,Int,Int,Int}[]
            for k in 1:K
                route = sol.routes[k]
                m     = length(route)
                for pi in 1:(m+1)
                    prev_p = pi == 1   ? 1 : _node_idx(route[pi-1], n)
                    next_p = pi == m+1 ? 1 : _node_idx(route[pi],   n)
                    cost_p = dist[prev_p, pu] + dist[pu, next_p] - dist[prev_p, next_p]
                    for di in (pi+1):(m+2)
                        if di == pi+1
                            prev_d = pu
                            next_d = pi <= m ? _node_idx(route[pi], n) : 1
                        else
                            prev_d = _node_idx(route[di-2], n)
                            next_d = di-1 <= m ? _node_idx(route[di-1], n) : 1
                        end
                        cost_d = dist[prev_d, de] + dist[de, next_d] - dist[prev_d, next_d]
                        push!(cands, (cost_p + cost_d, k, pi, di))
                    end
                end
            end
            sort!(cands)

            # Best analytical cost per route
            route_best = Dict{Int,Float64}()
            for (cost, k, _, _) in cands
                if !haskey(route_best, k)
                    route_best[k] = cost   # cands is sorted → first entry per k is best
                end
            end
            sorted_costs = sort(collect(values(route_best)))

            # Regret value (Inf if only one route available — must be inserted there)
            regret = if length(sorted_costs) < 2
                Inf
            elseif regret_k == 3 && length(sorted_costs) >= 3
                (sorted_costs[2] - sorted_costs[1]) + (sorted_costs[3] - sorted_costs[1])
            else
                sorted_costs[2] - sorted_costs[1]
            end

            if regret > best_regret
                best_regret = regret
                best_r      = r
                best_cands  = cands
            end
        end

        # Insert best_r with parallel packing checks (identical to repair_topk!)
        filter!(x -> x != best_r, remaining)
        r           = best_r
        inserted    = false
        batch_start = 1
        n_cands     = length(best_cands)

        while !inserted && batch_start <= n_cands
            batch_end = min(batch_start + K_CHECK - 1, n_cands)
            sz        = batch_end - batch_start + 1
            feasible  = fill(false, sz)

            Threads.@threads for i in 1:sz
                _, k, pi, di = best_cands[batch_start + i - 1]
                route_copy   = copy(sol.routes[k])
                insert!(route_copy, pi, r)
                insert!(route_copy, di, -r)
                feasible[i]  = _route_packing_ok(route_copy, sol.inst)
            end

            for i in 1:sz
                if feasible[i]
                    _, k, pi, di = best_cands[batch_start + i - 1]
                    insert!(sol.routes[k], pi, r)
                    insert!(sol.routes[k], di, -r)
                    inserted = true
                    break
                end
            end
            batch_start += K_CHECK
        end

        if !inserted
            placed = false
            for k in 1:K
                if isempty(sol.routes[k])
                    push!(sol.routes[k], r, -r)
                    placed = true
                    break
                end
            end
            placed || push!(sol.routes[1], r, -r)
        end
    end

    calc_objective(sol)
    result.changed = true
end

function repair_regret2!(sol::PDPSolution, par::Int, result::Result)
    repair_regret!(sol, par, result; regret_k=2)
end

function repair_regret3!(sol::PDPSolution, par::Int, result::Result)
    repair_regret!(sol, par, result; regret_k=3)
end

"""
    _random_construct!(sol)

Assign all requests to vehicles in a random round-robin order with paired
(p_r immediately followed by d_r) insertion. Used as a full restart when
incremental perturbation fails to escape a local optimum.
"""
function _random_construct!(sol::PDPSolution)
    n = n_requests(sol.inst)
    K = sol.inst.max_routes
    for k in 1:K; empty!(sol.routes[k]); end
    order = shuffle(1:n)
    for (i, r) in enumerate(order)
        push!(sol.routes[((i-1) % K) + 1], r, -r)
    end
    calc_objective(sol)
end

"""
    _large_shaw_perturbation!(sol, ratio)

Remove ~ratio fraction of all requests via Shaw-related selection and
reinsert with repair_topk!.  Used to escape local optima between ALNS bursts.
"""
function _large_shaw_perturbation!(sol::PDPSolution, ratio::Float64)
    dist = sol.dist

    present = Int[]
    for route in sol.routes, v in route
        v > 0 && push!(present, v)
    end
    isempty(present) && return

    n_remove = max(1, round(Int, ratio * length(present)))

    removed     = [present[rand(1:length(present))]]
    removed_set = Set{Int}(removed)

    while length(removed) < n_remove
        cands = [r for r in present if r ∉ removed_set]
        isempty(cands) && break
        scores = [(minimum(dist[rem + 1, r + 1] for rem in removed), r) for r in cands]
        sort!(scores)
        idx = max(1, ceil(Int, rand()^3 * length(scores)))
        push!(removed,     scores[idx][2])
        push!(removed_set, scores[idx][2])
    end

    for route in sol.routes
        filter!(v -> abs(v) ∉ removed_set, route)
    end
    sol.obj_val = Inf

    push!(sol.routes, removed)
    repair_topk!(sol, 0, Result())
end

# ── Round-2 improvements ──────────────────────────────────────────────────────

"""
    _improve_delivery_order!(sol) -> Bool

Try all pairwise swaps of delivery positions within each route.
A swap (i↔j, i<j) is accepted when:
  • each delivery still comes after its own pickup (PDP precedence), and
  • the resulting route is packing-feasible, and
  • travel cost does not increase.
Repeats until no improving swap exists.  Called after each new global best.
"""
function _improve_delivery_order!(sol::PDPSolution)
    inst     = sol.inst
    n        = n_requests(inst)
    dist     = sol.dist
    improved = false

    for route in sol.routes
        count(v -> v > 0, route) < 2 && continue

        changed  = true
        max_iter = 10 * count(v -> v > 0, route)
        iter     = 0
        while changed && iter < max_iter
            iter   += 1
            changed = false
            del_pos = [(i, -route[i]) for i in eachindex(route) if route[i] < 0]
            nd = length(del_pos)

            for a in 1:nd
                found = false
                for b in (a+1):nd
                    i, r1 = del_pos[a]
                    j, r2 = del_pos[b]   # j > i always

                    pi1 = findfirst(==(r1), route)
                    pi2 = findfirst(==(r2), route)
                    (pi1 === nothing || pi2 === nothing) && continue

                    # After swap: -r2 at i, -r1 at j
                    # Need pi2 < i (r2 pickup before its new delivery)
                    # Need pi1 < j (r1 pickup before its new delivery) — always true since pi1 < i < j
                    pi2 < i || continue

                    old_cost  = _route_cost(route, dist, n)
                    route[i]  = -r2
                    route[j]  = -r1

                    if _route_packing_ok(route, inst) &&
                            _route_cost(route, dist, n) < old_cost - 1e-6
                        changed  = true
                        improved = true
                        found    = true
                        break
                    else
                        route[i] = -r1
                        route[j] = -r2
                    end
                end
                found && break
            end
        end
    end

    improved && calc_objective(sol)
    return improved
end

"""
    destroy_segment!(sol, par, result)

Remove 2–4 consecutive pickup events (and their paired deliveries) from a
randomly chosen non-empty route and reinsert via repair_topk!.
"""
function destroy_segment!(sol::PDPSolution, par::Int, result::Result)
    eligible = [k for k in eachindex(sol.routes)
                if count(v -> v > 0, sol.routes[k]) >= 2]
    isempty(eligible) && return

    k     = eligible[rand(1:length(eligible))]
    route = sol.routes[k]

    pick_pos = [i for i in eachindex(route) if route[i] > 0]
    n_picks  = length(pick_pos)
    seg_size = min(rand(2:4), n_picks)
    start    = rand(1:(n_picks - seg_size + 1))

    seg_reqs = Set(route[pick_pos[start + j - 1]] for j in 1:seg_size)
    filter!(v -> abs(v) ∉ seg_reqs, route)

    push!(sol.routes, collect(seg_reqs))
    sol.obj_val    = Inf
    result.changed = true
end

"""
    destroy_tour!(sol, par, result)

Tour removal (Männel & Bortfeldt 2016): remove ALL requests from a randomly
chosen non-empty route to force a full reassignment of that vehicle's load.
If the route contained fewer than n_destroy requests, supplement with Shaw
removal until n_destroy is reached.  Drives the search toward solutions with
different route structures, particularly effective on clustered instances.
"""
function destroy_tour!(sol::PDPSolution, par::Int, result::Result)
    n_total   = sum(length(r) for r in sol.routes) ÷ 2
    n_destroy = get_number_to_destroy(n_total)
    n_destroy == 0 && return

    eligible = [k for k in eachindex(sol.routes) if !isempty(sol.routes[k])]
    isempty(eligible) && return

    # Remove every request from the chosen route
    k       = eligible[rand(1:length(eligible))]
    removed = [v for v in sol.routes[k] if v > 0]
    empty!(sol.routes[k])
    removed_set = Set(removed)

    # Supplement with Shaw removal if route was smaller than n_destroy
    if length(removed) < n_destroy
        dist    = sol.dist
        n       = n_requests(sol.inst)
        present = [v for route in sol.routes for v in route if v > 0 && v ∉ removed_set]

        while length(removed) < n_destroy && !isempty(present)
            scores = [(minimum(dist[rem+1, r+1] for rem in removed), r) for r in present]
            sort!(scores)
            idx = max(1, ceil(Int, rand()^3 * length(scores)))
            r   = scores[idx][2]
            push!(removed, r); push!(removed_set, r)
            filter!(x -> x != r, present)
        end
        for route in sol.routes
            filter!(v -> abs(v) ∉ removed_set, route)
        end
    end

    sol.obj_val    = Inf
    result.changed = !isempty(removed)
    push!(sol.routes, removed)
end

"""
    _or_opt_between_routes!(sol) -> Bool

Try moving each single request from its current route to a better position in
any other route.  A move is accepted when:
  • the receiving route is packing-feasible after insertion, and
  • total travel cost strictly decreases.
Repeats until no improving inter-route move exists.  Called after each new
global best alongside _improve_delivery_order!.
"""
function _or_opt_between_routes!(sol::PDPSolution)
    inst = sol.inst
    n    = n_requests(inst)
    dist = sol.dist
    K    = inst.max_routes
    improved = false

    changed = true
    max_iter = 10 * n   # hard cap: at most 10 passes per request
    iter = 0
    while changed && iter < max_iter
        iter += 1
        changed = false
        for k1 in 1:K
            route1 = sol.routes[k1]
            isempty(route1) && continue

            for r in [v for v in route1 if v > 0]
                # Cost saving from removing r from route1
                stripped1 = filter(v -> v != r && v != -r, route1)
                gain1 = _route_cost(route1, dist, n) - _route_cost(stripped1, dist, n)

                best_delta = 1e-4   # must save strictly more than this (avoids float cycling)
                best_k2    = -1
                best_r2    = nothing

                pu = r + 1
                de = r + n + 1

                for k2 in 1:K
                    k2 == k1 && continue
                    route2 = sol.routes[k2]
                    m2     = length(route2)

                    for pi in 1:(m2 + 1)
                        prev_p = pi == 1  ? 1 : _node_idx(route2[pi-1], n)
                        next_p = pi > m2  ? 1 : _node_idx(route2[pi],   n)
                        cost_p = dist[prev_p, pu] + dist[pu, next_p] - dist[prev_p, next_p]

                        for di in (pi+1):(m2+2)
                            prev_d = di == pi+1 ? pu : _node_idx(route2[di-2], n)
                            next_d = di <= m2+1 ? _node_idx(route2[di-1], n) : 1
                            cost_d = dist[prev_d, de] + dist[de, next_d] - dist[prev_d, next_d]

                            savings = gain1 - cost_p - cost_d
                            if savings > best_delta
                                candidate2 = copy(route2)
                                insert!(candidate2, pi, r)
                                insert!(candidate2, di, -r)
                                if _route_packing_ok(candidate2, inst)
                                    best_delta = savings
                                    best_k2    = k2
                                    best_r2    = candidate2
                                end
                            end
                        end
                    end
                end

                if best_k2 >= 0
                    sol.routes[k1]    = stripped1
                    sol.routes[best_k2] = best_r2
                    route1   = sol.routes[k1]
                    improved = true
                    changed  = true
                    break   # restart scan of k1's requests
                end
            end
        end
    end

    improved && calc_objective(sol)
    return improved
end

# ── main solver ───────────────────────────────────────────────────────────────
"""
    solve_alns(inst; time_limit) -> Nothing

Run ALNS on a 3L-PDP instance using MHLib and print the best solution found.
"""
function solve_alns(inst::Instance; time_limit::Float64 = 300.0, seed::Int = -1)
    seed >= 0 && Random.seed!(seed)

    n = n_requests(inst)
    K = inst.max_routes
    println("Building ALNS  |  n=$n  K=$K  time_limit=$(time_limit)s")

    BURST_TIME  = 15.0   # wall-clock seconds per ALNS burst
    BASE_RATIO  = 0.40   # base Shaw perturbation fraction on rejection
    MAX_RATIO   = 0.70   # ceiling for escalating perturbation

    # Meta SA (between-burst Metropolis: accept burst result even if worse than global best)
    # Greedy acceptance is kept within each burst so that burst descent converges to a
    # good local optimum efficiently; meta-SA then decides whether to start the next burst
    # from that (possibly worse) local optimum or from the global best.
    # Temperature cools by META_COOLING after each burst, from obj * META_TEMP_FACTOR.
    # With META_COOLING=0.85 the SA is active for roughly the first half of the run and
    # freezes gradually thereafter, balancing exploration with exploitation.
    META_TEMP_FACTOR = 0.02    # meta_temp = obj(init) * 0.02
    META_COOLING     = 0.85    # multiplicative cooling per burst

    MAX_BURSTS_NO_GLOBAL = 8   # early-stop after this many bursts with no global improvement

    # ── initial solution ───────────────────────────────────────────────────────
    init_sol = PDPSolution(inst)
    construct!(init_sol, 0, Result())

    best_sol    = copy(init_sol)
    current_sol = copy(init_sol)
    n_restarts       = 0
    bursts_no_global = 0
    meta_temp        = obj(init_sol) * META_TEMP_FACTOR
    reset_pack_counters!()
    t0 = time()

    # ── meta-loop: ALNS bursts with two-level SA ───────────────────────────────
    while (elapsed = time() - t0) < time_limit
        remaining  = time_limit - elapsed
        burst_secs = min(BURST_TIME, remaining)
        burst_secs < 1.0 && break

        ttime = Int(floor(burst_secs))
        MHLib.parse_settings!(MHLib.all_settings_cfgs,
            ["--mh_titer=-1", "--mh_ttime=$ttime",
             "--mh_alns_dest_max_ratio=0.5"])

        # Seed each burst from current_sol
        start   = copy(current_sol)
        init_fn = (s::PDPSolution, par::Int, res::Result) ->
                      (copy!(s, start); res.changed = true)

        meths_ch = [MHMethod("init",          init_fn,          0)]
        meths_de = [MHMethod("destroy_rand",  destroy_random!,  0),
                    MHMethod("destroy_worst", destroy_worst!,   0),
                    MHMethod("destroy_shaw",  destroy_shaw!,    0),
                    MHMethod("destroy_seg",   destroy_segment!, 0),
                    MHMethod("destroy_tour",  destroy_tour!,    0)]
        meths_re = [MHMethod("repair_topk",   repair_topk!,    0),
                    MHMethod("repair_regret2", repair_regret2!, 0),
                    MHMethod("repair_regret3", repair_regret3!, 0)]

        alns = ALNS(PDPSolution(inst), meths_ch, meths_de, meths_re, false)
        run!(alns)

        burst_best = alns.scheduler.incumbent

        # Always update global best if improved
        if obj(burst_best) < obj(best_sol)
            copy!(best_sol, burst_best)
            _improve_delivery_order!(best_sol)
            _or_opt_between_routes!(best_sol)
            bursts_no_global = 0
            @printf "  burst: new best=%.4f  (meta_T=%.2f)\n" obj(best_sol) meta_temp
        else
            bursts_no_global += 1
        end

        # Early stop if consistently no global improvement
        if bursts_no_global >= MAX_BURSTS_NO_GLOBAL
            @printf "  → early stop: %d bursts with no global improvement (best=%.4f)\n" bursts_no_global obj(best_sol)
            break
        end

        # Meta-SA: decide starting point for next burst via Metropolis criterion
        delta = obj(burst_best) - obj(best_sol)   # >= 0
        if delta <= 0.0 || rand() <= exp(-delta / max(meta_temp, 1e-9))
            # Accept burst result (improving or SA-accepted worsening)
            current_sol = copy(burst_best)
            delta > 0 && @printf "  burst: SA accept  sol=%.4f  Δ=+%.2f  T=%.2f\n" obj(burst_best) delta meta_temp
        else
            # Reject: perturb from global best and escalate diversity
            n_restarts += 1
            current_sol = copy(best_sol)
            ratio = min(MAX_RATIO, BASE_RATIO + 0.10 * (n_restarts - 1))
            _large_shaw_perturbation!(current_sol, ratio)
            @printf "  burst: SA reject  restart #%d  shaw %.0f%%  T=%.2f\n" n_restarts (ratio*100) meta_temp
        end

        meta_temp *= META_COOLING
    end

    total_time = time() - t0
    n_calls, n_feasible = get_pack_counts()
    pce = n_calls > 0 ? round(n_feasible / n_calls; digits=4) : 0.0
    println("\nALNS finished  ($(n_restarts) rejections,  $(round(total_time; digits=1))s)")
    println("Best objective : $(round(obj(best_sol); digits=4))")
    println("Pack calls: $n_calls  feasible: $n_feasible  PCE: $pce")
    _print_alns_solution(best_sol)
    return obj(best_sol), total_time, n_calls, n_feasible
end

# ── solution printer ───────────────────────────────────────────────────────────
function _print_alns_solution(sol::PDPSolution)
    println("\nBest solution routes:")
    for (k, route) in enumerate(sol.routes)
        isempty(route) && continue
        seq_str = join([(v > 0 ? "p$v" : "d$(-v)") for v in route], "→")
        println("  Vehicle $k: depot→$(seq_str)→depot")
    end
end
