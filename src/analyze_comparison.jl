# analyze_comparison.jl
# Analyses the 3-oracle comparison results (1csp/2csp/3csp at T_op=300s).
# Reads all comparison_worker_*.csv files, merges them, prints per-class
# and overall averages, and writes the updated §5.8 LaTeX ablation table.
#
# Usage (from project root, after all workers have finished):
#   julia --project=. src/analyze_comparison.jl

using Printf
using Statistics

const RESULTS_DIR = joinpath(@__DIR__, "..", "results")

# ── M&B 1D baselines (derived from M&B V5 avg / (1 + gap/100)) ────────────
const MB2016 = Dict(
    (50,  "RAND", 2) => (1634.33, 28.22),
    (50,  "RAND", 3) => (1622.36, 28.70),
    (50,  "CLUS", 2) => (1207.34, 23.57),
    (50,  "CLUS", 3) => (1169.94, 21.25),
    (50,  "CPCD", 2) => (1333.29, 21.03),
    (50,  "CPCD", 3) => (1320.94, 20.10),
    (75,  "RAND", 2) => (2145.67, 30.85),
    (75,  "RAND", 3) => (2124.77, 29.99),
    (75,  "CLUS", 2) => (1463.67, 26.23),
    (75,  "CLUS", 3) => (1455.71, 23.96),
    (75,  "CPCD", 2) => (2249.01, 23.31),
    (75,  "CPCD", 3) => (2235.34, 20.72),
    (100, "RAND", 2) => (4070.19, 31.88),
    (100, "RAND", 3) => (4040.47, 29.91),
    (100, "CLUS", 2) => (4193.50, 32.01),
    (100, "CLUS", 3) => (4155.06, 29.57),
    (100, "CPCD", 2) => (4320.29, 21.98),
    (100, "CPCD", 3) => (4258.44, 18.98),
)

function baseline_1d(size, layout, box)
    v5avg, v5gap = MB2016[(size, layout, box)]
    return v5avg / (1 + v5gap / 100)
end

function parse_inst(name)
    parts = split(name, "_")
    sz    = parse(Int, parts[1])
    lay   = parts[2]
    bx    = parse(Int, parts[3])
    return sz, lay, bx
end

# ── load all worker CSVs ───────────────────────────────────────────────────
# rows: (inst_name, seed, oracle, obj, pack_calls, pack_feasible)
rows = Tuple{String,Int,String,Float64,Int,Int}[]
for w in 0:4
    f = joinpath(RESULTS_DIR, "comparison_worker_$(w).csv")
    isfile(f) || continue
    for line in eachline(f)
        startswith(line, "instance") && continue
        parts = split(line, ",")
        length(parts) >= 4 || continue
        inst   = strip(parts[1])
        seed   = parse(Int, strip(parts[2]))
        oracle = strip(parts[3])
        obj    = parse(Float64, strip(parts[4]))
        n_calls    = length(parts) >= 6 ? parse(Int, strip(parts[6])) : 0
        n_feasible = length(parts) >= 7 ? parse(Int, strip(parts[7])) : 0
        push!(rows, (inst, seed, oracle, obj, n_calls, n_feasible))
    end
end
println("Total rows loaded: $(length(rows))")

# ── aggregate per (class, oracle) ─────────────────────────────────────────
# class = (size, layout, box) — "050_CLUS_2" maps to (50, "CLUS", 2)
cls_oracle_objs   = Dict{Tuple{Int,String,Int,String}, Vector{Float64}}()
cls_oracle_calls  = Dict{Tuple{Int,String,Int,String}, Vector{Int}}()
cls_oracle_feasible = Dict{Tuple{Int,String,Int,String}, Vector{Int}}()
for (inst, seed, oracle, obj, n_calls, n_feasible) in rows
    sz, lay, bx = parse_inst(inst)
    key = (sz, lay, bx, oracle)
    push!(get!(cls_oracle_objs,     key, Float64[]), obj)
    push!(get!(cls_oracle_calls,    key, Int[]),     n_calls)
    push!(get!(cls_oracle_feasible, key, Int[]),     n_feasible)
end

# ordered class list
classes = sort(unique([(sz, lay, bx) for (sz, lay, bx, _) in keys(cls_oracle_objs)]))

oracles = ["1csp", "2csp", "3csp"]

# ── helper: aggregate PCE for a (sz,lay,bx,oracle) key ────────────────────
function class_pce(sz, lay, bx, oracle)
    calls    = get(cls_oracle_calls,    (sz, lay, bx, oracle), Int[])
    feasible = get(cls_oracle_feasible, (sz, lay, bx, oracle), Int[])
    (isempty(calls) || sum(calls) == 0) && return NaN
    return sum(feasible) / sum(calls)
end

# ── print per-class table ──────────────────────────────────────────────────
println()
@printf("%-22s  %7s  %7s  %7s  %7s  %7s  %7s  %6s  %6s  %6s\n",
        "Class", "1C-SP", "2C-SP", "3C-SP",
        "Adv2v1(%)", "Adv3v1(%)", "Adv3v2(%)", "PCE1", "PCE2", "PCE3")
println(repeat("-", 105))

total_1 = Float64[]; total_2 = Float64[]; total_3 = Float64[]
tot_calls1 = 0; tot_calls2 = 0; tot_calls3 = 0
tot_feas1  = 0; tot_feas2  = 0; tot_feas3  = 0
for (sz, lay, bx) in classes
    a1 = get(cls_oracle_objs, (sz, lay, bx, "1csp"), Float64[])
    a2 = get(cls_oracle_objs, (sz, lay, bx, "2csp"), Float64[])
    a3 = get(cls_oracle_objs, (sz, lay, bx, "3csp"), Float64[])
    isempty(a1) && continue
    m1 = mean(a1); m2 = mean(a2); m3 = mean(a3)
    adv2v1 = 100*(m1 - m2)/m1
    adv3v1 = 100*(m1 - m3)/m1
    adv3v2 = 100*(m2 - m3)/m2
    p1 = class_pce(sz, lay, bx, "1csp")
    p2 = class_pce(sz, lay, bx, "2csp")
    p3 = class_pce(sz, lay, bx, "3csp")
    cls_label = @sprintf("%03d_%s_%d", sz, lay, bx)
    @printf("%-22s  %7.1f  %7.1f  %7.1f  %7.2f  %7.2f  %7.2f  %6.3f  %6.3f  %6.3f\n",
            cls_label, m1, m2, m3, adv2v1, adv3v1, adv3v2, p1, p2, p3)
    append!(total_1, a1); append!(total_2, a2); append!(total_3, a3)
    for lay2 in ["RAND","CLUS","CPCD"]
        global tot_calls1 += sum(get(cls_oracle_calls, (sz,lay2,bx,"1csp"), Int[]))
        global tot_calls2 += sum(get(cls_oracle_calls, (sz,lay2,bx,"2csp"), Int[]))
        global tot_calls3 += sum(get(cls_oracle_calls, (sz,lay2,bx,"3csp"), Int[]))
        global tot_feas1  += sum(get(cls_oracle_feasible, (sz,lay2,bx,"1csp"), Int[]))
        global tot_feas2  += sum(get(cls_oracle_feasible, (sz,lay2,bx,"2csp"), Int[]))
        global tot_feas3  += sum(get(cls_oracle_feasible, (sz,lay2,bx,"3csp"), Int[]))
    end
end
println(repeat("-", 105))
m1 = mean(total_1); m2 = mean(total_2); m3 = mean(total_3)
op1 = tot_calls1>0 ? tot_feas1/tot_calls1 : NaN
op2 = tot_calls2>0 ? tot_feas2/tot_calls2 : NaN
op3 = tot_calls3>0 ? tot_feas3/tot_calls3 : NaN
@printf("%-22s  %7.2f  %7.2f  %7.2f  %7.2f  %7.2f  %7.2f  %6.3f  %6.3f  %6.3f\n",
        "OVERALL", m1, m2, m3,
        100*(m1-m2)/m1, 100*(m1-m3)/m1, 100*(m2-m3)/m2, op1, op2, op3)
println()
@printf("Overall pack calls  — 1csp: %d   2csp: %d   3csp: %d\n",
        tot_calls1, tot_calls2, tot_calls3)

# ── pairwise win counts (needed for Wins column in LaTeX table) ────────────
pairs = Dict{Tuple{String,Int}, Dict{String,Float64}}()
for (inst, seed, oracle, obj, _, _) in rows
    d = get!(pairs, (inst, seed), Dict{String,Float64}())
    d[oracle] = obj
end

# per-(sz,bx) win counters: 3csp<1csp, 2csp<1csp, 3csp<2csp
szbx_wins = Dict{Tuple{Int,Int}, NTuple{3,Int}}()   # (sz,bx) => (w31, w21, w32)
szbx_npairs = Dict{Tuple{Int,Int}, Int}()
for ((inst, seed), d) in pairs
    (haskey(d,"1csp") && haskey(d,"2csp") && haskey(d,"3csp")) || continue
    sz, lay, bx = parse_inst(inst)
    k = (sz, bx)
    w31, w21, w32 = get(szbx_wins, k, (0,0,0))
    o1 = d["1csp"]; o2 = d["2csp"]; o3 = d["3csp"]
    w31 += (o3 < o1) ? 1 : 0
    w21 += (o2 < o1) ? 1 : 0
    w32 += (o3 < o2) ? 1 : 0
    szbx_wins[k]   = (w31, w21, w32)
    szbx_npairs[k] = get(szbx_npairs, k, 0) + 1
end

# overall pairwise wins
let
    n_3over1 = 0; n_2over1 = 0; n_3over2 = 0; n_2over3 = 0; n_tie32 = 0
    for ((inst, seed), d) in pairs
        (haskey(d,"1csp") && haskey(d,"2csp") && haskey(d,"3csp")) || continue
        o1 = d["1csp"]; o2 = d["2csp"]; o3 = d["3csp"]
        if o3 < o2; n_3over2 += 1
        elseif o2 < o3; n_2over3 += 1
        else; n_tie32 += 1; end
        o3 < o1 && (n_3over1 += 1)
        o2 < o1 && (n_2over1 += 1)
    end
    total_pairs = n_3over2 + n_2over3 + n_tie32
    println()
    println("Pairwise win counts:")
    println("  3C-SP < 2C-SP: $n_3over2 / $total_pairs")
    println("  2C-SP < 3C-SP: $n_2over3 / $total_pairs  (ties: $n_tie32)")
    println("  3C-SP < 1C-SP: $n_3over1 / $total_pairs")
    println("  2C-SP < 1C-SP: $n_2over1 / $total_pairs")
end

# ── generate Option-A LaTeX table ─────────────────────────────────────────
# Columns: Class | n | [1C-SP: Calls(M) PCE TTD] | [2C-SP: ...] | [3C-SP: ...]
#        | Adv 3v1(%) | Wins 3v1
szbx_groups = sort(unique([(sz, bx) for (sz, lay, bx) in classes]))

latex_path = joinpath(@__DIR__, "..", "latex", "tables", "ablation_3oracle.tex")
open(latex_path, "w") do io
    println(io, raw"% Auto-generated by analyze_comparison.jl -- do not edit manually.")
    println(io, raw"\begin{tabular}{@{}l r | r r | r r | r r | r r@{}}")
    println(io, raw"  \toprule")
    println(io, raw"  \multirow{2}{*}{Instance class} & \multirow{2}{*}{$n$}" *
                raw" & \multicolumn{2}{c|}{1C-SP (M\&B proxy)}" *
                raw" & \multicolumn{2}{c|}{2C-SP}" *
                raw" & \multicolumn{2}{c|}{3C-SP (ours)}" *
                raw" & \multirow{2}{*}{Adv 3v1 (\%)}" *
                raw" & \multirow{2}{*}{Wins 3v1} \\\\")
    println(io, raw"  \cmidrule(lr){3-4}\cmidrule(lr){5-6}\cmidrule(lr){7-8}")
    println(io, raw"  & & Calls (M) & TTD & Calls (M) & TTD" *
                raw" & Calls (M) & TTD & & \\\\" )
    println(io, raw"  \midrule")

    # Lower TTD is better — bold only the minimum TTD per row (ties allowed).
    is_best_ttd(x, vals) = isapprox(x, minimum(vals); rtol=0, atol=1e-6)
    fmt_calls(x) = @sprintf("%.1f", x)
    fmt_ttd1(x, vals) =
        is_best_ttd(x, vals) ? @sprintf("\\textbf{%.1f}", x) : @sprintf("%.1f", x)
    fmt_ttd2(x, vals) =
        is_best_ttd(x, vals) ? @sprintf("\\textbf{%.2f}", x) : @sprintf("%.2f", x)

    tot_c1=0; tot_c2=0; tot_c3=0; tot_f1=0; tot_f2=0; tot_f3=0
    tot_w31=0; tot_np=0

    for (sz, bx) in szbx_groups
        g1=Float64[]; g2=Float64[]; g3=Float64[]
        c1=0; c2=0; c3=0; f1=0; f2=0; f3=0
        for lay in ["RAND","CLUS","CPCD"]
            append!(g1, get(cls_oracle_objs, (sz,lay,bx,"1csp"), Float64[]))
            append!(g2, get(cls_oracle_objs, (sz,lay,bx,"2csp"), Float64[]))
            append!(g3, get(cls_oracle_objs, (sz,lay,bx,"3csp"), Float64[]))
            c1 += sum(get(cls_oracle_calls, (sz,lay,bx,"1csp"), Int[]))
            c2 += sum(get(cls_oracle_calls, (sz,lay,bx,"2csp"), Int[]))
            c3 += sum(get(cls_oracle_calls, (sz,lay,bx,"3csp"), Int[]))
            f1 += sum(get(cls_oracle_feasible, (sz,lay,bx,"1csp"), Int[]))
            f2 += sum(get(cls_oracle_feasible, (sz,lay,bx,"2csp"), Int[]))
            f3 += sum(get(cls_oracle_feasible, (sz,lay,bx,"3csp"), Int[]))
        end
        isempty(g1) && continue

        m1=mean(g1); m2=mean(g2); m3=mean(g3)
        pce1 = c1>0 ? f1/c1 : NaN
        pce2 = c2>0 ? f2/c2 : NaN
        pce3 = c3>0 ? f3/c3 : NaN
        adv31 = 100*(m1-m3)/m1
        adv31_str = adv31>=0 ? @sprintf("\$+\$%.2f", adv31) : @sprintf("\$-\$%.2f", abs(adv31))
        n = length(g1)

        w31, _, _ = get(szbx_wins, (sz,bx), (0,0,0))
        np        = get(szbx_npairs, (sz,bx), 0)

        sz_str = sz==50 ? "50\\,req" : sz==75 ? "75\\,req" : "100\\,req"
        bx_str = bx==2  ? "2\\,box/req" : "3\\,box/req"

        ttd_vals = [m1, m2, m3]

        println(io, "  $(sz_str), $(bx_str) & $n" *
            " & $(fmt_calls(c1/1e6)) & $(fmt_ttd1(m1, ttd_vals))" *
            " & $(fmt_calls(c2/1e6)) & $(fmt_ttd1(m2, ttd_vals))" *
            " & $(fmt_calls(c3/1e6)) & $(fmt_ttd1(m3, ttd_vals))" *
            " & $adv31_str & $w31/$np \\\\")

        tot_c1+=c1; tot_c2+=c2; tot_c3+=c3
        tot_f1+=f1; tot_f2+=f2; tot_f3+=f3
        tot_w31+=w31; tot_np+=np
    end

    println(io, raw"  \midrule")
    m1=mean(total_1); m2=mean(total_2); m3=mean(total_3)
    op1=tot_c1>0 ? tot_f1/tot_c1 : NaN
    op2=tot_c2>0 ? tot_f2/tot_c2 : NaN
    op3=tot_c3>0 ? tot_f3/tot_c3 : NaN
    adv31=100*(m1-m3)/m1
    adv31_str = adv31>=0 ? @sprintf("\$+\$%.2f", adv31) : @sprintf("\$-\$%.2f", abs(adv31))

    ttd_vals = [m1, m2, m3]

    println(io, "  \\textbf{Overall} & $(length(total_1))" *
        " & $(fmt_calls(tot_c1/1e6)) & $(fmt_ttd2(m1, ttd_vals))" *
        " & $(fmt_calls(tot_c2/1e6)) & $(fmt_ttd2(m2, ttd_vals))" *
        " & $(fmt_calls(tot_c3/1e6)) & $(fmt_ttd2(m3, ttd_vals))" *
        " & $adv31_str & $tot_w31/$tot_np \\\\")
    println(io, raw"  \bottomrule")
    println(io, raw"\end{tabular}")
end
println("\nLaTeX table written to: $latex_path")
