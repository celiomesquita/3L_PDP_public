# Packing heuristic for the 3L-PDP: Layer / Segment-Pattern (SP) approach
#
# References:
#   Bortfeldt & Yi (2020) – "The Split Delivery VRP with Three-Dimensional
#   Loading Constraints", European Journal of Operational Research 282(2),
#   545–558.  (source of the 1C-SP / 2C-SP terminology)
#   Zhang et al. (2025) – improved 3L-SDVRP results using the same paradigm.
#
# Prerequisite: types.jl must be included before this file.
#
# ── Vehicle coordinate system (Männel & Bortfeldt 2016) ───────────────────────
#   a ∈ [0, Lv]  depth  (0 = door, Lv = cab)
#   b ∈ [0, Wv]  width
#   c ∈ [0, Hv]  height
#
# Each Box has fixed orientation (PC1): (l, w, h) maps to (a, b, c).
#
# ── Packing constraints ────────────────────────────────────────────────────────
#   PC1 – fixed orientation (no rotation attempted)
#   PC2 – vertical stability (shelf packing gives full base support); deactivated when
#        _USE_COG_SP[] is true — then CoG–SP replaces PC2 (see docs/packing_oracle_cog_sp_design.md)
@isdefined(_USE_COG_SP) || const _USE_COG_SP = Ref{Bool}(false)

include(joinpath(@__DIR__, "packing_cog_sp.jl"))

"""Cross-section pack: shelf-FFD (PC2) or CoG--SP when `_USE_COG_SP[]`."""
function _pack_cross_section(boxes::AbstractVector{Box}, Wv::Int, Hv::Int)::Int
    if _USE_COG_SP[]
        h, _ = _pack_2d_height_cog(boxes, Wv, Hv)
        return h == typemax(Int) ? _PACK_INF : h
    end
    return _pack_2d_height(boxes, Wv, Hv)
end
#   PC3 – fragility (fragile boxes placed on the topmost shelf; nothing above)
#   PC4 – LIFO (each request occupies a contiguous a-segment;
#              delivery order equals segment order from door inward)
#
# ── Algorithm overview ─────────────────────────────────────────────────────────
#   _pack_2d_height  shelf-FFD packing in a Wv × Hv cross-section → height used
#   _make_layers     partition a request's boxes into a-layers (depth slabs)
#   _depth_1csp      total a-depth for one request packed independently
#   _depth_2csp      try to reduce total depth of two adjacent requests by
#                    merging their boundary layers (2C-SP); LIFO is preserved
#                    by vertically separating the two requests' items in the
#                    merged cross-section
#   pack_route       returns 0 (feasible) or total box count (infeasible penalty)

@isdefined(_PACK_INF)    || const _PACK_INF    = typemax(Int)     # sentinel: does not fit
@isdefined(_USE_3CSP)    || const _USE_3CSP    = Ref{Bool}(true)  # set false for 2C-SP ablation
@isdefined(_USE_MERGE)   || const _USE_MERGE   = Ref{Bool}(true)  # set false for 1C-SP (M&B-like strict depth)
@isdefined(_USE_DENSITY) || const _USE_DENSITY = Ref{Bool}(false) # set true for 3L-PDP-D: density stacking (PC5)
@isdefined(_USE_SS)      || const _USE_SS      = Ref{Bool}(false) # set true for 3L-PDP-S: structural stacking (PC6)

# Density of a request: total_weight / total_volume.
# Delivery order must yield non-decreasing densities (lightest first = top compartment).
function req_density(r::Request)::Float64
    vol = sum(b.l * b.w * b.h for b in r.boxes; init = 0)
    return vol > 0 ? r.total_weight / vol : 0.0
end

# Effective Box Compression Test strength — combined McKee + Twede & Selke (2005).
#
# Component 1 — McKee (1963) cardboard term:
#   BCT_card = BCT_FACTOR × (ECT/6) × Σ √(l+w)
#   Derivation: BCT [N] = 5.876 × ECT × √(2(l+w)[m] × t[m])
#   ECT = 6 kN/m (BC-flute default), t = 4 mm, dimensions in dm,
#   1 weight-unit ≈ 0.1 kg → BCT_FACTOR ≈ 1016; set to 2000 for a moderate constraint.
#
# Component 2 — Twede & Selke (2005) cargo self-support term:
#   cargo_support = CARGO_SUPPORT_FACTOR × ((6 − ECT)/2) × total_weight
#   The factor (6−ECT)/2 maps ECT grades to Twede & Selke load classes:
#     ECT=4 (easy load,   dense/rigid cargo): factor = 1.0  → full self-support
#     ECT=5 (medium load, semi-rigid cargo):  factor = 0.5  → half self-support
#     ECT=6 (difficult load, hollow cargo):   factor = 0.0  → no self-support
#   For M&B instances (ECT=6 always) the cargo term vanishes → pure McKee, unchanged.
@isdefined(_BCT_FACTOR)           || const _BCT_FACTOR           = Ref(2000.0)
@isdefined(_CARGO_SUPPORT_FACTOR) || const _CARGO_SUPPORT_FACTOR = Ref(1.0)

function req_bct(r::Request)::Float64
    bct_card     = _BCT_FACTOR[] * (r.ect / 6.0) * sum(sqrt(b.l + b.w) for b in r.boxes; init = 0.0)
    cargo_support = _CARGO_SUPPORT_FACTOR[] * ((6.0 - r.ect) / 2.0) * r.total_weight
    return bct_card + cargo_support
end

# ── PCE instrumentation: thread-safe packing call counters ────────────────────
@isdefined(_PACK_CALLS)    || const _PACK_CALLS    = Threads.Atomic{Int}(0)
@isdefined(_PACK_FEASIBLE) || const _PACK_FEASIBLE = Threads.Atomic{Int}(0)

function reset_pack_counters!()
    Threads.atomic_xchg!(_PACK_CALLS,    0)
    Threads.atomic_xchg!(_PACK_FEASIBLE, 0)
    return nothing
end
get_pack_counts() = (_PACK_CALLS[], _PACK_FEASIBLE[])

# ── 2-D shelf-FFD in a Wv × Hv cross-section ─────────────────────────────────
"""
    _pack_2d_height(boxes, Wv, Hv) -> Int

Pack `boxes` into a cross-section of width `Wv` and height `Hv` using
first-fit decreasing shelf packing.

Shelf order (PC3): non-fragile boxes are sorted by height descending and
packed into lower shelves via FFD; fragile boxes are packed last into one or
more dedicated topmost shelves, so no other item is ever placed above them.

Returns the total height consumed by all shelves, or `_PACK_INF` if the
boxes cannot fit.
"""
function _pack_2d_height(boxes::AbstractVector{Box}, Wv::Int, Hv::Int)::Int
    isempty(boxes) && return 0

    function shelf_ffd_height(candidates::Vector{Box}, height_limit::Int)::Int
        sorted = sort(candidates; by = b -> b.h, rev = true)
        shelves = Tuple{Int,Int}[]
        placed = false
        for b in sorted
            placed = false
            for i in eachindex(shelves)
                sh_h, sh_w = shelves[i]
                if b.h <= sh_h && sh_w + b.w <= Wv
                    shelves[i] = (sh_h, sh_w + b.w)
                    placed = true
                    break
                end
            end
            if !placed
                (b.w > Wv || b.h > height_limit) && return _PACK_INF
                push!(shelves, (b.h, b.w))
            end
        end
        total_h = sum(s[1] for s in shelves; init = 0)
        return total_h <= height_limit ? total_h : _PACK_INF
    end

    non_frag = [b for b in boxes if !b.fragile]
    frag     = [b for b in boxes if  b.fragile]

    isempty(frag) && return shelf_ffd_height(non_frag, Hv)

    # Fragile boxes must be on a top shelf. Non-fragile boxes may share that
    # same shelf side-by-side, because no item is physically above them there.
    frag_w = sum(b.w for b in frag; init = 0)
    frag_h = maximum(b.h for b in frag)
    (frag_w > Wv || frag_h > Hv) && return _PACK_INF

    best = _PACK_INF
    top_candidates = sort(non_frag; by = b -> b.h, rev = true)
    for top_h in unique(sort([frag_h; [b.h for b in non_frag if b.h >= frag_h]; Hv]))
        top_w = frag_w
        lower = Box[]
        for b in top_candidates
            if b.h <= top_h && top_w + b.w <= Wv
                top_w += b.w
            else
                push!(lower, b)
            end
        end
        lower_h = shelf_ffd_height(lower, Hv - top_h)
        lower_h == _PACK_INF && continue
        best = min(best, top_h + lower_h)
    end

    return best <= Hv ? best : _PACK_INF
end

# ── layer builder: partition boxes into a-axis slabs ─────────────────────────
"""
    _make_layers(boxes, Wv, Hv) -> Vector{Tuple{Int,Vector{Box}}}

Greedily assign `boxes` to layers along the a-axis.  A layer is a depth slab
whose extent equals the maximum `l` of its constituent boxes.  Boxes are
processed in descending `l` order so that larger boxes open new layers first
and smaller boxes may consolidate into existing layers.

A box joins the first existing layer in which
  (a) `box.l ≤ layer_depth`, and
  (b) the box fits in the Wv × Hv cross-section together with the
      other boxes already assigned to that layer (checked via `_pack_2d_height`).

Returns a vector of `(depth, boxes_in_layer)` tuples.  Returns an empty vector
if any single box cannot be placed (infeasible instance for this cross-section).
"""
function _make_layers(boxes::AbstractVector{Box},
                      Wv::Int, Hv::Int)::Vector{Tuple{Int,Vector{Box}}}
    isempty(boxes) && return Tuple{Int,Vector{Box}}[]
    sorted = sort(collect(boxes); by = b -> b.l, rev = true)

    layers = Tuple{Int,Vector{Box}}[]

    for b in sorted
        placed = false
        for i in eachindex(layers)
            depth_i, layer_boxes = layers[i]
            b.l > depth_i && continue        # box too long for this layer's slab
            candidate = vcat(layer_boxes, [b])
            if _pack_cross_section(candidate, Wv, Hv) < _PACK_INF
                layers[i] = (depth_i, candidate)
                placed = true
                break
            end
        end
        if !placed
            _pack_cross_section([b], Wv, Hv) == _PACK_INF && return Tuple{Int,Vector{Box}}[]
            push!(layers, (b.l, [b]))
        end
    end

    # ── Layer consolidation pass ───────────────────────────────────────────
    # Layers are in depth-descending order (layers[1] deepest, layers[end]
    # shallowest).  Starting from the shallowest layer, try to absorb it into
    # any deeper layer: all its boxes already satisfy the depth constraint
    # (b.l ≤ depth_thin ≤ depth_target), so only the cross-section check
    # (_pack_2d_height) can block absorption.  Removing a thin layer reduces
    # total a-depth for the request.
    i = length(layers)
    while i >= 2
        _, boxes_i = layers[i]
        absorbed = false
        for j in 1:i-1
            depth_j, boxes_j = layers[j]
            if _pack_cross_section(vcat(boxes_j, boxes_i), Wv, Hv) < _PACK_INF
                layers[j] = (depth_j, vcat(boxes_j, boxes_i))
                deleteat!(layers, i)
                absorbed = true
                break
            end
        end
        # If absorbed: the new last layer may itself be absorbable — restart
        # from the end.  If not absorbed: move to the next thinner layer.
        i = absorbed ? length(layers) : i - 1
    end

    return layers
end

# ── 1C-SP: single-request segment depth ──────────────────────────────────────
"""
    _depth_1csp(req, Wv, Hv) -> Int

Return the minimum a-axis depth required to pack all boxes of `req` using
independent layers (one-compartment segment pattern, 1C-SP).
Returns `_PACK_INF` if the request's boxes cannot fit in any cross-section.
"""
function _depth_1csp(req::Request, Wv::Int, Hv::Int)::Int
    layers = _make_layers(req.boxes, Wv, Hv)
    isempty(layers) && !isempty(req.boxes) && return _PACK_INF
    return sum(d for (d, _) in layers; init = 0)
end

# ── 2C-SP: boundary-layer merge for two adjacent requests ─────────────────────
"""
    _depth_2csp(r_near, r_far, Wv, Hv) -> Int

Attempt to reduce the combined a-depth of the adjacent pair (`r_near`,
`r_far`) by merging the last layer of `r_near` with the first layer of
`r_far` into a single cross-section slab (two-compartment segment pattern,
2C-SP).

LIFO compatibility (PC4) and vertical stability (PC2 when !_USE_COG_SP[]) are maintained by
vertical separation: `r_far`'s boxes occupy the lower zone of the merged
cross-section (height h_far, resting on the vehicle floor), and `r_near`'s
boxes are packed into the upper zone (height h_near, above r_far), with
h_far + h_near ≤ Hv.  Placing the first-to-deliver request on top guarantees
that its items can be lifted out without displacing r_far's items (PC4), and
r_far remains floor-supported throughout loading and unloading (PC2 when !_USE_COG_SP[]).

Returns `min(d_1csp_near + d_1csp_far, d_2csp)`, or `_PACK_INF` if either
request is individually infeasible.
"""
function _depth_2csp(r_near::Request, r_far::Request, Wv::Int, Hv::Int)::Int
    layers_near = _make_layers(r_near.boxes, Wv, Hv)
    layers_far  = _make_layers(r_far.boxes,  Wv, Hv)

    (isempty(layers_near) && !isempty(r_near.boxes)) && return _PACK_INF
    (isempty(layers_far)  && !isempty(r_far.boxes))  && return _PACK_INF

    d_1c = sum(d for (d, _) in layers_near; init = 0) +
           sum(d for (d, _) in layers_far;  init = 0)

    # Nothing to merge if either side has no layers
    (isempty(layers_near) || isempty(layers_far)) && return d_1c

    _, boxes_last  = layers_near[end]
    d_first, boxes_first = layers_far[1]

    # Vertical-separation feasibility check: r_far on floor, r_near on top (PC4; PC2 if !_USE_COG_SP[])
    h_far  = _pack_cross_section(boxes_first, Wv, Hv)
    h_far  == _PACK_INF && return d_1c
    h_near = _pack_cross_section(boxes_last,  Wv, Hv - h_far)
    h_near == _PACK_INF && return d_1c

    merged_depth = max(layers_near[end][1], d_first)
    d_2c = sum(d for (d, _) in layers_near[1:end-1]; init = 0) +
           merged_depth +
           sum(d for (d, _) in layers_far[2:end];    init = 0)

    return min(d_1c, d_2c)
end

# ── 3C-SP: three-request vertical stack ──────────────────────────────────────
"""
    _depth_3csp(r_near, r_mid, r_far, Wv, Hv) -> Int

Attempt to reduce the combined a-depth of three consecutive requests by packing
them into a single cross-section slab (three-compartment segment pattern, 3C-SP).

LIFO vertical order (floor to ceiling): r_far, r_mid, r_near.
  - r_far's boundary layer rests on the vehicle floor.
  - r_mid's boxes occupy the zone above r_far.
  - r_near's boundary layer sits on top, accessible first without disturbing
    the others (PC4).

For r_mid with multiple layers all of its boxes are treated as the middle
zone; the slab depth equals max(last-layer depth of r_near, max depth of
r_mid, first-layer depth of r_far).

Returns the minimum total a-depth for the triple, or `_PACK_INF` if any
request is individually infeasible.
"""
function _depth_3csp(r_near::Request, r_mid::Request, r_far::Request,
                     Wv::Int, Hv::Int)::Int
    layers_near = _make_layers(r_near.boxes, Wv, Hv)
    layers_mid  = _make_layers(r_mid.boxes,  Wv, Hv)
    layers_far  = _make_layers(r_far.boxes,  Wv, Hv)

    (isempty(layers_near) && !isempty(r_near.boxes)) && return _PACK_INF
    (isempty(layers_mid)  && !isempty(r_mid.boxes))  && return _PACK_INF
    (isempty(layers_far)  && !isempty(r_far.boxes))  && return _PACK_INF

    d_1c = sum(d for (d, _) in layers_near; init = 0) +
           sum(d for (d, _) in layers_mid;  init = 0) +
           sum(d for (d, _) in layers_far;  init = 0)

    (isempty(layers_near) || isempty(layers_mid) || isempty(layers_far)) && return d_1c

    # Boundary boxes: last layer of r_near, all of r_mid, first layer of r_far
    _, boxes_near_bnd = layers_near[end]
    _, boxes_far_bnd  = layers_far[1]
    boxes_mid_all     = reduce(vcat, [b for (_, b) in layers_mid])

    # Vertical feasibility: r_far on floor, r_mid above, r_near on top
    h_far  = _pack_cross_section(boxes_far_bnd,  Wv, Hv)
    h_far  == _PACK_INF && return d_1c
    h_mid  = _pack_cross_section(boxes_mid_all,  Wv, Hv - h_far)
    h_mid  == _PACK_INF && return d_1c
    h_near = _pack_cross_section(boxes_near_bnd, Wv, Hv - h_far - h_mid)
    h_near == _PACK_INF && return d_1c

    merged_depth = max(layers_near[end][1],
                       maximum(d for (d, _) in layers_mid),
                       layers_far[1][1])

    d_3c = sum(d for (d, _) in layers_near[1:end-1]; init = 0) +
           merged_depth +
           sum(d for (d, _) in layers_far[2:end];    init = 0)

    return min(d_1c, d_3c)
end

# ── main entry point ──────────────────────────────────────────────────────────
"""
    pack_route(route_ids, inst) -> Int

Evaluate the 3D packing feasibility of a vehicle route using the Layer/SP
heuristic.

`route_ids` must be given in *delivery order*: `route_ids[1]` is delivered
first (nearest to the vehicle door) and `route_ids[end]` last (deepest, near
cab).  For the all-pickups-first route structure this equals the pickup order.

Algorithm:
  1. Weight-capacity check (vehicle capacity Q).
  2. Compute 1C-SP depth for every request independently.
  3. If the total depth already fits in Lv, return 0 (feasible).
  4. Optimal 2C-SP / 3C-SP matching via DP: for each position k, consider
     merging pair (k-1,k) via 2C-SP or triple (k-2,k-1,k) via 3C-SP;
     find the maximum-savings non-overlapping selection using a linear-time
     DP (rolling three-state recurrence).  The DP exits early as soon as
     accumulated savings proves feasibility.
  5. Return 0 if total merged depth ≤ Lv, else return the total number
     of boxes in the route (used as a penalty term in the objective).

Returns:
  0              — a feasible packing exists
  n_boxes_total  — no feasible packing found (penalty proxy)
"""
function pack_route(route_ids::Vector{Int}, inst::Instance)::Int
    isempty(route_ids) && return 0
    Threads.atomic_add!(_PACK_CALLS, 1)   # count every non-trivial oracle query

    requests      = [inst.requests[r] for r in route_ids]
    n_boxes_total = sum(length(r.boxes) for r in requests)

    # ── weight capacity ────────────────────────────────────────────────────
    sum(r.total_weight for r in requests) > inst.Q && return n_boxes_total

    # ── density stacking constraint (PC5, optional) ────────────────────────
    # route_ids[1] = first delivered = top compartment (must be lightest).
    # route_ids[end] = last delivered = floor compartment (must be densest).
    # Densities must be non-decreasing along the delivery sequence.
    if _USE_DENSITY[] && length(requests) > 1
        prev = req_density(requests[1])
        ok = true
        for i in 2:length(requests)
            d = req_density(requests[i])
            if d < prev - 1e-9
                ok = false; break
            end
            prev = d
        end
        ok || return n_boxes_total
    end

    # ── structural stacking constraint (PC6, optional) ────────────────────
    # route_ids[j] at position j must support the total weight of all requests
    # delivered before it (positions 1..j-1), which sit physically above it
    # in the vehicle height direction.
    # BCT(requests[j]) ≥ Σ weight(requests[i]) for i < j.
    if _USE_SS[] && length(requests) > 1
        weight_above = 0.0
        ok = true
        for j in 1:length(requests)
            if req_bct(requests[j]) < weight_above - 1e-9
                ok = false; break
            end
            weight_above += Float64(requests[j].total_weight)
        end
        ok || return n_boxes_total
    end

    # ── 1C-SP depths ───────────────────────────────────────────────────────
    Wv = inst.Wv;  Hv = inst.Hv;  Lv = inst.Lv
    depths = Int[_depth_1csp(r, Wv, Hv) for r in requests]
    any(d == _PACK_INF for d in depths) && return n_boxes_total
    if sum(depths) <= Lv
        Threads.atomic_add!(_PACK_FEASIBLE, 1); return 0
    end
    !_USE_MERGE[] && return n_boxes_total  # 1C-SP only: no merging (M&B-like strict depth)

    # ── 2C-SP + 3C-SP: optimal non-overlapping merge via DP ──────────────
    # Rolling recurrence (three states suffice):
    #   opt_km1 = max savings for first k-1 requests
    #   opt_km2 = max savings for first k-2 requests
    #   opt_km3 = max savings for first k-3 requests
    # Transitions at position k:
    #   skip:      opt_km1
    #   2C pair:   opt_km2 + ps2(k-1, k)
    #   3C triple: opt_km3 + ps3(k-2, k-1, k)   [only when k ≥ 3]
    # Early exit as soon as opt_k ≥ deficit.
    N = length(requests)
    N < 2 && return n_boxes_total   # single request already failed depth check

    deficit = sum(depths) - Lv
    opt_km3 = 0
    opt_km2 = 0
    opt_km1 = 0

    for k in 2:N
        d2    = _depth_2csp(requests[k-1], requests[k], Wv, Hv)
        ps2   = max(0, depths[k-1] + depths[k] - d2)
        opt_k = max(opt_km1, opt_km2 + ps2)

        if k >= 3 && _USE_3CSP[]
            d3  = _depth_3csp(requests[k-2], requests[k-1], requests[k], Wv, Hv)
            ps3 = max(0, depths[k-2] + depths[k-1] + depths[k] - d3)
            opt_k = max(opt_k, opt_km3 + ps3)
        end

        if opt_k >= deficit
            Threads.atomic_add!(_PACK_FEASIBLE, 1); return 0   # proven feasible — stop early
        end
        opt_km3 = opt_km2
        opt_km2 = opt_km1
        opt_km1 = opt_k
    end

    return n_boxes_total
end
