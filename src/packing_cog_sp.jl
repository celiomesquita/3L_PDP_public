# CoG–SP: Support Polygon + Center of Gravity (Ali et al. 2025, §3.3)
# Cross-section axes: x = width (b), y = height (c). Requires types.jl (Box).

struct PlacedBox
    b::Box
    x::Int   # origin along width
    y::Int   # origin along height (bottom)
end

function _rect_overlap_x(x1::Int, w1::Int, x2::Int, w2::Int)
    lo = max(x1, x2)
    hi = min(x1 + w1, x2 + w2)
    return lo < hi ? (lo, hi) : nothing
end

function _append_rect_corners!(pts::Vector{Tuple{Float64,Float64}}, xlo::Int, xhi::Int, y::Int)
    push!(pts, (Float64(xlo), Float64(y)))
    push!(pts, (Float64(xhi), Float64(y)))
end

"""Contact vertices for box `b` at (x,y) supported at z=y by floor and/or boxes below."""
function _support_contacts(placed::Vector{PlacedBox}, Wv::Int,
                           b::Box, x::Int, y::Int)::Vector{Tuple{Float64, Float64}}
    pts = Tuple{Float64, Float64}[]
    if y == 0
        ov = _rect_overlap_x(x, b.w, 0, Wv)
        ov !== nothing && _append_rect_corners!(pts, ov[1], ov[2], 0)
    end
    for pb in placed
        top = pb.y + pb.b.h
        top != y && continue
        ov = _rect_overlap_x(x, b.w, pb.x, pb.b.w)
        ov === nothing && continue
        _append_rect_corners!(pts, ov[1], ov[2], y)
    end
    return pts
end

function _convex_hull_2d(points::Vector{Tuple{Float64, Float64}})
    unique_pts = Tuple{Float64, Float64}[]
    for p in points
        if !any(isapprox(p[1], q[1]; atol=1e-9) && isapprox(p[2], q[2]; atol=1e-9) for q in unique_pts)
            push!(unique_pts, p)
        end
    end
    length(unique_pts) <= 1 && return unique_pts
    sort!(unique_pts, by = p -> (p[1], p[2]))
    cross(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
    lower = Tuple{Float64, Float64}[]
    for p in unique_pts
        while length(lower) >= 2 && cross(lower[end-1], lower[end], p) <= 0
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = Tuple{Float64, Float64}[]
    for p in reverse(unique_pts)
        while length(upper) >= 2 && cross(upper[end-1], upper[end], p) <= 0
            pop!(upper)
        end
        push!(upper, p)
    end
    hull = [lower[1:end-1]; upper[1:end-1]]
    return length(hull) >= 3 ? hull : unique_pts
end

function _point_on_segment(px::Float64, py::Float64,
                           a::Tuple{Float64, Float64},
                           b::Tuple{Float64, Float64})::Bool
    ax, ay = a
    bx, by = b
    cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    abs(cross) > 1e-6 && return false
    dotp = (px - ax) * (bx - ax) + (py - ay) * (by - ay)
    seg = (bx - ax)^2 + (by - ay)^2
    return dotp >= -1e-6 && dotp <= seg + 1e-6
end

function _cog_inside_sp(cx::Float64, cy::Float64,
                        hull::Vector{Tuple{Float64, Float64}})::Bool
    n = length(hull)
    n == 0 && return false
    n == 1 && return isapprox(cx, hull[1][1]; atol=1e-6) && isapprox(cy, hull[1][2]; atol=1e-6)
    n == 2 && return _point_on_segment(cx, cy, hull[1], hull[2])
    for i in 1:n
        j = i == n ? 1 : i + 1
        cross = (hull[j][1] - hull[i][1]) * (cy - hull[i][2]) -
                (hull[j][2] - hull[i][2]) * (cx - hull[i][1])
        cross < -1e-9 && return false
    end
    return true
end

function _stable_placement(placed::Vector{PlacedBox}, Wv::Int,
                         b::Box, x::Int, y::Int)::Bool
    pts = _support_contacts(placed, Wv, b, x, y)
    isempty(pts) && return false
    hull = _convex_hull_2d(pts)
    # Project CoG onto the support plane (Ali: horizontal x–y; here width × height at y).
    cx = Float64(x) + b.w / 2.0
    cy = Float64(y)
    return _cog_inside_sp(cx, cy, hull)
end

function _shelf_used_width(shelf::Vector{PlacedBox})::Int
    isempty(shelf) ? 0 : sum(pb.b.w for pb in shelf; init = 0)
end

function _try_place!(placed::Vector{PlacedBox}, shelf::Vector{PlacedBox},
                     y_base::Int, shelf_h::Int, b::Box, Wv::Int, Hv_lim::Int)::Bool
    x = _shelf_used_width(shelf)
    (x + b.w > Wv || b.h > shelf_h || y_base + shelf_h > Hv_lim) && return false
    _stable_placement(placed, Wv, b, x, y_base) || return false
    pb = PlacedBox(b, x, y_base)
    push!(shelf, pb)
    push!(placed, pb)
    return true
end

function _shelf_ffd_cog(candidates::Vector{Box}, Wv::Int, height_limit::Int)::Int
    sorted = sort(candidates; by = b -> b.h, rev = true)
    placed = PlacedBox[]
    shelves = Vector{PlacedBox}[]
    shelf_heights = Int[]
    for b in sorted
        done = false
        for i in eachindex(shelves)
            sh_h = shelf_heights[i]
            y_base_i = i > 1 ? sum(shelf_heights[1:i-1]) : 0
            if b.h <= sh_h && _try_place!(placed, shelves[i], y_base_i, sh_h, b, Wv, height_limit)
                done = true
                break
            end
        end
        if !done
            y_base = sum(shelf_heights; init = 0)
            (b.w > Wv || b.h > height_limit - y_base) && return typemax(Int)
            new_shelf = PlacedBox[]
            _try_place!(placed, new_shelf, y_base, b.h, b, Wv, height_limit) ||
                return typemax(Int)
            push!(shelves, new_shelf)
            push!(shelf_heights, b.h)
        end
    end
    total_h = sum(shelf_heights; init = 0)
    return total_h <= height_limit ? total_h : typemax(Int)
end

"""
    _pack_2d_height_cog(boxes, Wv, Hv) -> (height::Int, placed::Vector{PlacedBox})

Shelf-FFD with PC3 fragile-on-top ordering and CoG–SP check per placement.
Returns (_PACK_INF height) if infeasible.
"""
function _pack_2d_height_cog(boxes::AbstractVector{Box}, Wv::Int, Hv::Int)
    isempty(boxes) && return 0, PlacedBox[]
    inf = typemax(Int)

    non_frag = [b for b in boxes if !b.fragile]
    frag     = [b for b in boxes if  b.fragile]

    if isempty(frag)
        h = _shelf_ffd_cog(non_frag, Wv, Hv)
        return h == inf ? (inf, PlacedBox[]) : (h, PlacedBox[])
    end

    frag_w = sum(b.w for b in frag; init = 0)
    frag_h = maximum(b.h for b in frag)
    (frag_w > Wv || frag_h > Hv) && return inf, PlacedBox[]

    best = inf
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
        lower_h = _shelf_ffd_cog(lower, Wv, Hv - top_h)
        lower_h == inf && continue
        best = min(best, top_h + lower_h)
    end

    return best <= Hv ? (best, PlacedBox[]) : (inf, PlacedBox[])
end
