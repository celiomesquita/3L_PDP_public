# MIP model for the 3L-PDP using JuMP + HiGHS.
#
# Purpose: exact formulation for validating the mathematical model on small subsets.
#          Not a production solver — see solution method section of the paper.
#
# Index conventions (all 1-based in Julia):
#   nodes   : 1 = depot, 2..n+1 = pickup p_r, n+2..2n+1 = delivery d_r
#   vehicles: 1..K
#   requests: 1..n
#   items   : global flat index 1..S over all boxes
#
# Variable groups and approximate counts for n requests, S items, K vehicles:
#   x[i,j,k]          routing arcs          — (2n+1)² · K binary
#   u[i,k]            MTZ positions          — 2n · K continuous
#   y[r,k]            request-vehicle assign — n · K binary
#   a,b,c[s]          item positions         — 3S continuous
#   delta[s,t,u]       non-overlap indicators — 6·S(S-1)/2 binary
#   same_veh[s,t]      co-vehicle indicator  — S(S-1)/2 binary
#   ord[r,rp,k]       delivery order         — n(n-1)·K binary
#   ppd[r,rp,k]       co-load indicator      — n(n-1)·K binary
#   blocking[r,rp,k]  LIFO trigger           — n(n-1)·K binary
#
# Observed (n=4, S=10, K=4): 1721 constraints, 825 variables (763 binary).
# Solve time ~200 s on Intel Xeon E3-1225 v6 / 32 GiB / HiGHS 1.13.1.
# Optimal objective: 258.28 (all 4 requests on one vehicle, LIFO binding).
#
# Constraint labels match the manuscript problem formulation (PC1–PC7).

using JuMP
using HiGHS

include("types.jl")
include("utils.jl")

# ---------------------------------------------------------------------------
# Helper: build a flat item list with the owning request index
# ---------------------------------------------------------------------------
struct ItemInfo
    req::Int       # request index (1..n)
    box::Box
end

function build_items(inst::Instance)::Vector{ItemInfo}
    items = ItemInfo[]
    for (r, req) in enumerate(inst.requests)
        for b in req.boxes
            push!(items, ItemInfo(r, b))
        end
    end
    return items
end

# ---------------------------------------------------------------------------
# Main model builder
# ---------------------------------------------------------------------------
function build_model(inst::Instance; time_limit::Float64 = 300.0)
    n = n_requests(inst)
    K = inst.max_routes
    C = distance_matrix(inst)   # (2n+1)×(2n+1), 1-based

    # Node indices (1-based)
    DEPOT = 1
    pickup(r)   = r + 1         # node index of pickup of request r
    delivery(r) = n + r + 1     # node index of delivery of request r
    ALL_NODES   = 1:(2n + 1)
    PD_NODES    = 2:(2n + 1)    # all non-depot nodes
    P_NODES     = 2:(n + 1)     # pickup nodes
    D_NODES     = (n + 2):(2n + 1)  # delivery nodes

    items = build_items(inst)
    S     = length(items)

    # Big-M values
    M_u   = Float64(2n)         # for MTZ position variables
    M_Lv  = Float64(inst.Lv)
    M_Wv  = Float64(inst.Wv)
    M_Hv  = Float64(inst.Hv)
    M_ord = M_u                 # for ord linking constraint

    # -----------------------------------------------------------------------
    model = Model(HiGHS.Optimizer)
    set_attribute(model, "time_limit", time_limit)
    set_attribute(model, "output_flag", true)

    # -----------------------------------------------------------------------
    # VARIABLES
    # -----------------------------------------------------------------------

    # Routing: x[i,j,k] = 1 if vehicle k traverses arc (i→j)
    @variable(model, x[i=ALL_NODES, j=ALL_NODES, k=1:K; i != j], Bin)

    # MTZ position of node i on vehicle k's route (1..2n for non-depot)
    @variable(model, 0 <= u[i=PD_NODES, k=1:K] <= M_u)

    # Request-vehicle assignment: y[r,k] = 1 if request r on vehicle k
    @variable(model, y[1:n, 1:K], Bin)

    # 3D packing positions (rear-bottom-left corner of each item)
    @variable(model, 0 <= a[1:S] <= inst.Lv)
    @variable(model, 0 <= b[1:S] <= inst.Wv)
    @variable(model, 0 <= c[1:S] <= inst.Hv)

    # Non-overlap indicators: δ[s,t,u] for each ordered pair (s<t), direction u∈1..6
    # We define δ for s < t only (symmetric pairs)
    pairs = [(s, t) for s in 1:S for t in (s+1):S]
    @variable(model, delta[pairs, 1:6], Bin)

    # LIFO ordering: ord[r,rp,k] = 1 if delivery of r comes before delivery of rp on vehicle k
    req_pairs = [(r, rp) for r in 1:n for rp in 1:n if r != rp]
    @variable(model, ord[req_pairs, 1:K], Bin)

    # -----------------------------------------------------------------------
    # OBJECTIVE  (eq:obj)
    # -----------------------------------------------------------------------
    @objective(model, Min,
        sum(C[i, j] * x[i, j, k]
            for i in ALL_NODES, j in ALL_NODES, k in 1:K if i != j))

    # -----------------------------------------------------------------------
    # ROUTING CONSTRAINTS
    # -----------------------------------------------------------------------

    # (eq:visit) Each pickup and delivery node visited exactly once
    for i in PD_NODES
        @constraint(model,
            sum(x[i, j, k] for j in ALL_NODES, k in 1:K if j != i) == 1)
    end

    # (eq:flow) Flow conservation at non-depot nodes
    for i in PD_NODES, k in 1:K
        @constraint(model,
            sum(x[j, i, k] for j in ALL_NODES if j != i) ==
            sum(x[i, j, k] for j in ALL_NODES if j != i))
    end

    # (eq:depot-out) Each vehicle leaves depot at most once
    for k in 1:K
        @constraint(model,
            sum(x[DEPOT, j, k] for j in PD_NODES) <= 1)
    end

    # (eq:depot-in) Each vehicle returns to depot at most once
    for k in 1:K
        @constraint(model,
            sum(x[i, DEPOT, k] for i in PD_NODES) <= 1)
    end

    # -----------------------------------------------------------------------
    # ASSIGNMENT LINKING: y[r,k] ↔ x  (eq:precedence, same-vehicle part)
    # -----------------------------------------------------------------------
    # y[r,k] = 1 iff vehicle k visits pickup node of request r
    for r in 1:n, k in 1:K
        @constraint(model,
            sum(x[pickup(r), j, k] for j in ALL_NODES if j != pickup(r)) == y[r, k])
    end

    # y[r,k] = 1 iff vehicle k visits delivery node of request r (same vehicle for both ends)
    for r in 1:n, k in 1:K
        @constraint(model,
            sum(x[delivery(r), j, k] for j in ALL_NODES if j != delivery(r)) == y[r, k])
    end

    # Each request assigned to exactly one vehicle
    for r in 1:n
        @constraint(model, sum(y[r, k] for k in 1:K) == 1)
    end

    # -----------------------------------------------------------------------
    # PRECEDENCE: pickup before delivery on same vehicle  (eq:precedence)
    # -----------------------------------------------------------------------
    for r in 1:n, k in 1:K
        @constraint(model,
            u[pickup(r), k] + 1 <= u[delivery(r), k] + M_u * (1 - y[r, k]))
    end

    # -----------------------------------------------------------------------
    # MTZ SUBTOUR ELIMINATION  (eq:subtour)
    # -----------------------------------------------------------------------
    for i in PD_NODES, j in PD_NODES, k in 1:K
        i == j && continue
        @constraint(model,
            u[i, k] - u[j, k] + M_u * x[i, j, k] <= M_u - 1)
    end
    # Position bounds for active nodes
    for i in PD_NODES, k in 1:K
        @constraint(model, u[i, k] >= 1)
    end

    # -----------------------------------------------------------------------
    # WEIGHT CAPACITY  (eq:weight)
    # -----------------------------------------------------------------------
    for k in 1:K
        @constraint(model,
            sum(inst.requests[r].total_weight * y[r, k] for r in 1:n) <= inst.Q)
    end

    # -----------------------------------------------------------------------
    # 3D PACKING: BOUNDS  (eq:bounds)
    # -----------------------------------------------------------------------
    for (s, it) in enumerate(items)
        set_upper_bound(a[s], inst.Lv - it.box.l)
        set_upper_bound(b[s], inst.Wv - it.box.w)
        set_upper_bound(c[s], inst.Hv - it.box.h)
    end

    # -----------------------------------------------------------------------
    # 3D PACKING: NON-OVERLAP  (eq:no1 – eq:no7)
    #
    # For items on different vehicles, no packing constraint is needed.
    # We enforce non-overlap only when items share a vehicle, using a guard:
    #   same_veh[s,t] = Σ_k w[s,k]*w[t,k]  (1 iff same vehicle)
    # To avoid products of variables we introduce same_veh[s,t] as a binary
    # and link it to the item-vehicle assignment w[s,k] (derived from y).
    # -----------------------------------------------------------------------

    # Item-vehicle assignment: w[s,k] = y[r,k] where r = items[s].req
    # (no new variable needed — just an alias used in constraints)
    w(s, k) = y[items[s].req, k]

    # Auxiliary: same_veh[s,t] ∈ {0,1}
    @variable(model, same_veh[pairs], Bin)
    for (s, t) in pairs
        for k in 1:K
            # same_veh[s,t] >= w[s,k] + w[t,k] - 1
            @constraint(model, same_veh[(s,t)] >= w(s,k) + w(t,k) - 1)
        end
        # same_veh[s,t] <= w[s,k] + w[t,k]  for all k — handled by upper bound 1
        # and: same_veh[s,t] <= 1/K * Σ_k (w[s,k] + w[t,k])  (tighter but not needed)
    end

    # Non-overlap big-M constraints
    for (s, t) in pairs
        ls, ws_s, hs = items[s].box.l, items[s].box.w, items[s].box.h
        lt, ws_t, ht = items[t].box.l, items[t].box.w, items[t].box.h

        # When same_veh = 0, RHS is relaxed (≥ negative number), so no binding effect.
        # When same_veh = 1, exactly one δ must hold.
        guard = same_veh[(s, t)]

        # (eq:no1)  s left of t
        @constraint(model, a[s] + ls <= a[t] + M_Lv * (1 - delta[(s,t), 1]))
        # (eq:no2)  t left of s
        @constraint(model, a[t] + lt <= a[s] + M_Lv * (1 - delta[(s,t), 2]))
        # (eq:no3)  s front of t
        @constraint(model, b[s] + ws_s <= b[t] + M_Wv * (1 - delta[(s,t), 3]))
        # (eq:no4)  t front of s
        @constraint(model, b[t] + ws_t <= b[s] + M_Wv * (1 - delta[(s,t), 4]))
        # (eq:no5)  s below t
        @constraint(model, c[s] + hs <= c[t] + M_Hv * (1 - delta[(s,t), 5]))
        # (eq:no6)  t below s
        @constraint(model, c[t] + ht <= c[s] + M_Hv * (1 - delta[(s,t), 6]))
        # (eq:no7)  at least one separator active when co-loaded
        @constraint(model,
            sum(delta[(s,t), u] for u in 1:6) >= guard)
    end

    # -----------------------------------------------------------------------
    # LIFO CONSTRAINTS  (eq:lifo)
    #
    # Convention: door at a = 0, cab at a = Lv.
    # Request rp BLOCKS request r when both are on vehicle k and:
    #   (a) pickup of rp comes before delivery of r  → ppd[(r,rp),k] = 1
    #   (b) delivery of r comes before delivery of rp → ord[(r,rp),k] = 1
    # Combined: p_rp < d_r < d_rp  (rp is loaded when r is unloaded).
    # When rp blocks r: items of r must be closer to the door (smaller a).
    # -----------------------------------------------------------------------

    # --- ord: delivery of r before delivery of rp (forced to reflect route order) ---
    for (r, rp) in req_pairs, k in 1:K
        @constraint(model, ord[(r,rp), k] <= y[r, k])
        @constraint(model, ord[(r,rp), k] <= y[rp, k])
        # If ord=1: d_r strictly before d_rp  (MTZ positions are integers → use -1)
        @constraint(model,
            u[delivery(r), k] - u[delivery(rp), k] <=
            -1 + M_ord * (1 - ord[(r, rp), k]) + M_ord * (2 - y[r, k] - y[rp, k]))
        # Force ord=1 when d_r before d_rp: if ord=0 and both on k → d_rp ≤ d_r
        @constraint(model,
            u[delivery(rp), k] - u[delivery(r), k] <=
            M_ord * ord[(r, rp), k] + M_ord * (2 - y[r, k] - y[rp, k]))
    end
    # Antisymmetry: at most one direction per vehicle
    for r in 1:n, rp in (r+1):n, k in 1:K
        @constraint(model, ord[(r,rp), k] + ord[(rp,r), k] <= 1)
    end

    # --- ppd: pickup of rp comes before delivery of r on vehicle k ---
    @variable(model, ppd[req_pairs, 1:K], Bin)
    for (r, rp) in req_pairs, k in 1:K
        @constraint(model, ppd[(r,rp), k] <= y[r, k])
        @constraint(model, ppd[(r,rp), k] <= y[rp, k])
        # If ppd=1: p_rp strictly before d_r
        @constraint(model,
            u[pickup(rp), k] - u[delivery(r), k] <=
            -1 + M_u * (1 - ppd[(r,rp), k]) + M_u * (2 - y[r, k] - y[rp, k]))
        # Force ppd=1 when p_rp < d_r: if ppd=0 and both on k → d_r ≤ p_rp
        @constraint(model,
            u[delivery(r), k] - u[pickup(rp), k] <=
            M_u * ppd[(r,rp), k] + M_u * (2 - y[r, k] - y[rp, k]))
    end

    # --- blocking: rp blocks r  iff  ord[(r,rp),k]=1  AND  ppd[(r,rp),k]=1 ---
    @variable(model, blocking[req_pairs, 1:K], Bin)
    for (r, rp) in req_pairs, k in 1:K
        @constraint(model, blocking[(r,rp), k] <= ord[(r,rp), k])
        @constraint(model, blocking[(r,rp), k] <= ppd[(r,rp), k])
        @constraint(model, blocking[(r,rp), k] >= ord[(r,rp), k] + ppd[(r,rp), k] - 1)
    end

    # --- LIFO packing: when rp blocks r, items of r closer to door than items of rp ---
    for (r, rp) in req_pairs, k in 1:K
        for s in 1:S, t in 1:S
            items[s].req == r && items[t].req == rp || continue
            @constraint(model,
                a[s] + items[s].box.l <= a[t] + M_Lv * (1 - blocking[(r,rp), k]))
        end
    end

    # -----------------------------------------------------------------------
    # FRAGILITY  (eq:fragility)
    #
    # If item s is fragile, no item t may be placed above it in overlapping xy area.
    # Equivalently: if s is fragile and items s,t overlap in xy, then c[t] < c[s].
    # We use the δ indicators: items s,t are separated in z iff δ5 or δ6 holds.
    # Fragile s: force δ6 (t below s) whenever s and t share a vehicle.
    # -----------------------------------------------------------------------
    for (s, t) in pairs
        items[s].box.fragile || continue
        guard = same_veh[(s, t)]
        # t must be below s OR they are separated in x or y
        # i.e. δ1 | δ2 | δ3 | δ4 | δ6 must hold
        @constraint(model,
            delta[(s,t), 1] + delta[(s,t), 2] +
            delta[(s,t), 3] + delta[(s,t), 4] +
            delta[(s,t), 6] >= guard)
    end
    for (s, t) in pairs
        items[t].box.fragile || continue
        guard = same_veh[(s, t)]
        # s must be below t OR separated in x or y (δ5 = s below t)
        @constraint(model,
            delta[(s,t), 1] + delta[(s,t), 2] +
            delta[(s,t), 3] + delta[(s,t), 4] +
            delta[(s,t), 5] >= guard)
    end

    return model, items, pairs, req_pairs
end

# ---------------------------------------------------------------------------
# Solve and extract solution
# ---------------------------------------------------------------------------
function solve_3lpdp(inst::Instance; time_limit::Float64 = 300.0)
    model, items, pairs, req_pairs = build_model(inst; time_limit)
    optimize!(model)

    status = termination_status(model)
    println("\n=== Solver status: $status ===")

    if primal_status(model) != FEASIBLE_POINT
        println("No feasible solution found.")
        return nothing
    end

    n = n_requests(inst)
    K = inst.max_routes
    S = length(items)

    x_val = value.(model[:x])
    u_val = value.(model[:u])
    y_val = value.(model[:y])
    a_val = value.(model[:a])
    b_val = value.(model[:b])
    c_val = value.(model[:c])

    println("\n--- Objective (total distance): $(round(objective_value(model), digits=2)) ---\n")

    DEPOT = 1
    pickup(r)   = r + 1
    delivery(r) = n + r + 1
    ALL_NODES   = 1:(2n + 1)

    for k in 1:K
        # Check if vehicle k is used
        active_reqs = [r for r in 1:n if round(Int, y_val[r, k]) == 1]
        isempty(active_reqs) && continue

        println("Vehicle $k  |  requests: $active_reqs")

        # Reconstruct route by following x arcs
        route = Int[DEPOT]
        current = DEPOT
        for _ in 1:(2 * length(active_reqs) + 1)
            next = findfirst(j -> j != current &&
                                  round(Int, x_val[current, j, k]) == 1,
                             collect(ALL_NODES))
            next === nothing && break
            push!(route, ALL_NODES[next])
            current = ALL_NODES[next]
            current == DEPOT && break
        end
        println("  Route (node indices): $route")

        # Annotate nodes
        node_name(i) = i == DEPOT ? "depot" :
                       i <= n + 1 ? "p$(i-1)" : "d$(i-n-1)"
        println("  Route (names):        ", join(node_name.(route), " → "))

        # Print item placements for this vehicle
        println("  Item placements:")
        for (s, it) in enumerate(items)
            it.req ∈ active_reqs || continue
            println("    item $s (req $(it.req), box $(it.box.l)×$(it.box.w)×$(it.box.h)" *
                    (it.box.fragile ? " FRAGILE" : "") *
                    "):  a=$(round(a_val[s],digits=1))  b=$(round(b_val[s],digits=1))  c=$(round(c_val[s],digits=1))")
        end
        println()
    end

    return model
end
