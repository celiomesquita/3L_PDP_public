# Density stacking impact analysis for 3L-PDP
#
# Estimates the TTD cost of imposing a density ordering constraint (3C-SP-D):
# items delivered last (floor compartment) must be denser than items delivered
# first (top compartment).
#
# Method: Monte Carlo — N random chromosomes per instance, decoded via NN tour
# (same decoder as BRKGA).  For each decoded route, records:
#   (a) whether the peak co-loading state is density-compliant
#   (b) whether pack_route deems it feasible (base 3C-SP)
#   (c) total travel distance (TTD)
#
# Compares:
#   TTD_base    = best TTD among packing-feasible routes (3C-SP, no density)
#   TTD_density = best TTD among packing-feasible AND density-compliant routes
#   Gap%        = (TTD_density - TTD_base) / TTD_base × 100
#
# Usage (from project root, single-threaded to not compete with benchmark):
#   julia --project=. src/density_impact.jl

using Printf, Statistics, Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("brkga.jl")   # for _nn_tour and PDPInstance

const N_SAMPLES     = 2_000   # random chromosomes per instance
const PILOT_INSTS   = [       # one per size × layout × box combination
    "050_RAND_2_1", "050_RAND_3_1",
    "050_CLUS_2_1", "050_CLUS_3_1",
    "050_CPCD_2_1", "050_CPCD_3_1",
    "075_RAND_2_1", "075_RAND_3_1",
    "075_CLUS_2_1", "075_CLUS_3_1",
    "075_CPCD_2_1", "075_CPCD_3_1",
    "100_RAND_2_1", "100_RAND_3_1",
    "100_CLUS_2_1", "100_CLUS_3_1",
    "100_CPCD_2_1", "100_CPCD_3_1",
]

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")

# ── replicate BRKGA decoder for a single chromosome ──────────────────────────
function decode_chromosome(chr::Vector{Float64}, pdp::PDPInstance)
    inst = pdp.inst
    n    = pdp.n
    K    = pdp.K
    C    = pdp.dist

    veh_reqs = [Int[] for _ in 1:K]
    for r in 1:n
        k = min(K, floor(Int, chr[r] * K) + 1)
        push!(veh_reqs[k], r)
    end

    travel_cost = 0.0
    all_compliant = true
    all_feasible  = true

    for k in 1:K
        reqs = veh_reqs[k]
        isempty(reqs) && continue

        route = _nn_tour(reqs, n, C)

        # travel cost
        prev = 1
        for v in route
            nxt = v > 0 ? v + 1 : -v + n + 1
            travel_cost += C[prev, nxt]
            prev = nxt
        end
        travel_cost += C[prev, 1]

        # peak co-loading state
        delivery_pos = Dict{Int,Int}()
        for (pos, v) in enumerate(route)
            v < 0 && (delivery_pos[-v] = pos)
        end
        loaded      = Int[]
        peak_loaded = Int[]
        for v in route
            if v > 0
                push!(loaded, v)
                length(loaded) > length(peak_loaded) && (peak_loaded = copy(loaded))
            else
                filter!(x -> x != -v, loaded)
            end
        end
        sort!(peak_loaded; by = r -> delivery_pos[r])

        # density compliance of peak co-loading state (independent of pack_route flag)
        if length(peak_loaded) > 1
            densities = [req_density(inst.requests[r]) for r in peak_loaded]
            issorted(densities) || (all_compliant = false)
        end

        # packing feasibility (base 3C-SP, density flag OFF)
        _USE_DENSITY[] = false
        pack_route(peak_loaded, inst) == 0 || (all_feasible = false)
    end

    return travel_cost, all_feasible, all_compliant
end

# ── main ──────────────────────────────────────────────────────────────────────
function main()
    rng = MersenneTwister(42)

    println("Density stacking impact analysis  (N=$N_SAMPLES samples/instance)")
    println()
    @printf("%-22s  %3s  %8s  %8s  %8s  %7s  %7s\n",
            "Instance", "n", "Compl%", "Feas%", "FeasCompl%",
            "TTD_base", "TTD_dens")
    println("-"^80)

    summary_gaps = Float64[]

    for inst_name in PILOT_INSTS
        path = joinpath(INSTANCES_DIR, inst_name * ".txt")
        isfile(path) || (println("  SKIP (not found): $inst_name"); continue)

        inst = parse_instance(path)
        pdp  = PDPInstance(inst)
        n    = pdp.n

        ttd_feasible  = Float64[]   # TTD of packing-feasible routes
        ttd_fc        = Float64[]   # TTD of feasible AND density-compliant routes
        n_compliant   = 0
        n_feasible    = 0
        n_fc          = 0

        for _ in 1:N_SAMPLES
            chr = rand(rng, n)
            ttd, feasible, compliant = decode_chromosome(chr, pdp)

            compliant && (n_compliant += 1)
            if feasible
                n_feasible += 1
                push!(ttd_feasible, ttd)
                compliant && (n_fc += 1; push!(ttd_fc, ttd))
            end
        end

        compl_pct  = n_compliant / N_SAMPLES * 100
        feas_pct   = n_feasible  / N_SAMPLES * 100
        fc_pct     = n_fc        / N_SAMPLES * 100

        ttd_base = isempty(ttd_feasible) ? NaN : minimum(ttd_feasible)
        ttd_dens = isempty(ttd_fc)       ? NaN : minimum(ttd_fc)
        gap      = (isnan(ttd_base) || isnan(ttd_dens)) ? NaN :
                    (ttd_dens - ttd_base) / ttd_base * 100

        isnan(gap) || push!(summary_gaps, gap)

        @printf("%-22s  %3d  %7.1f%%  %7.1f%%  %9.1f%%  %7.1f  %7.1f",
                inst_name, n, compl_pct, feas_pct, fc_pct, ttd_base, ttd_dens)
        isnan(gap) ? println("  --") : @printf("  %+6.2f%%\n", gap)
    end

    println("-"^80)
    if !isempty(summary_gaps)
        @printf("Mean TTD gap (density constraint):  %+.2f%%\n", mean(summary_gaps))
        @printf("Max  TTD gap (density constraint):  %+.2f%%\n", maximum(summary_gaps))
    end
    println()
    println("Legend:")
    println("  Compl%     — peak co-loading state satisfies density ordering")
    println("  Feas%      — route is packing-feasible (base 3C-SP)")
    println("  FeasCompl% — feasible AND density-compliant")
    println("  TTD_base   — best TTD among feasible routes (3C-SP)")
    println("  TTD_dens   — best TTD among feasible + density-compliant routes (3C-SP-D)")
    println("  Gap%       — TTD increase imposed by density constraint")
end

main()
