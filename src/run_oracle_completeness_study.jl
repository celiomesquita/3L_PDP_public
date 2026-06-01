# Oracle Completeness Study — 3C-SP false-rejection rate
#
# For routes that 3C-SP rejects, quantifies what fraction could be certified
# as feasible by a more complete oracle.  Two bounds are computed:
#
#   Lower bound  (any_order)  — fraction of rejections where SOME delivery
#     ordering of the same co-loaded requests passes 3C-SP.  Items pack fine
#     under vertical separation; 3C-SP just happened to evaluate the wrong order.
#
#   Upper bound  (joint_fit)  — fraction of rejections where ALL items, packed
#     jointly with no delivery-order constraint, still fit within Lv.  These
#     routes are not volumetrically infeasible; 3C-SP's vertical-separation
#     requirement is the sole blocker.
#
# The true false-rejection rate of 3C-SP relative to a complete oracle lies in
# [lower_bound, upper_bound].  Routes above the upper bound are provably
# infeasible under any oracle (items cannot physically fit in the vehicle).
#
# Usage (from project root):
#   julia --project=. src/run_oracle_completeness_study.jl

using Statistics
using Printf
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")

const INSTANCES_DIR  = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR    = joinpath(@__DIR__, "..", "results")
const MAX_ROUTE_LEN  = 6      # co-loading sets longer than this are rare in M&B
const SAMPLES_PER_LEN = 500   # random routes sampled per (instance, length) pair
const MAX_PERM_K     = 5      # exhaustive permutation check up to this many requests
const RANDOM_PERM_SAMPLES = 120  # fallback for k > MAX_PERM_K

# ── helpers ───────────────────────────────────────────────────────────────────

function inst_class(name::String)
    parts = split(name, "_")
    length(parts) < 3 && return (0, 0)
    n_req = something(tryparse(Int, parts[1]), 0)
    n_box = something(tryparse(Int, parts[3]), 0)
    return (n_req, n_box)
end

# All permutations of a short integer vector (only call for length ≤ MAX_PERM_K)
function _all_perms(v::Vector{Int})::Vector{Vector{Int}}
    length(v) == 1 && return [v]
    result = Vector{Vector{Int}}()
    for i in eachindex(v)
        rest = [v[j] for j in eachindex(v) if j != i]
        for p in _all_perms(rest)
            push!(result, vcat(v[i], p))
        end
    end
    return result
end

# Joint depth: pack ALL boxes from all requests as one combined pseudo-request,
# ignoring any delivery-order constraint.  Returns _PACK_INF if a single box
# exceeds Wv or Hv, otherwise returns the minimum total a-depth.
function _joint_depth(requests::Vector{Request}, Wv::Int, Hv::Int)::Int
    all_boxes = reduce(vcat, [r.boxes for r in requests])
    isempty(all_boxes) && return 0
    layers = _make_layers(all_boxes, Wv, Hv)
    (isempty(layers) && !isempty(all_boxes)) && return _PACK_INF
    return sum(d for (d, _) in layers; init = 0)
end

# ── per-instance analysis ─────────────────────────────────────────────────────

struct RouteStats
    n_routes   :: Int
    n_rejected :: Int
    n_any_order:: Int   # rejected but some permutation of the same ids passes 3C-SP
    n_joint_fit:: Int   # rejected but items fit jointly (no delivery-order constraint)
end

function analyse_instance(inst::Instance, n_routes_target::Int, rng::AbstractRNG)
    n   = n_requests(inst)
    Wv  = inst.Wv;  Hv = inst.Hv;  Lv = inst.Lv
    n_routes = 0;  n_rejected = 0;  n_any_order = 0;  n_joint_fit = 0

    for len in 2:min(n, MAX_ROUTE_LEN)
        for _ in 1:n_routes_target
            route = randperm(rng, n)[1:len]
            n_routes += 1

            verdict = pack_route(route, inst)
            verdict == 0 && continue   # 3C-SP accepted — not relevant here

            n_rejected += 1
            requests = [inst.requests[r] for r in route]
            k = len

            # ── lower bound: does any delivery ordering pass 3C-SP? ──────────
            found_any = false
            if k <= MAX_PERM_K
                for perm in _all_perms(route)
                    if pack_route(perm, inst) == 0
                        found_any = true; break
                    end
                end
            else
                for _ in 1:RANDOM_PERM_SAMPLES
                    perm = route[randperm(rng, k)]
                    if pack_route(perm, inst) == 0
                        found_any = true; break
                    end
                end
            end
            found_any && (n_any_order += 1)

            # ── upper bound: do items fit when packed jointly? ───────────────
            jd = _joint_depth(requests, Wv, Hv)
            if jd != _PACK_INF && jd <= Lv
                n_joint_fit += 1
            end
        end
    end

    return RouteStats(n_routes, n_rejected, n_any_order, n_joint_fit)
end

# ── main ──────────────────────────────────────────────────────────────────────

function main()
    isdir(RESULTS_DIR) || mkdir(RESULTS_DIR)
    rng = MersenneTwister(42)

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(INSTANCES_DIR)))

    println("Oracle Completeness Study — 3C-SP false-rejection rate")
    println("=" ^ 65)
    @printf("  Route lengths 2–%d  |  %d samples per (instance, length)  |  perms up to k=%d\n\n",
            MAX_ROUTE_LEN, SAMPLES_PER_LEN, MAX_PERM_K)

    class_agg = Dict{Tuple{Int,Int}, Vector{Int}}()  # [routes, rejected, any_order, joint_fit]
    overall   = zeros(Int, 4)

    # CSV output
    csv_path = joinpath(RESULTS_DIR, "oracle_completeness.csv")
    open(csv_path, "w") do io
        println(io, "instance,n_req_class,n_box_class,n_routes,n_rejected," *
                    "n_any_order,n_joint_fit,pct_rejected,pct_any_order,pct_joint_fit")
    end

    for inst_file in inst_files
        inst_name = replace(inst_file, ".txt" => "")
        inst      = parse_instance(joinpath(INSTANCES_DIR, inst_file))
        cls       = inst_class(inst_name)
        haskey(class_agg, cls) || (class_agg[cls] = zeros(Int, 4))

        s = analyse_instance(inst, SAMPLES_PER_LEN, rng)

        class_agg[cls][1] += s.n_routes
        class_agg[cls][2] += s.n_rejected
        class_agg[cls][3] += s.n_any_order
        class_agg[cls][4] += s.n_joint_fit
        overall[1] += s.n_routes;   overall[2] += s.n_rejected
        overall[3] += s.n_any_order; overall[4] += s.n_joint_fit

        pct_rej   = s.n_rejected > 0 ? 100.0 * s.n_rejected / s.n_routes    : 0.0
        pct_any   = s.n_rejected > 0 ? 100.0 * s.n_any_order / s.n_rejected : 0.0
        pct_joint = s.n_rejected > 0 ? 100.0 * s.n_joint_fit / s.n_rejected : 0.0

        @printf("  %-22s  rej=%5d (%.1f%%)  any_order=%5.1f%%  joint_fit=%5.1f%%\n",
                inst_name, s.n_rejected, pct_rej, pct_any, pct_joint)
        flush(stdout)

        open(csv_path, "a") do io
            @printf(io, "%s,%d,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f\n",
                    inst_name, cls[1], cls[2],
                    s.n_routes, s.n_rejected, s.n_any_order, s.n_joint_fit,
                    pct_rej, pct_any, pct_joint)
        end
    end

    # ── summary by instance class ─────────────────────────────────────────────
    println()
    println("── Summary by instance class ─────────────────────────────────────")
    @printf("%-22s  %8s  %8s  %12s  %12s\n",
            "class", "routes", "rejected", "any_order%", "joint_fit%")
    println("-" ^ 68)
    for cls in sort(collect(keys(class_agg)))
        s = class_agg[cls]
        s[2] == 0 && continue
        @printf("(%3d req, %d box)        %8d  %8d  %11.1f%%  %11.1f%%\n",
                cls[1], cls[2], s[1], s[2],
                100.0 * s[3] / s[2],
                100.0 * s[4] / s[2])
    end
    println("-" ^ 68)

    # ── overall ───────────────────────────────────────────────────────────────
    println()
    @printf("OVERALL  routes=%d  rejected=%d  (%.1f%% rejection rate)\n",
            overall[1], overall[2], 100.0 * overall[2] / overall[1])

    if overall[2] > 0
        lb = 100.0 * overall[3] / overall[2]
        ub = 100.0 * overall[4] / overall[2]
        prov_infeas = 100.0 - ub
        @printf("\n  False-rejection rate bounds:\n")
        @printf("    Lower bound  (some ordering passes 3C-SP):   %6.2f%%\n", lb)
        @printf("    Upper bound  (items fit jointly, no order):  %6.2f%%\n", ub)
        @printf("    Provably infeasible (joint packing fails):   %6.2f%%\n", prov_infeas)
        println()
        println("  Interpretation:")
        println("  The fraction of zero-reloading-feasible routes excluded by")
        println("  3C-SP's vertical-separation constraint lies in")
        @printf("  [%.2f%%, %.2f%%] of all 3C-SP rejections.\n", lb, ub)
        println("  Routes outside this interval are provably infeasible under")
        println("  any oracle.")
    end

    println("\nResults written to: $csv_path")
end

main()
