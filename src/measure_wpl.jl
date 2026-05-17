# Worst-Case Packing Latency (WPL) micro-benchmark
#
# Measures the empirical per-call cost of pack_route across all 54 benchmark
# instances, grouped by (n_requests, n_boxes_per_request) class.
#
# Usage:
#   julia --project=. src/measure_wpl.jl
#
# Output:
#   results/wpl_results.csv   — per-call timing for every route evaluated
#   (summary printed to stdout)

using Statistics
using Printf

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")

# ── instance class from filename ──────────────────────────────────────────────
function inst_class(name::String)
    parts = split(name, "_")
    length(parts) < 3 && return (0, 0)
    n_req = something(tryparse(Int, parts[1]), 0)
    n_box = something(tryparse(Int, parts[3]), 0)
    return (n_req, n_box)
end

# ── enumerate all possible route sub-sequences of length 1..min(n,6) ─────────
# For timing purposes we want a representative sample of route lengths,
# not an exhaustive enumeration of all permutations (too slow for n=100).
function sample_routes(n::Int; max_len::Int = 8, samples_per_len::Int = 200)
    routes = Vector{Vector{Int}}()
    rng    = collect(1:n)
    for len in 1:min(n, max_len)
        for _ in 1:samples_per_len
            r = shuffle(rng)[1:len]
            push!(routes, r)
        end
    end
    return routes
end

function shuffle(v::Vector{T}) where T
    v2 = copy(v)
    n  = length(v2)
    for i in n:-1:2
        j = rand(1:i)
        v2[i], v2[j] = v2[j], v2[i]
    end
    return v2
end

# ── main ──────────────────────────────────────────────────────────────────────
function main()
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    csv_path = joinpath(RESULTS_DIR, "wpl_results.csv")
    open(csv_path, "w") do io
        println(io, "instance,n_req,n_box,route_len,elapsed_ns")
    end

    # class → timing accumulator
    class_times = Dict{Tuple{Int,Int}, Vector{Float64}}()

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(INSTANCES_DIR)))

    for inst_file in inst_files
        inst_name = replace(inst_file, ".txt" => "")
        inst = parse_instance(joinpath(INSTANCES_DIR, inst_file))
        n    = n_requests(inst)
        cls  = inst_class(inst_name)

        haskey(class_times, cls) || (class_times[cls] = Float64[])

        routes = sample_routes(n)

        open(csv_path, "a") do io
            for route in routes
                t0 = time_ns()
                pack_route(route, inst)
                t1 = time_ns()
                ns = Float64(t1 - t0)
                push!(class_times[cls], ns)
                @printf(io, "%s,%d,%d,%d,%.0f\n",
                        inst_name, cls[1], cls[2], length(route), ns)
            end
        end
        @printf("  %-22s  n=%3d  b=%d  routes=%d  mean=%.1f μs\n",
                inst_name, n, cls[2],
                length(routes),
                mean(class_times[cls][max(1,end-length(routes)+1):end]) / 1e3)
        flush(stdout)
    end

    # ── summary table ─────────────────────────────────────────────────────────
    println("\n── WPL Summary by instance class ────────────────────────────────")
    @printf("%-18s  %6s  %6s  %8s  %8s  %8s\n",
            "class (n_req,n_box)", "n_calls", "mean μs",
            "p95 μs", "p99 μs", "max μs")
    for cls in sort(collect(keys(class_times)))
        ts = class_times[cls]
        p  = sort(ts)
        p95 = p[clamp(round(Int, 0.95 * length(p)), 1, length(p))]
        p99 = p[clamp(round(Int, 0.99 * length(p)), 1, length(p))]
        @printf("(%3d req, %d box)      %6d  %7.1f  %8.1f  %8.1f  %8.1f\n",
                cls[1], cls[2], length(ts),
                mean(ts) / 1e3,
                p95 / 1e3, p99 / 1e3, maximum(ts) / 1e3)
    end
    println("\nResults written to: $csv_path")
end

main()
