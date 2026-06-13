# Select hardest 20% of heterogeneous instances by 3L-PDP-H baseline TTD
# (same source as Table tab:results_hetero, col. 3L-PDP-H Avg).
#
# Usage:
#   julia --project=. src/select_hardest_hetero_instances.jl [fraction] [out_path]

using Printf
using Statistics

const HETERO_BASELINE_CSV = joinpath(@__DIR__, "..", "results", "memetic_benchmark_3lpdp_h.csv")
const DEFAULT_OUT = joinpath(@__DIR__, "..", "3L_PDP_instances_hetero", "hardest_hetero_top20pct.txt")

function parse_inst_key(name::String)
    # 050_CLUS_2_1_H3 -> (50, "CLUS", 2, 1, 3)
    parts = split(name, "_")
    sz = parse(Int, parts[1])
    lay = parts[2]
    bx = parse(Int, parts[3])
    idx = parse(Int, parts[4])
    h = parse(Int, replace(parts[5], "H" => ""))
    return (sz, lay, bx, idx, h)
end

function class_label(sz, lay, bx)
    @sprintf("%d %s, %d box", sz, lay, bx)
end

function load_baseline_ttd(csv_path::String)
    rows = Tuple{String, Float64}[]
    for line in eachline(csv_path)
        startswith(line, "instance,") && continue
        p = split(line, ",")
        length(p) >= 11 || continue
        strip(p[2]) == "3lpdp_h" || continue
        parse(Int, strip(p[3])) != 1 && continue  # seed 1 (hetero table convention)
        lowercase(strip(p[10])) == "true" || continue
        ttd = parse(Float64, strip(p[7]))
        push!(rows, (strip(p[1]), ttd))
    end
    return rows
end

function main()
    frac = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 0.20
    out_path = length(ARGS) >= 2 ? ARGS[2] : DEFAULT_OUT
    isfile(HETERO_BASELINE_CSV) || error("Missing $HETERO_BASELINE_CSV")

    rows = load_baseline_ttd(HETERO_BASELINE_CSV)
    sort!(rows, by = r -> r[2], rev = true)
    n_total = length(rows)
    n_pick = max(1, ceil(Int, frac * n_total))
    selected = rows[1:n_pick]

    threshold = selected[end][2]
    println("Hardest $(frac*100)% of hetero instances (3L-PDP-H baseline TTD, seed 1)")
    println("  Source: $HETERO_BASELINE_CSV")
    println("  Total feasible: $n_total  →  selected: $n_pick  (TTD >= $(round(threshold, digits=2)))")
    println()

    # Per-class counts in selection vs table ranks
    cls_count = Dict{String, Int}()
    cls_ttd = Dict{String, Vector{Float64}}()
    for (inst, ttd) in selected
        sz, lay, bx, _, _ = parse_inst_key(inst)
        lbl = class_label(sz, lay, bx)
        cls_count[lbl] = get(cls_count, lbl, 0) + 1
        push!(get!(cls_ttd, lbl, Float64[]), ttd)
    end
    println("Selected instances by class (cf. Table tab:results_hetero):")
    for lbl in sort(collect(keys(cls_count)))
        n = cls_count[lbl]
        @printf("  %-18s  %3d instances  mean TTD=%.2f\n", lbl, n, mean(cls_ttd[lbl]))
    end
    println()

    open(out_path, "w") do io
        println(io, "# Hardest $(frac*100)% hetero instances by 3L-PDP-H TTD (seed 1)")
        println(io, "# n_pick=$n_pick  threshold=$threshold")
        for (inst, ttd) in selected
            @printf(io, "%s,%.5f\n", inst, ttd)
        end
    end
    println("Wrote $out_path")
end

main()
