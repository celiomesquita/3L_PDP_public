# Ablation: 2C-SP-only vs 3C-SP packing oracle
#
# For every feasible route recorded in results/results.csv (obj < 1e6),
# decode the chromosome back to routes and ask:
#   - Does 2C-SP alone (ignoring the k>=3 branch) certify the route?
#   - Does 3C-SP add any routes that 2C-SP alone would reject?
#   - How often does the 3C-SP triple contribute the decisive savings?
#
# Usage:
#   julia --project=. src/ablation_3csp.jl
#
# Output: printed summary + results/ablation_3csp.csv

using Statistics
using Printf

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")   # for _chromosome_to_pdp_routes, PDPInstance

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")
const RESULTS_DIR   = joinpath(@__DIR__, "..", "results")

# ── 2C-SP-only version of pack_route ──────────────────────────────────────────
function pack_route_2csp_only(route_ids::Vector{Int}, inst::Instance)::Int
    isempty(route_ids) && return 0
    requests      = [inst.requests[r] for r in route_ids]
    n_boxes_total = sum(length(r.boxes) for r in requests)
    sum(r.total_weight for r in requests) > inst.Q && return n_boxes_total
    Wv = inst.Wv;  Hv = inst.Hv;  Lv = inst.Lv
    depths = Int[_depth_1csp(r, Wv, Hv) for r in requests]
    any(d == _PACK_INF for d in depths) && return n_boxes_total
    sum(depths) <= Lv && return 0
    N = length(requests)
    N < 2 && return n_boxes_total
    deficit = sum(depths) - Lv
    opt_km2 = 0
    opt_km1 = 0
    for k in 2:N
        d2    = _depth_2csp(requests[k-1], requests[k], Wv, Hv)
        ps2   = max(0, depths[k-1] + depths[k] - d2)
        opt_k = max(opt_km1, opt_km2 + ps2)
        opt_k >= deficit && return 0
        opt_km2 = opt_km1
        opt_km1 = opt_k
    end
    return n_boxes_total
end

# ── per-route 3C-SP contribution tracker ──────────────────────────────────────
# Returns (was_feasible_full, was_feasible_2csp, triple_was_decisive)
function audit_route(route_ids::Vector{Int}, inst::Instance)
    isempty(route_ids) && return (true, true, false)
    requests      = [inst.requests[r] for r in route_ids]
    Wv = inst.Wv;  Hv = inst.Hv;  Lv = inst.Lv
    n_boxes_total = sum(length(r.boxes) for r in requests)
    sum(r.total_weight for r in requests) > inst.Q && return (false, false, false)
    depths = Int[_depth_1csp(r, Wv, Hv) for r in requests]
    any(d == _PACK_INF for d in depths) && return (false, false, false)
    sum(depths) <= Lv && return (true, true, false)   # 1C-SP already fits

    N = length(requests)
    N < 2 && return (false, false, false)
    deficit = sum(depths) - Lv

    # ── full 3C-SP DP (records whether triple branch was ever decisive) ──
    opt_km3 = 0; opt_km2 = 0; opt_km1 = 0
    triple_decisive = false
    feasible_full   = false
    for k in 2:N
        d2  = _depth_2csp(requests[k-1], requests[k], Wv, Hv)
        ps2 = max(0, depths[k-1] + depths[k] - d2)
        opt_k_no3 = max(opt_km1, opt_km2 + ps2)
        opt_k = opt_k_no3
        if k >= 3
            d3  = _depth_3csp(requests[k-2], requests[k-1], requests[k], Wv, Hv)
            ps3 = max(0, depths[k-2] + depths[k-1] + depths[k] - d3)
            cand3 = opt_km3 + ps3
            if cand3 > opt_k_no3
                opt_k = cand3
                triple_decisive = true
            end
        end
        if opt_k >= deficit; feasible_full = true; break; end
        opt_km3 = opt_km2; opt_km2 = opt_km1; opt_km1 = opt_k
    end

    # ── 2C-SP-only DP ──
    opt_km2 = 0; opt_km1 = 0
    feasible_2c = false
    for k in 2:N
        d2  = _depth_2csp(requests[k-1], requests[k], Wv, Hv)
        ps2 = max(0, depths[k-1] + depths[k] - d2)
        opt_k = max(opt_km1, opt_km2 + ps2)
        if opt_k >= deficit; feasible_2c = true; break; end
        opt_km2 = opt_km1; opt_km1 = opt_k
    end

    return (feasible_full, feasible_2c, triple_decisive && feasible_full && !feasible_2c)
end

# ── main ──────────────────────────────────────────────────────────────────────
function main()
    # Load all instances once
    inst_map = Dict{String, Instance}()
    for f in readdir(INSTANCES_DIR)
        endswith(f, ".txt") && f != "readme.txt" || continue
        name = replace(f, ".txt" => "")
        inst_map[name] = parse_instance(joinpath(INSTANCES_DIR, f))
    end

    csv_out = joinpath(RESULTS_DIR, "ablation_3csp.csv")
    open(csv_out, "w") do io
        println(io, "instance,n_req,n_box,n_routes,n_routes_feasible_full," *
                    "n_routes_feasible_2csp,n_routes_only_3csp,pct_only_3csp")
    end

    total_routes = 0; total_feasible_full = 0
    total_feasible_2c = 0; total_only_3c = 0

    for (inst_name, inst) in sort(collect(inst_map); by = x -> x[1])
        # Build a PDPInstance and sample routes via NN for all possible vehicle assignments
        pdp  = PDPInstance(inst)
        n    = pdp.n
        parts = split(inst_name, "_")
        n_req = something(tryparse(Int, parts[1]), 0)
        n_box = something(tryparse(Int, parts[3]), 0)

        # Generate 500 random chromosomes and decode to routes
        n_routes_total = 0; n_ff = 0; n_f2c = 0; n_only3 = 0
        for _ in 1:500
            chr = rand(n)
            routes = _chromosome_to_pdp_routes(chr, pdp)
            for route in routes
                length(route) < 2 && continue
                # Convert signed-int route → delivery-order request ids
                req_ids = [v > 0 ? v : -v for v in route if v < 0]  # delivery order
                isempty(req_ids) && continue
                n_routes_total += 1
                ff, f2c, only3 = audit_route(req_ids, inst)
                ff     && (n_ff    += 1)
                f2c    && (n_f2c   += 1)
                only3  && (n_only3 += 1)
            end
        end

        pct = n_ff > 0 ? 100.0 * n_only3 / n_ff : 0.0
        @printf("  %-22s  routes=%5d  feas_full=%5d  feas_2csp=%5d  only_3csp=%4d  (%.1f%% of feasible)\n",
                inst_name, n_routes_total, n_ff, n_f2c, n_only3, pct)
        flush(stdout)

        open(csv_out, "a") do io
            println(io, "$inst_name,$n_req,$n_box,$n_routes_total,$n_ff,$n_f2c,$n_only3,$(round(pct;digits=2))")
        end

        total_routes      += n_routes_total
        total_feasible_full += n_ff
        total_feasible_2c  += n_f2c
        total_only_3c      += n_only3
    end

    println("\n── Aggregate across all 54 instances ────────────────────────────")
    @printf("Total routes sampled : %d\n", total_routes)
    @printf("Feasible (full 3C-SP): %d  (%.1f%%)\n",
            total_feasible_full, 100.0 * total_feasible_full / total_routes)
    @printf("Feasible (2C-SP only): %d  (%.1f%%)\n",
            total_feasible_2c,  100.0 * total_feasible_2c  / total_routes)
    @printf("Only feasible via 3C-SP: %d  (%.1f%% of all feasible routes)\n",
            total_only_3c, total_feasible_full > 0 ?
            100.0 * total_only_3c / total_feasible_full : 0.0)
    println("\nResults written to: $csv_out")
end

main()
