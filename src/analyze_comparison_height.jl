# Analyze packing-oracle depth study with multiple vehicle heights.
# Reads results/comparison_oracle_depth_worker_*.csv, prints per-Hv summaries,
# and writes latex/tables/ablation_3oracle_height_study.tex (Table V format + H_v).
#
# Usage:
#   julia --project=. src/analyze_comparison_height.jl

using Printf
using Statistics

const RESULTS_DIR = joinpath(@__DIR__, "..", "results")
const LAYOUTS = ["RAND", "CLUS", "CPCD"]

# M&B instance files use decimeters: Hv=30 → 3.0 m.
hv_to_meters(Hv::Int) = Hv / 10.0

function parse_inst(name)
    parts = split(name, "_")
    return parse(Int, parts[1]), parts[2], parse(Int, parts[3])
end

function load_rows()
    files = String[]
    merged = joinpath(RESULTS_DIR, "comparison_oracle_depth_height.csv")
    isfile(merged) && push!(files, merged)
    for w in 0:63
        f = joinpath(RESULTS_DIR, "comparison_oracle_depth_worker_$(w).csv")
        isfile(f) && !(f in files) && push!(files, f)
    end
    isempty(files) && error("No comparison_oracle_depth_worker_*.csv in $RESULTS_DIR")

    dedup = Dict{Tuple{String,Int,String,Int}, Tuple{Float64,Int,Int}}()
    for f in files
        for line in eachline(f)
            startswith(line, "instance") && continue
            parts = split(line, ",")
            length(parts) < 4 && continue
            inst   = strip(parts[1])
            seed   = parse(Int, strip(parts[2]))
            oracle = strip(parts[3])
            if length(parts) >= 8 && tryparse(Int, strip(parts[4])) !== nothing
                Hv  = parse(Int, strip(parts[4]))
                obj = parse(Float64, strip(parts[5]))
                nc  = parse(Int, strip(parts[7]))
                nf  = parse(Int, strip(parts[8]))
            else
                Hv  = 30
                obj = parse(Float64, strip(parts[4]))
                nc  = length(parts) >= 6 ? parse(Int, strip(parts[6])) : 0
                nf  = length(parts) >= 7 ? parse(Int, strip(parts[7])) : 0
            end
            dedup[(inst, seed, oracle, Hv)] = (obj, nc, nf)
        end
    end
    return [(inst, seed, oracle, Hv, obj, nc, nf)
            for ((inst, seed, oracle, Hv), (obj, nc, nf)) in dedup]
end

function summarize_hv(rows, Hv::Int)
    sub = [r for r in rows if r[4] == Hv]
    isempty(sub) && return nothing

    cls_objs  = Dict{Tuple{Int,String,Int,String}, Vector{Float64}}()
    cls_calls = Dict{Tuple{Int,String,Int,String}, Vector{Int}}()
    for (inst, seed, oracle, _, obj, nc, _) in sub
        sz, lay, bx = parse_inst(inst)
        push!(get!(cls_objs, (sz, lay, bx, oracle), Float64[]), obj)
        push!(get!(cls_calls, (sz, lay, bx, oracle), Int[]), nc)
    end

    classes = sort(unique([(sz, lay, bx) for (sz, lay, bx, _) in keys(cls_objs)]))
    total_1 = Float64[]; total_2 = Float64[]; total_3 = Float64[]

    println()
    println("=" ^ 80)
    @printf("Vehicle height Hv = %d  (%.1f m)  (%d rows)\n", Hv, hv_to_meters(Hv), length(sub))
    println("=" ^ 80)
    @printf("%-22s  %8s  %8s  %8s  %8s  %8s\n", "Class", "1C-SP", "2C-SP", "3C-SP", "Adv2v1%", "Adv3v2%")
    println(repeat("-", 72))

    for (sz, lay, bx) in classes
        a1 = get(cls_objs, (sz, lay, bx, "1csp"), Float64[])
        a2 = get(cls_objs, (sz, lay, bx, "2csp"), Float64[])
        a3 = get(cls_objs, (sz, lay, bx, "3csp"), Float64[])
        isempty(a1) && continue
        m1, m2, m3 = mean(a1), mean(a2), mean(a3)
        @printf("%-22s  %8.1f  %8.1f  %8.1f  %7.2f  %7.2f\n",
                @sprintf("%03d_%s_%d", sz, lay, bx), m1, m2, m3,
                100 * (m1 - m2) / m1, 100 * (m2 - m3) / m2)
        append!(total_1, a1); append!(total_2, a2); append!(total_3, a3)
    end

    m1, m2, m3 = mean(total_1), mean(total_2), mean(total_3)
    println(repeat("-", 72))
    @printf("%-22s  %8.2f  %8.2f  %8.2f  %7.2f  %7.2f\n",
            "OVERALL", m1, m2, m3, 100 * (m1 - m2) / m1, 100 * (m2 - m3) / m2)

    pairs = Dict{Tuple{String,Int}, Dict{String,Float64}}()
    for (inst, seed, oracle, _, obj, _, _) in sub
        get!(pairs, (inst, seed), Dict{String,Float64}())[oracle] = obj
    end
    w21 = w32 = np = 0
    for (_, d) in pairs
        (haskey(d, "1csp") && haskey(d, "2csp") && haskey(d, "3csp")) || continue
        np += 1
        w21 += d["2csp"] < d["1csp"] ? 1 : 0
        w32 += d["3csp"] < d["2csp"] ? 1 : 0
    end
    @printf("Pairwise: 2C better than 1C: %d/%d   3C better than 2C: %d/%d\n", w21, np, w32, np)
    return (Hv=Hv, m1=m1, m2=m2, m3=m3, w21=w21, w32=w32, np=np)
end

"""Mean TTD for (sz, bx, oracle, Hv) aggregated over RAND/CLUS/CPCD."""
function class_mean_ttd(cls_objs, sz, bx, oracle, Hv)
    g = Float64[]
    for lay in LAYOUTS
        append!(g, get(cls_objs, (sz, lay, bx, oracle, Hv), Float64[]))
    end
    return isempty(g) ? nothing : (mean(g), length(g))
end

function write_latex_height_study(rows)
    cls_objs = Dict{Tuple{Int,String,Int,String,Int}, Vector{Float64}}()
    for (inst, seed, oracle, Hv, obj, _, _) in rows
        sz, lay, bx = parse_inst(inst)
        push!(get!(cls_objs, (sz, lay, bx, oracle, Hv), Float64[]), obj)
    end

    HV_LO = 30
    HV_HI = 36
    szbx_groups = sort(unique([(sz, bx) for (sz, lay, bx, _, _) in keys(cls_objs)]))

    is_best_ttd(x, a, b) = isapprox(x, min(a, b); rtol=0, atol=1e-6)
    function fmt_ttd(x, a, b; dec::Int=1)
        bold = is_best_ttd(x, a, b)
        if dec == 2
            return bold ? @sprintf("\\textbf{%.2f}", x) : @sprintf("%.2f", x)
        end
        return bold ? @sprintf("\\textbf{%.1f}", x) : @sprintf("%.1f", x)
    end
    # Percent change in TTD from 2.5 m → 3.0 m: negative when 3.0 m is better (lower TTD).
    fmt_delta(lo, hi) = begin
        pct = 100 * (hi - lo) / lo
        pct >= 0 ? @sprintf("\$+\$%.2f", pct) : @sprintf("\$-\$%.2f", abs(pct))
    end

    function oracle_block(io, m_lo, m_hi; dec::Int=1)
        print(io, " & $(fmt_ttd(m_lo, m_lo, m_hi; dec=dec))")
        print(io, " & $(fmt_ttd(m_hi, m_lo, m_hi; dec=dec))")
        print(io, " & $(fmt_delta(m_lo, m_hi))")
    end

    latex_path = joinpath(@__DIR__, "..", "latex", "tables", "ablation_3oracle_height_study.tex")
    open(latex_path, "w") do io
        eol = " \\\\\n"
        println(io, "% Auto-generated by analyze_comparison_height.jl")
        println(io, raw"\begin{tabular}{@{}l r | r r r | r r r | r r r@{}}")
        println(io, raw"  \toprule")
        print(io, raw"  & & \multicolumn{3}{c|}{1C-SP (M\&B proxy)}")
        print(io, raw" & \multicolumn{3}{c|}{2C-SP}")
        println(io, raw" & \multicolumn{3}{c}{3C-SP (ours)}" * eol)
        println(io, raw"  \cmidrule(lr){3-5}\cmidrule(lr){6-8}\cmidrule(lr){9-11}")
        println(io, raw"  Instance class & $n$ & \multicolumn{1}{c}{3.0\,m} & \multicolumn{1}{c}{3.6\,m} & \multicolumn{1}{c|}{$\Delta$\%}" *
                    raw" & \multicolumn{1}{c}{3.0\,m} & \multicolumn{1}{c}{3.6\,m} & \multicolumn{1}{c|}{$\Delta$\%}" *
                    raw" & \multicolumn{1}{c}{3.0\,m} & \multicolumn{1}{c}{3.6\,m} & \multicolumn{1}{c}{$\Delta$\%}" * eol)
        println(io, raw"  \midrule")

        for (sz, bx) in szbx_groups
            r1 = class_mean_ttd(cls_objs, sz, bx, "1csp", HV_LO)
            r2 = class_mean_ttd(cls_objs, sz, bx, "2csp", HV_LO)
            r3 = class_mean_ttd(cls_objs, sz, bx, "3csp", HV_LO)
            r1 === nothing && continue
            m1_lo, n = r1
            m1_hi, _ = class_mean_ttd(cls_objs, sz, bx, "1csp", HV_HI)
            m2_lo, _ = r2
            m2_hi, _ = class_mean_ttd(cls_objs, sz, bx, "2csp", HV_HI)
            m3_lo, _ = r3
            m3_hi, _ = class_mean_ttd(cls_objs, sz, bx, "3csp", HV_HI)
            m1_hi === nothing && continue

            sz_str = sz == 50 ? "50\\,req" : sz == 75 ? "75\\,req" : "100\\,req"
            bx_str = bx == 2 ? "2\\,box/req" : "3\\,box/req"
            print(io, "  $(sz_str), $(bx_str) & $n")
            oracle_block(io, m1_lo, m1_hi)
            oracle_block(io, m2_lo, m2_hi)
            oracle_block(io, m3_lo, m3_hi)
            println(io, eol)
        end

        # Overall: pool all instance-seed TTDs per (oracle, height)
        function pool(oracle, Hv)
            [obj for (inst, seed, o, Hv2, obj, _, _) in rows if o == oracle && Hv2 == Hv]
        end
        g1_lo, g1_hi = pool("1csp", HV_LO), pool("1csp", HV_HI)
        g2_lo, g2_hi = pool("2csp", HV_LO), pool("2csp", HV_HI)
        g3_lo, g3_hi = pool("3csp", HV_LO), pool("3csp", HV_HI)
        m1_lo, m1_hi = mean(g1_lo), mean(g1_hi)
        m2_lo, m2_hi = mean(g2_lo), mean(g2_hi)
        m3_lo, m3_hi = mean(g3_lo), mean(g3_hi)
        np = length(g1_lo)

        println(io, raw"  \midrule")
        print(io, "  \\textbf{Overall} & $np")
        oracle_block(io, m1_lo, m1_hi; dec=2)
        oracle_block(io, m2_lo, m2_hi; dec=2)
        oracle_block(io, m3_lo, m3_hi; dec=2)
        println(io, eol)
        println(io, raw"  \bottomrule")
        println(io, raw"\end{tabular}")
    end
    println("\nLaTeX table → $latex_path")
end

function main()
    rows = load_rows()
    println("Loaded $(length(rows)) deduplicated rows")
    hv_vals = sort(unique(r[4] for r in rows))
    println("Heights (Hv): ", hv_vals)

    summaries = filter(!isnothing, [summarize_hv(rows, Hv) for Hv in hv_vals])

    if length(summaries) >= 2
        println()
        println("=" ^ 80)
        println("Cross-height (3C-SP mean TTD)")
        println("=" ^ 80)
        for s in summaries
            @printf("  Hv=%2d (%.1f m)  1C=%8.2f  2C=%8.2f  3C=%8.2f  (3C wins 2C: %d/%d)\n",
                    s.Hv, hv_to_meters(s.Hv), s.m1, s.m2, s.m3, s.w32, s.np)
        end
        base = summaries[1]
        for s in summaries[2:end]
            @printf("  3C-SP TTD %.1f m vs %.1f m: %+.2f%%\n",
                    hv_to_meters(s.Hv), hv_to_meters(base.Hv),
                    100 * (base.m3 - s.m3) / base.m3)
        end
    end

    write_latex_height_study(rows)
end

main()
