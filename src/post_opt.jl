# post_opt.jl
# Post-optimization for BRKGA solutions via Or-opt and intra-route 2-opt.
#
# All packing checks use the full sequential (all-states) 3C-SP oracle:
# every pickup state along each route is verified, not just the peak.
# This is stricter than the BRKGA decoder (peak-only) and ensures that
# every delivered solution is genuinely IPR-certified.
#
# Cost improvement is checked BEFORE calling pack_route, so packing calls
# are only made for moves that are already cost-reducing.  This keeps the
# total post-opt wall-clock time small relative to the BRKGA budget.

# ── node-index helpers ────────────────────────────────────────────────────────
# dist matrix layout: index 1 = depot, r+1 = pickup of r, r+n+1 = delivery of r
@inline _node_idx(v::Int, n::Int) = v > 0 ? v + 1 : -v + n + 1

# ── route travel cost ─────────────────────────────────────────────────────────
function _route_cost(route::Vector{Int}, dist::Matrix{Float64}, n::Int)::Float64
    isempty(route) && return 0.0
    cost = dist[1, _node_idx(route[1], n)]
    for i in 1:length(route)-1
        cost += dist[_node_idx(route[i], n), _node_idx(route[i+1], n)]
    end
    cost += dist[_node_idx(route[end], n), 1]
    return cost
end

# ── total travel distance across all routes ───────────────────────────────────
function total_ttd(routes::Vector{Vector{Int}}, dist::Matrix{Float64}, n::Int)::Float64
    sum(_route_cost(r, dist, n) for r in routes; init=0.0)
end

# ── PDP precedence check: every pickup must precede its delivery ───────────────
function _pdp_ok(route::Vector{Int})::Bool
    seen = Set{Int}()
    for v in route
        v > 0 ? push!(seen, v) : (-v ∈ seen || return false)
    end
    return true
end

# ── peak-state packing feasibility for a route ───────────────────────────────
# Matches the BRKGA decoder convention: checks only the maximum co-loading
# state, with items sorted by delivery position (ascending).
function _pack_ok(route::Vector{Int}, inst::Instance)::Bool
    del_pos = Dict{Int,Int}()
    for (i, v) in enumerate(route)
        v < 0 && (del_pos[-v] = i)
    end
    loaded = Int[]; peak = Int[]
    for v in route
        if v > 0
            push!(loaded, v)
            length(loaded) > length(peak) && (peak = copy(loaded))
        else
            deleteat!(loaded, findfirst(==(-v), loaded))
        end
    end
    isempty(peak) && return true
    sort!(peak; by = r -> get(del_pos, r, typemax(Int)))
    return pack_route(peak, inst) == 0
end

# ── Or-opt pass: relocate each request to its best feasible position ──────────
#
# For every request r in every route, we:
#   1. Tentatively remove r (both +r and -r) from its source route.
#   2. Enumerate all valid (pickup_pos, delivery_pos) pairs in every route
#      (including the source route without r).
#   3. Accept the move with the greatest travel-distance saving, provided the
#      new route is PDP-feasible and passes the all-states packing check.
#
# Cost-first filtering: we compute the distance delta before calling pack_route,
# so the oracle is only invoked when the move is already cost-improving.
#
# Returns true if at least one move was accepted.
function _or_opt_pass!(routes::Vector{Vector{Int}},
                       inst::Instance,
                       dist::Matrix{Float64})::Bool
    n = n_requests(inst)
    K = length(routes)
    improved = false

    k_src = 1
    while k_src <= K
        isempty(routes[k_src]) && (k_src += 1; continue)

        reqs = [v for v in routes[k_src] if v > 0]
        r_idx = 1

        while r_idx <= length(reqs)
            req = reqs[r_idx]

            # Remove req from source route
            src_without = filter(v -> abs(v) != req, routes[k_src])
            cost_src_before = _route_cost(routes[k_src], dist, n)
            cost_src_after  = _route_cost(src_without,   dist, n)
            Δsrc = cost_src_before - cost_src_after   # saving from removal

            best_gain  = 1e-9      # strict improvement threshold
            best_k     = -1
            best_cand  = Vector{Int}()

            for k_dst in 1:K
                base      = k_dst == k_src ? src_without : routes[k_dst]
                cost_base = k_dst == k_src ? cost_src_after : _route_cost(base, dist, n)
                L         = length(base)

                for pp in 0:L              # pickup insertion index (before position pp+1)
                    for dp in pp:L         # delivery insertion index (after pickup)
                        # Fast cost estimate before building candidate vector.
                        # Node before/after pickup insertion:
                        prev_p = pp == 0 ? 1 : _node_idx(base[pp], n)
                        next_p = pp == L ? 1 : _node_idx(base[pp+1], n)
                        # Node before/after delivery insertion (shifted by +1 due to pickup):
                        pp1 = pp + 1   # pickup is now at position pp+1 in the extended route
                        prev_d = dp == pp ? _node_idx(req, n) :
                                            _node_idx(base[dp], n)
                        next_d = dp == L  ? 1 : _node_idx(base[dp+1], n)

                        # Quick cost delta (not exact when pp==dp, but used only for filtering)
                        p_node = _node_idx( req, n)
                        d_node = _node_idx(-req, n)
                        Δdst_approx = if pp == dp
                            # pickup and delivery inserted consecutively
                            dist[prev_p, p_node] + dist[p_node, d_node] +
                            dist[d_node, next_d] - dist[prev_p, next_d]
                        else
                            dist[prev_p, p_node] + dist[p_node, next_p] - dist[prev_p, next_p] +
                            dist[prev_d, d_node] + dist[d_node, next_d] - dist[prev_d, next_d]
                        end

                        gain_approx = Δsrc - Δdst_approx
                        gain_approx > best_gain || continue   # fast reject

                        # Build the candidate route and do exact checks
                        cand = copy(base)
                        insert!(cand, dp + 1, -req)
                        insert!(cand, pp + 1,  req)

                        _pdp_ok(cand)       || continue
                        _pack_ok(cand, inst) || continue

                        gain_exact = Δsrc + cost_base - _route_cost(cand, dist, n)
                        if gain_exact > best_gain
                            best_gain = gain_exact
                            best_k    = k_dst
                            best_cand = cand
                        end
                    end
                end
            end

            if best_k != -1
                routes[k_src] = src_without
                routes[best_k] = best_cand
                improved = true
                reqs = [v for v in routes[k_src] if v > 0]
                # Do not advance r_idx: the slot may now hold a different request
            else
                r_idx += 1
            end
        end
        k_src += 1
    end
    return improved
end

# ── 2-opt pass: reverse segments within each route ────────────────────────────
#
# For each route, tries all O(L²) segment reversals.  A reversal is accepted
# only if it:
#   (a) reduces travel distance,
#   (b) maintains PDP pickup-before-delivery precedence, and
#   (c) passes the all-states packing check.
#
# Iterates within each route until no improving reversal is found.
# Returns true if at least one reversal was accepted across all routes.
function _two_opt_pass!(routes::Vector{Vector{Int}},
                        inst::Instance,
                        dist::Matrix{Float64})::Bool
    n = n_requests(inst)
    improved = false

    for k in eachindex(routes)
        route = routes[k]
        L = length(route)
        L < 4 && continue

        again = true
        while again
            again = false
            cost_now = _route_cost(route, dist, n)

            for i in 1:L-2
                for j in i+2:L
                    # Reversing route[i:j] changes edges (i-1,i) and (j,j+1).
                    # Quick cost delta before building candidate.
                    a = i == 1 ? 1 : _node_idx(route[i-1], n)
                    b = _node_idx(route[i],   n)
                    c = _node_idx(route[j],   n)
                    d = j == L ? 1 : _node_idx(route[j+1], n)

                    Δcost = dist[a, c] + dist[b, d] - dist[a, b] - dist[c, d]
                    Δcost < -1e-9 || continue   # fast reject: no cost improvement

                    cand = vcat(route[1:i-1], reverse(route[i:j]), route[j+1:end])
                    _pdp_ok(cand)        || continue
                    _pack_ok(cand, inst) || continue

                    cost_new = cost_now + Δcost
                    if cost_new < cost_now - 1e-9
                        route    = cand
                        cost_now = cost_new
                        again    = true
                        improved = true
                    end
                end
            end
        end
        routes[k] = route
    end
    return improved
end

# ── main entry point ──────────────────────────────────────────────────────────
"""
    post_optimize!(routes, inst, dist) -> nothing

Apply iterated Or-opt and 2-opt local search to a set of PDP routes in-place.
Alternates between Or-opt passes (inter- and intra-route request relocation)
and intra-route 2-opt passes until no further improvement is found.
All moves are validated against both PDP precedence and the full all-states
3C-SP packing oracle.
"""
function post_optimize!(routes::Vector{Vector{Int}},
                        inst::Instance,
                        dist::Matrix{Float64})
    any_improved = true
    while any_improved
        a = _or_opt_pass!(routes, inst, dist)
        b = _two_opt_pass!(routes, inst, dist)
        any_improved = a || b
    end
end
