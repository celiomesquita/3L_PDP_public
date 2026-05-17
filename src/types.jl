# Data structures for the 3L-PDP

struct Box
    l::Int           # length (x-axis)
    w::Int           # width  (y-axis)
    h::Int           # height (z-axis)
    fragile::Bool
    weight::Float64  # volume-proportional allocation of request weight
end

struct Request
    id::Int
    px::Int; py::Int          # pickup coordinates
    service_p::Int            # service time at pickup
    dx::Int; dy::Int          # delivery coordinates
    service_d::Int            # service time at delivery
    total_weight::Int
    boxes::Vector{Box}
    ect::Float64              # Edge Crush Test strength [kN/m]; default 6.0 (BC-flute)
end

struct Depot
    x::Int
    y::Int
end

struct Instance
    max_routes::Int
    Q::Int              # vehicle weight capacity
    Lv::Int; Wv::Int; Hv::Int   # vehicle loading space dimensions
    depot::Depot
    requests::Vector{Request}
end

n_requests(inst::Instance) = length(inst.requests)
n_items(inst::Instance)    = sum(length(r.boxes) for r in inst.requests)
