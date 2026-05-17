# Utility functions: distance matrix and subset extraction.

include("types.jl")

"""
    distance_matrix(inst) -> Matrix{Float64}

Returns a (2n+1) × (2n+1) Euclidean distance matrix where:
  - index 1       = depot (node 0)
  - indices 2..n+1   = pickup nodes p_1 .. p_n   (node r   → index r+1)
  - indices n+2..2n+1 = delivery nodes d_1 .. d_n  (node n+r → index n+r+1)

All indices are 1-based for Julia arrays.
"""
function distance_matrix(inst::Instance)::Matrix{Float64}
    n   = n_requests(inst)
    N   = 2n + 1          # total nodes (depot + n pickups + n deliveries)

    # Gather coordinates in node order: depot, p_1..p_n, d_1..d_n
    coords = Vector{Tuple{Int,Int}}(undef, N)
    coords[1] = (inst.depot.x, inst.depot.y)
    for (r, req) in enumerate(inst.requests)
        coords[r + 1]     = (req.px, req.py)   # pickup of request r
        coords[n + r + 1] = (req.dx, req.dy)   # delivery of request r
    end

    C = Matrix{Float64}(undef, N, N)
    for i in 1:N, j in 1:N
        dx = coords[i][1] - coords[j][1]
        dy = coords[i][2] - coords[j][2]
        C[i, j] = sqrt(dx^2 + dy^2)
    end
    return C
end

"""
    extract_subset(inst, request_ids) -> Instance

Returns a new Instance containing only the listed request IDs (1-based within inst.requests).
max_routes is capped at the number of selected requests.
"""
function extract_subset(inst::Instance, request_ids)::Instance
    reqs = [inst.requests[i] for i in request_ids]
    # Re-index request IDs 1..length(reqs) so the model indices are contiguous
    reqs = [Request(i, r.px, r.py, r.service_p, r.dx, r.dy, r.service_d,
                    r.total_weight, r.boxes, r.ect)
            for (i, r) in enumerate(reqs)]
    max_k = min(inst.max_routes, length(reqs))
    return Instance(max_k, inst.Q, inst.Lv, inst.Wv, inst.Hv, inst.depot, reqs)
end
