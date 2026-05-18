# Generate LaTeX tables from benchmark results CSV.
#
# Reads results/results.csv (produced by run_benchmark.jl) and writes:
#   latex/tables/results_summary.tex   — Table 3: per-class averages
#   latex/tables/results_detailed.tex  — Table 4: per-instance results
#
# Usage (from project root):
#   julia --project=. src/gen_tables.jl
#
# The 1D baselines (routing-only lower bounds) are derived from the
# Mannel & Bortfeldt (2016) V5 data embedded below:
#   ttd_1D = v5_avg / (1 + v5_gap/100)

using Printf
using Statistics

# ── M&B (2016) reference data ─────────────────────────────────────────────────
# Format: class_key => (v5_avg, v5_gap_pct)
# class_key = (size, layout, box)  e.g. (50, "RAND", 2)
# 1D baseline: ttd_1D = v5_avg / (1 + v5_gap/100)

# ── M&B (2018) V4 per-instance data ──────────────────────────────────────────
# Source: Männel & Bortfeldt (2018) Table 15 (Appendix A).
# V4 = RS loading + RS unloading + Reloading ban; NO IPR routing constraint.
# Values are mean ttd over 5 runs as published.
const MB2018_V4 = Dict(
    "050_RAND_2_1" => 1635.72, "050_RAND_2_2" => 1506.50, "050_RAND_2_3" => 1526.49,
    "050_RAND_2_4" => 1540.53, "050_RAND_2_5" => 1487.54,
    "050_CLUS_2_1" => 1071.01, "050_CLUS_2_2" => 1036.82, "050_CLUS_2_3" => 1092.75,
    "050_CLUS_2_4" => 1229.84, "050_CLUS_2_5" => 1320.13,
    "050_CPCD_2_1" => 1347.40, "050_CPCD_2_2" => 1270.08, "050_CPCD_2_3" => 1201.01,
    "050_CPCD_2_4" => 1318.11, "050_CPCD_2_5" => 1452.44,
    "050_RAND_3_1" => 1591.50, "050_RAND_3_2" => 1463.68, "050_RAND_3_3" => 1553.59,
    "050_RAND_3_4" => 1507.59, "050_RAND_3_5" => 1513.57,
    "050_CLUS_3_1" => 1026.93, "050_CLUS_3_2" => 1009.62, "050_CLUS_3_3" => 1075.38,
    "050_CLUS_3_4" => 1213.93, "050_CLUS_3_5" => 1300.73,
    "050_CPCD_3_1" => 1353.83, "050_CPCD_3_2" => 1273.55, "050_CPCD_3_3" => 1220.64,
    "050_CPCD_3_4" => 1317.87, "050_CPCD_3_5" => 1434.08,
    "075_RAND_2_1" => 2097.80, "075_RAND_2_2" => 2052.71, "075_RAND_2_3" => 2099.16,
    "075_CLUS_2_1" => 1429.87, "075_CLUS_2_2" => 1385.28, "075_CLUS_2_3" => 1454.94,
    "075_CPCD_2_1" => 2185.09, "075_CPCD_2_2" => 2184.20, "075_CPCD_2_3" => 2265.27,
    "075_RAND_3_1" => 2135.84, "075_RAND_3_2" => 2031.04, "075_RAND_3_3" => 2052.43,
    "075_CLUS_3_1" => 1448.22, "075_CLUS_3_2" => 1400.21, "075_CLUS_3_3" => 1481.37,
    "075_CPCD_3_1" => 2243.73, "075_CPCD_3_2" => 2265.49, "075_CPCD_3_3" => 2239.72,
    "100_RAND_2_1" => 3991.39,
    "100_CLUS_2_1" => 4130.58,
    "100_CPCD_2_1" => 4272.27,
    "100_RAND_3_1" => 4044.72,
    "100_CLUS_3_1" => 4149.49,
    "100_CPCD_3_1" => 4320.01,
)

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

# ── parse instance name ────────────────────────────────────────────────────────
# "050_CLUS_2_1" → (size=50, layout="CLUS", box=2, idx=1)
function parse_inst_name(name::String)
    parts  = split(name, "_")
    size   = parse(Int, parts[1])
    layout = parts[2]
    box    = parse(Int, parts[3])
    idx    = parse(Int, parts[4])
    return size, layout, box, idx
end

# ── M&B (2016) time limits per class (seconds) ────────────────────────────────
# These are the per-instance-class wall-clock budgets from Männel & Bortfeldt
# (2016) Table 7, also used as the BRKGA time limit via scaled_time_limit().
const MB_TIME_S = Dict(
    (50,  2) => 120,
    (50,  3) => 300,
    (75,  2) => 240,
    (75,  3) => 600,
    (100, 2) => 480,
    (100, 3) => 1200,
)

# ── load CSV ──────────────────────────────────────────────────────────────────
function load_csv(path::String)
    # Returns:
    #   results  : Dict (inst_name, method) => Vector{Float64} of objectives
    #   times    : Dict (inst_name, method) => Vector{Float64} of wall-clock times
    #   pce_data : Dict (inst_name, method) => Vector{Float64} of per-run PCE values
    results  = Dict{Tuple{String,String}, Vector{Float64}}()
    times    = Dict{Tuple{String,String}, Vector{Float64}}()
    pce_data = Dict{Tuple{String,String}, Vector{Float64}}()
    isfile(path) || error("CSV not found: $path")
    for line in eachline(path)
        (startswith(line, "instance") || contains(line, ",method,")) && continue
        parts = split(line, ",")
        length(parts) >= 4 || continue
        inst = strip(parts[1])
        meth = strip(parts[2])
        obj  = parse(Float64, strip(parts[4]))
        key  = (inst, meth)
        push!(get!(results, key, Float64[]), obj)
        # wall-clock time (column 5, optional)
        if length(parts) >= 5
            t = tryparse(Float64, strip(parts[5]))
            isnothing(t) || push!(get!(times, key, Float64[]), t)
        end
        # PCE columns (optional — old CSVs have only 5 columns)
        if length(parts) >= 7
            n_calls    = parse(Int, strip(parts[6]))
            n_feasible = parse(Int, strip(parts[7]))
            pce = n_calls > 0 ? n_feasible / n_calls : NaN
            push!(get!(pce_data, key, Float64[]), pce)
        end
    end
    return results, times, pce_data
end

# ── gap helper ────────────────────────────────────────────────────────────────
gap_pct(val, baseline) = (val - baseline) / baseline * 100.0

# ── format helpers ────────────────────────────────────────────────────────────
fmt2(x) = isnan(x) ? "--" : @sprintf("%.2f", x)
fmt1(x) = isnan(x) ? "--" : @sprintf("%.2f", x)

# ── write results_summary.tex ─────────────────────────────────────────────────
# Column order: M&B V4 | 3L-PDP (Avg, ΔV4) | 3L-PDP-D (Avg, ΔV4) | 3L-PDP-S (Avg, ΔV4)
function write_summary(results, density, ss, times, out_path)
    sizes   = [50, 75, 100]
    layouts = ["RAND", "CLUS", "CPCD"]
    boxes   = [2, 3]

    all_v4_avg   = Float64[]
    all_pdp_avg  = Float64[]
    all_pdp_dv4  = Float64[]
    all_dpd_avg  = Float64[]
    all_dpd_dv4  = Float64[]
    all_ss_avg   = Float64[]
    all_ss_dv4   = Float64[]

    fmt_time(s) = s >= 60 ? @sprintf("%d\\,min", round(Int, s/60)) :
                            @sprintf("%d\\,s",   round(Int, s))

    open(out_path, "w") do io
        println(io, raw"% Auto-generated by gen_tables.jl — do not edit manually.")
        println(io, raw"{\footnotesize\renewcommand{\arraystretch}{0.85}\setlength{\tabcolsep}{3pt}%")
        println(io, raw"\begin{tabular}{@{}llc r r rr rr rr@{}}")
        println(io, raw"\toprule")
        println(io, raw"\multirow{2}{*}{Size} & \multirow{2}{*}{Class} & \multirow{2}{*}{$|\mathcal{I}|$}")
        println(io, raw"  & \multirow{2}{*}{Time} & \multirow{2}{*}{M\&B~V4}")
        println(io, raw"  & \multicolumn{2}{c}{3L-PDP} & \multicolumn{2}{c}{3L-PDP-D} & \multicolumn{2}{c}{3L-PDP-S} \\\\")
        println(io, raw"\cmidrule(lr){6-7}\cmidrule(lr){8-9}\cmidrule(lr){10-11}")
        println(io, raw" & & & & & Avg & $\Delta$V4 & Avg & $\Delta$V4 & Avg & $\Delta$V4 \\\\")
        println(io, raw"\midrule")

        for size in sizes
            n_inst_size = size == 50 ? 5 : (size == 75 ? 3 : 1)
            first_row_size = true

            for layout in layouts
                for box in boxes
                    n_inst    = n_inst_size
                    mb_time_s = MB_TIME_S[(size, box)]

                    v4_vals  = Float64[]
                    pdp_avgs = Float64[]
                    dpd_avgs = Float64[]
                    ss_avgs  = Float64[]

                    for idx in 1:n_inst
                        k = @sprintf("%03d_%s_%d_%d", size, layout, box, idx)
                        haskey(MB2018_V4, k)          && push!(v4_vals,  MB2018_V4[k])
                        haskey(results, (k, "brkga")) && push!(pdp_avgs, mean(results[(k, "brkga")]))
                        haskey(density, (k, "brkga")) && push!(dpd_avgs, mean(density[(k, "brkga")]))
                        haskey(ss,      (k, "brkga")) && push!(ss_avgs,  mean(ss[(k, "brkga")]))
                    end

                    v4_avg  = isempty(v4_vals)  ? NaN : mean(v4_vals)
                    pdp_avg = isempty(pdp_avgs) ? NaN : mean(pdp_avgs)
                    dpd_avg = isempty(dpd_avgs) ? NaN : mean(dpd_avgs)
                    ss_avg  = isempty(ss_avgs)  ? NaN : mean(ss_avgs)
                    pdp_dv4 = (isnan(pdp_avg) || isnan(v4_avg)) ? NaN : gap_pct(pdp_avg, v4_avg)
                    dpd_dv4 = (isnan(dpd_avg) || isnan(v4_avg)) ? NaN : gap_pct(dpd_avg, v4_avg)
                    ss_dv4  = (isnan(ss_avg)  || isnan(v4_avg)) ? NaN : gap_pct(ss_avg,  v4_avg)

                    isnan(v4_avg)  || push!(all_v4_avg,  v4_avg)
                    isnan(pdp_avg) || push!(all_pdp_avg, pdp_avg)
                    isnan(pdp_dv4) || push!(all_pdp_dv4, pdp_dv4)
                    isnan(dpd_avg) || push!(all_dpd_avg, dpd_avg)
                    isnan(dpd_dv4) || push!(all_dpd_dv4, dpd_dv4)
                    isnan(ss_avg)  || push!(all_ss_avg,  ss_avg)
                    isnan(ss_dv4)  || push!(all_ss_dv4,  ss_dv4)

                    size_str = first_row_size ? "\\multirow{6}{*}{$size}" : ""
                    first_row_size = false

                    # Bold the overall minimum of {V4, 3L-PDP, 3L-PDP-D, 3L-PDP-S}
                    cands = filter(!isnan, [v4_avg, pdp_avg, dpd_avg, ss_avg])
                    row_min = isempty(cands) ? NaN : minimum(cands)
                    near_row_min(x) = !isnan(row_min) && abs(x - row_min) < 1e-9
                    fs(x) = isnan(x) ? "--" : (near_row_min(x) ? "\$\\mathbf{$(@sprintf("%.2f",x))}\$" : @sprintf("%.2f",x))
                    fg(x) = isnan(x) ? "--" : @sprintf("%.2f", x)

                    @printf(io,
                        "  %s & %s, %d box & %d & %s & %s & %s & %s & %s & %s & %s & %s \\\\\n",
                        size_str, layout, box, n_inst,
                        fmt_time(mb_time_s),
                        fs(v4_avg),
                        fs(pdp_avg), fg(pdp_dv4),
                        fs(dpd_avg), fg(dpd_dv4),
                        fs(ss_avg),  fg(ss_dv4))
                end
            end
            println(io, raw"\midrule")
        end

        # Compute averages from accumulated vectors, then derive ΔV4 from those
        # averages — not as mean of per-class percentages — so the table is
        # internally consistent (displayed avg and ΔV4 agree arithmetically).
        gav4  = isempty(all_v4_avg)  ? NaN : mean(all_v4_avg)
        gapdp = isempty(all_pdp_avg) ? NaN : mean(all_pdp_avg)
        gadpd = isempty(all_dpd_avg) ? NaN : mean(all_dpd_avg)
        gass  = isempty(all_ss_avg)  ? NaN : mean(all_ss_avg)
        gdv4_pdp = (isnan(gapdp) || isnan(gav4)) ? NaN : gap_pct(gapdp, gav4)
        gdv4_dpd = (isnan(gadpd) || isnan(gav4)) ? NaN : gap_pct(gadpd, gav4)
        gdv4_ss  = (isnan(gass)  || isnan(gav4)) ? NaN : gap_pct(gass,  gav4)

        # Bold the minimum of the four averages
        gcands  = filter(!isnan, [gav4, gapdp, gadpd, gass])
        gmin    = isempty(gcands) ? NaN : minimum(gcands)
        fgb(x)  = isnan(x) ? "--" : (abs(x - gmin) < 1e-9 ? "\$\\mathbf{$(@sprintf("%.2f",x))}\$" : @sprintf("%.2f",x))
        fgap(x) = isnan(x) ? "--" : @sprintf("%.2f", x)

        @printf(io,
            "\\textbf{Avg} & & \\textbf{54} & & %s & %s & %s & %s & %s & %s & %s \\\\\n",
            fgb(gav4),
            fgb(gapdp), fgap(gdv4_pdp),
            fgb(gadpd), fgap(gdv4_dpd),
            fgb(gass),  fgap(gdv4_ss))
        println(io, raw"\bottomrule")
        println(io, raw"\end{tabular}}")
    end
    println("  Written: $out_path")
end

# ── write results_detailed.tex ────────────────────────────────────────────────
# Column order: Instance | M&B V4 | 3L-PDP (Avg, ΔV4) | 3L-PDP-D (Avg, ΔV4) | 3L-PDP-S (Avg, ΔV4)
function write_detailed(results, density, ss, out_path)
    sizes   = [50, 75, 100]
    layouts = ["RAND", "CLUS", "CPCD"]
    boxes   = [2, 3]

    all_v4_avg  = Float64[]
    all_pdp_avg = Float64[]
    all_pdp_dv4 = Float64[]
    all_dpd_avg = Float64[]
    all_dpd_dv4 = Float64[]
    all_ss_avg  = Float64[]
    all_ss_dv4  = Float64[]

    hdr1 = " & & \\multicolumn{2}{c}{3L-PDP} & \\multicolumn{2}{c}{3L-PDP-D} & \\multicolumn{2}{c}{3L-PDP-S} \\\\"
    hdr2 = raw"\cmidrule(lr){3-4}\cmidrule(lr){5-6}\cmidrule(lr){7-8}"
    hdr3 = " Instance & M\\&B~V4 & Avg & \$\\Delta\$V4 & Avg & \$\\Delta\$V4 & Avg & \$\\Delta\$V4 \\\\"

    open(out_path, "w") do io
        println(io, raw"% Auto-generated by gen_tables.jl — do not edit manually.")
        println(io, raw"{\footnotesize\setlength{\tabcolsep}{3pt}%")
        println(io, raw"\begin{longtable}{@{}l r rr rr rr@{}}")
        println(io, raw"\caption{Per-instance results (avg over 5 seeds). $\Delta$V4 = gap vs.\ M\&B (2018) V4 (\%; negative means better than V4). 3L-PDP-D adds density stacking constraint (PC5); 3L-PDP-S adds structural stacking constraint (PC6) via BCT.}")
        println(io, "\\label{tab:results_detailed}\\\\")
        println(io, raw"\toprule")
        println(io, hdr1); println(io, hdr2); println(io, hdr3)
        println(io, raw"\midrule\endfirsthead")
        println(io, "\\toprule"); println(io, hdr1); println(io, hdr2)
        println(io, hdr3 * raw"\midrule\endhead")
        println(io, raw"\midrule\multicolumn{8}{r}{\footnotesize(continued)}\endfoot")
        println(io, raw"\bottomrule\endlastfoot")

        for size in sizes
            n_inst_size = size == 50 ? 5 : (size == 75 ? 3 : 1)
            for layout in layouts
                for box in boxes
                    for idx in 1:n_inst_size
                        inst_name = @sprintf("%03d_%s_%d_%d", size, layout, box, idx)
                        v4_v      = get(MB2018_V4, inst_name, NaN)
                        pdp_vals  = get(results, (inst_name, "brkga"), Float64[])
                        dpd_vals  = get(density, (inst_name, "brkga"), Float64[])
                        ss_vals   = get(ss,      (inst_name, "brkga"), Float64[])

                        pdp_avg = isempty(pdp_vals) ? NaN : mean(pdp_vals)
                        dpd_avg = isempty(dpd_vals) ? NaN : mean(dpd_vals)
                        ss_avg  = isempty(ss_vals)  ? NaN : mean(ss_vals)
                        pdp_dv4 = (isnan(pdp_avg) || isnan(v4_v)) ? NaN : gap_pct(pdp_avg, v4_v)
                        dpd_dv4 = (isnan(dpd_avg) || isnan(v4_v)) ? NaN : gap_pct(dpd_avg, v4_v)
                        ss_dv4  = (isnan(ss_avg)  || isnan(v4_v)) ? NaN : gap_pct(ss_avg,  v4_v)

                        isnan(v4_v)    || push!(all_v4_avg,  v4_v)
                        isnan(pdp_avg) || push!(all_pdp_avg, pdp_avg)
                        isnan(pdp_dv4) || push!(all_pdp_dv4, pdp_dv4)
                        isnan(dpd_avg) || push!(all_dpd_avg, dpd_avg)
                        isnan(dpd_dv4) || push!(all_dpd_dv4, dpd_dv4)
                        isnan(ss_avg)  || push!(all_ss_avg,  ss_avg)
                        isnan(ss_dv4)  || push!(all_ss_dv4,  ss_dv4)

                        # Bold the overall minimum of {V4, 3L-PDP, 3L-PDP-D, 3L-PDP-S}
                        candidates = filter(!isnan, [v4_v, pdp_avg, dpd_avg, ss_avg])
                        min_avg = isempty(candidates) ? NaN : minimum(candidates)
                        near_min(x) = !isnan(min_avg) && abs(x - min_avg) < 1e-9

                        f(x)  = @sprintf("%.2f", x)
                        fb(x) = "\$\\mathbf{$(@sprintf("%.2f", x))}\$"
                        fg(x) = @sprintf("%+.2f", x)

                        v4_s   = isnan(v4_v)    ? "--" : (near_min(v4_v)    ? fb(v4_v)    : f(v4_v))
                        pdp_s  = isnan(pdp_avg) ? "--" : (near_min(pdp_avg) ? fb(pdp_avg) : f(pdp_avg))
                        dpd_s  = isnan(dpd_avg) ? "--" : (near_min(dpd_avg) ? fb(dpd_avg) : f(dpd_avg))
                        ss_s   = isnan(ss_avg)  ? "--" : (near_min(ss_avg)  ? fb(ss_avg)  : f(ss_avg))
                        pdv4_s = isnan(pdp_dv4) ? "--" : fg(pdp_dv4)
                        ddv4_s = isnan(dpd_dv4) ? "--" : fg(dpd_dv4)
                        sdv4_s = isnan(ss_dv4)  ? "--" : fg(ss_dv4)

                        @printf(io, "%s & %s & %s & %s & %s & %s & %s & %s \\\\\n",
                                replace(inst_name, "_" => "\\_"),
                                v4_s, pdp_s, pdv4_s, dpd_s, ddv4_s, ss_s, sdv4_s)
                    end
                    println(io, raw"\midrule")
                end
            end
        end

        fmtavg(v)  = isempty(v) ? "--" : @sprintf("%.2f", mean(v))
        fmtavgg(v) = isempty(v) ? "--" : @sprintf("%+.2f", mean(v))

        avg_v4  = isempty(all_v4_avg)  ? NaN : mean(all_v4_avg)
        avg_pdp = isempty(all_pdp_avg) ? NaN : mean(all_pdp_avg)
        avg_dpd = isempty(all_dpd_avg) ? NaN : mean(all_dpd_avg)
        avg_ss  = isempty(all_ss_avg)  ? NaN : mean(all_ss_avg)
        avg_min = minimum(filter(!isnan, [avg_v4, avg_pdp, avg_dpd, avg_ss]))
        fbavg(x) = isnan(x) ? "--" : (abs(x - avg_min) < 1e-9 ? "\$\\mathbf{$(@sprintf("%.2f",x))}\$" : @sprintf("%.2f",x))

        @printf(io, "\\textbf{Average} & %s & %s & %s & %s & %s & %s & %s \\\\\n",
                fbavg(avg_v4),
                fbavg(avg_pdp), fmtavgg(all_pdp_dv4),
                fbavg(avg_dpd), fmtavgg(all_dpd_dv4),
                fbavg(avg_ss),  fmtavgg(all_ss_dv4))

        println(io, raw"\end{longtable}}")
    end
    println("  Written: $out_path")
end

# ── write results_hetero.tex ──────────────────────────────────────────────────
# Compares 3L-PDP-H, 3L-PDP-D, and 3L-PDP-C on the synthetic heterogeneous
# instances (3L_PDP_instances_hetero/).  No M&B V4 reference exists for these
# instances; the gap (ΔBase) is relative to the 3L-PDP-H baseline.
# The Win D/C column counts how many instances within the class are won by
# PC5 (D) vs PC7 (C), the key metric showing divergence from the near-tie
# observed on the M&B benchmark.
function write_hetero_summary(base, density, ss, out_path)
    sizes   = [50, 75, 100]
    layouts = ["RAND", "CLUS", "CPCD"]
    boxes   = [2, 3]
    n_h     = 5    # H-seed variants per base instance

    all_base_avg = Float64[]
    all_dpd_avg  = Float64[]
    all_ss_avg   = Float64[]
    all_dpd_db   = Float64[]
    all_ss_db    = Float64[]
    total_wins_d = 0
    total_wins_s = 0

    open(out_path, "w") do io
        println(io, "% Auto-generated by gen_tables.jl — do not edit manually.")
        println(io, raw"{\footnotesize\renewcommand{\arraystretch}{0.85}\setlength{\tabcolsep}{3pt}%")
        println(io, raw"\begin{tabular}{@{}llc r rr rr c@{}}")
        println(io, raw"\toprule")
        println(io, raw"\multirow{2}{*}{$n$} & \multirow{2}{*}{Class}")
        println(io, raw"  & \multirow{2}{*}{$|\mathcal{H}|$}")
        println(io, raw"  & \multirow{2}{*}{3L-PDP-H}")
        println(io, raw"  & \multicolumn{2}{c}{3L-PDP-D} & \multicolumn{2}{c}{3L-PDP-C}")
        println(io, raw"  & Win \\\\")
        println(io, raw"\cmidrule(lr){5-6}\cmidrule(lr){7-8}")
        println(io, raw" & & & & Avg & $\Delta$Base & Avg & $\Delta$Base & D\,/\,C \\\\")
        println(io, raw"\midrule")

        for size in sizes
            n_inst_size = size == 50 ? 5 : (size == 75 ? 3 : 1)
            first_size  = true

            for layout in layouts
                for box in boxes
                    n_total_h = n_inst_size * n_h

                    base_avgs = Float64[]
                    dpd_avgs  = Float64[]
                    ss_avgs   = Float64[]
                    d_wins = 0; s_wins = 0

                    for idx in 1:n_inst_size
                        for h in 1:n_h
                            k   = @sprintf("%03d_%s_%d_%d_H%d", size, layout, box, idx, h)
                            b_v = haskey(base,    (k, "brkga")) ? mean(base[(k,    "brkga")]) : NaN
                            d_v = haskey(density, (k, "brkga")) ? mean(density[(k, "brkga")]) : NaN
                            s_v = haskey(ss,      (k, "brkga")) ? mean(ss[(k,     "brkga")]) : NaN
                            isnan(b_v) || push!(base_avgs, b_v)
                            isnan(d_v) || push!(dpd_avgs,  d_v)
                            isnan(s_v) || push!(ss_avgs,   s_v)
                            if !isnan(d_v) && !isnan(s_v)
                                d_v < s_v && (d_wins += 1)
                                d_v > s_v && (s_wins += 1)
                            end
                        end
                    end

                    base_avg = isempty(base_avgs) ? NaN : mean(base_avgs)
                    dpd_avg  = isempty(dpd_avgs)  ? NaN : mean(dpd_avgs)
                    ss_avg   = isempty(ss_avgs)   ? NaN : mean(ss_avgs)
                    dpd_db   = (isnan(dpd_avg) || isnan(base_avg)) ? NaN : gap_pct(dpd_avg, base_avg)
                    ss_db    = (isnan(ss_avg)  || isnan(base_avg)) ? NaN : gap_pct(ss_avg,  base_avg)

                    isnan(base_avg) || push!(all_base_avg, base_avg)
                    isnan(dpd_avg)  || push!(all_dpd_avg,  dpd_avg)
                    isnan(ss_avg)   || push!(all_ss_avg,   ss_avg)
                    isnan(dpd_db)   || push!(all_dpd_db,   dpd_db)
                    isnan(ss_db)    || push!(all_ss_db,    ss_db)
                    total_wins_d += d_wins
                    total_wins_s += s_wins

                    size_str   = first_size ? "\\multirow{6}{*}{$size}" : ""
                    first_size = false

                    win_str = (d_wins == 0 && s_wins == 0) ? "--" :
                               "$d_wins\\,/\\,$s_wins"

                    @printf(io,
                        "  %s & %s, %d box & %d & %s & %s & %s & %s & %s & %s \\\\\n",
                        size_str, layout, box, n_total_h,
                        fmt2(base_avg),
                        fmt2(dpd_avg), isnan(dpd_db) ? "--" : @sprintf("%+.2f", dpd_db),
                        fmt2(ss_avg),  isnan(ss_db)  ? "--" : @sprintf("%+.2f", ss_db),
                        win_str)
                end
            end
            println(io, raw"\midrule")
        end

        fmtavg(v)   = isempty(v) ? "--" : @sprintf("%.2f", mean(v))
        fmtdelta(v) = isempty(v) ? "--" : @sprintf("%+.2f", mean(v))
        n_tot = sum(size == 50 ? 5 : (size == 75 ? 3 : 1) for size in sizes) * 3 * 2 * n_h

        @printf(io,
            "\\textbf{Avg} & & \\textbf{%d} & %s & %s & %s & %s & %s & %s\\,/\\,%s \\\\\n",
            n_tot,
            fmtavg(all_base_avg),
            fmtavg(all_dpd_avg),  fmtdelta(all_dpd_db),
            fmtavg(all_ss_avg),   fmtdelta(all_ss_db),
            total_wins_d, total_wins_s)
        println(io, raw"\bottomrule")
        println(io, raw"\end{tabular}}")
    end
    println("  Written: $out_path")
end

# ── write density_comparison.tex ──────────────────────────────────────────────
# Column order: Size | Class | |I| | M&B V4 | BRKGA | BRKGA-D | ΔDensity
# Compares baseline BRKGA (results.csv) vs BRKGA with density constraint (results_density.csv).
function write_density_comparison(baseline, density, out_path)
    sizes   = [50, 75, 100]
    layouts = ["RAND", "CLUS", "CPCD"]
    boxes   = [2, 3]

    all_v4_avg   = Float64[]
    all_base_avg = Float64[]
    all_dens_avg = Float64[]
    all_delta    = Float64[]

    open(out_path, "w") do io
        println(io, raw"% Auto-generated by gen_tables.jl — do not edit manually.")
        println(io, raw"{\footnotesize\renewcommand{\arraystretch}{0.85}\setlength{\tabcolsep}{3pt}%")
        println(io, raw"\begin{tabular}{@{}llc r r r r@{}}")
        println(io, raw"\toprule")
        println(io, raw"Size & Class & $|\mathcal{I}|$ & M\&B~V4 & 3L-PDP & 3L-PDP-D & $\Delta$D \\\\")
        println(io, raw"\midrule")

        for size in sizes
            n_inst_size = size == 50 ? 5 : (size == 75 ? 3 : 1)
            first_row_size = true

            for layout in layouts
                for box in boxes
                    n_inst = n_inst_size

                    v4_vals   = Float64[]
                    base_avgs = Float64[]
                    dens_avgs = Float64[]

                    for idx in 1:n_inst
                        k = @sprintf("%03d_%s_%d_%d", size, layout, box, idx)
                        haskey(MB2018_V4, k)            && push!(v4_vals,   MB2018_V4[k])
                        haskey(baseline, (k, "brkga"))  && push!(base_avgs, mean(baseline[(k, "brkga")]))
                        haskey(density,  (k, "brkga"))  && push!(dens_avgs, mean(density[(k,  "brkga")]))
                    end

                    v4_avg   = isempty(v4_vals)   ? NaN : mean(v4_vals)
                    base_avg = isempty(base_avgs) ? NaN : mean(base_avgs)
                    dens_avg = isempty(dens_avgs) ? NaN : mean(dens_avgs)
                    delta    = (isnan(dens_avg) || isnan(base_avg)) ? NaN : gap_pct(dens_avg, base_avg)

                    isnan(v4_avg)   || push!(all_v4_avg,   v4_avg)
                    isnan(base_avg) || push!(all_base_avg, base_avg)
                    isnan(dens_avg) || push!(all_dens_avg, dens_avg)
                    isnan(delta)    || push!(all_delta,    delta)

                    size_str = first_row_size ? "\\multirow{6}{*}{$size}" : ""
                    first_row_size = false

                    @printf(io,
                        "  %s & %s, %d box & %d & %s & %s & %s & %s \\\\\n",
                        size_str, layout, box, n_inst,
                        fmt2(v4_avg), fmt2(base_avg), fmt2(dens_avg),
                        isnan(delta) ? "--" : @sprintf("%+.2f", delta))
                end
            end
            println(io, raw"\midrule")
        end

        fmtavg(v)  = isempty(v) ? "--" : @sprintf("%.2f", mean(v))
        fmtdelta(v) = isempty(v) ? "--" : @sprintf("%+.2f", mean(v))
        @printf(io,
            "\\textbf{Avg} & & \\textbf{54} & %s & %s & %s & %s \\\\\n",
            fmtavg(all_v4_avg), fmtavg(all_base_avg),
            fmtavg(all_dens_avg), fmtdelta(all_delta))
        println(io, raw"\bottomrule")
        println(io, raw"\end{tabular}}")
    end
    println("  Written: $out_path")
end

# ── entry point ────────────────────────────────────────────────────────────────
function main()
    results_dir  = joinpath(@__DIR__, "..", "results")
    summary_out  = joinpath(@__DIR__, "..", "latex", "tables", "results_summary.tex")
    detailed_out = joinpath(@__DIR__, "..", "latex", "tables", "results_detailed.tex")
    density_out  = joinpath(@__DIR__, "..", "latex", "tables", "density_comparison.tex")
    hetero_out   = joinpath(@__DIR__, "..", "latex", "tables", "results_hetero.tex")

    csv_files = [
        joinpath(results_dir, "results.csv"),            # BRKGA benchmark (54 instances × 5 seeds)
        joinpath(results_dir, "results_alns_greedy.csv"), # ALNS benchmark (54 instances × 5 seeds)
    ]
    results  = Dict{Tuple{String,String}, Vector{Float64}}()
    times    = Dict{Tuple{String,String}, Vector{Float64}}()
    pce_data = Dict{Tuple{String,String}, Vector{Float64}}()
    for csv_path in csv_files
        isfile(csv_path) || continue
        println("Loading results from $csv_path ...")
        partial_res, partial_times, partial_pce = load_csv(csv_path)
        for (k, v) in partial_res;   append!(get!(results,  k, Float64[]), v); end
        for (k, v) in partial_times; append!(get!(times,    k, Float64[]), v); end
        for (k, v) in partial_pce;   append!(get!(pce_data, k, Float64[]), v); end
    end
    n_runs  = sum(length(v) for v in values(results))
    n_pce   = isempty(pce_data) ? 0 : sum(length(v) for v in values(pce_data))
    println("  $n_runs run records loaded ($(length(results)) unique (instance,method) pairs)")
    println("  $n_pce runs with PCE data")
    println()

    # Load density results (optional)
    density_csv = joinpath(results_dir, "results_density.csv")
    dens_res = Dict{Tuple{String,String}, Vector{Float64}}()
    if isfile(density_csv)
        println("Loading density results from $density_csv ...")
        dens_res, _, _ = load_csv(density_csv)
        println("  $(sum(length(v) for v in values(dens_res))) density run records")
    else
        println("  Note: results_density.csv not found — 3L-PDP-D columns will be empty")
    end
    println()

    # Load structural stacking (SS) results (optional)
    ss_csv = joinpath(results_dir, "results_ss.csv")
    ss_res = Dict{Tuple{String,String}, Vector{Float64}}()
    if isfile(ss_csv)
        println("Loading SS results from $ss_csv ...")
        ss_res, _, _ = load_csv(ss_csv)
        println("  $(sum(length(v) for v in values(ss_res))) SS run records")
    else
        println("  Note: results_ss.csv not found — 3L-PDP-S columns will be empty")
    end
    println()

    # Load heterogeneous-instance results (optional)
    hetero_csv   = joinpath(results_dir, "results_hetero.csv")
    hetero_d_csv = joinpath(results_dir, "results_hetero_density.csv")
    hetero_s_csv = joinpath(results_dir, "results_hetero_ss.csv")

    hetero_base = Dict{Tuple{String,String}, Vector{Float64}}()
    hetero_dens = Dict{Tuple{String,String}, Vector{Float64}}()
    hetero_ss   = Dict{Tuple{String,String}, Vector{Float64}}()

    if isfile(hetero_csv)
        println("Loading hetero baseline from $hetero_csv ...")
        hetero_base, _, _ = load_csv(hetero_csv)
        println("  $(sum(length(v) for v in values(hetero_base))) hetero baseline run records")
    end
    if isfile(hetero_d_csv)
        println("Loading hetero density from $hetero_d_csv ...")
        hetero_dens, _, _ = load_csv(hetero_d_csv)
        println("  $(sum(length(v) for v in values(hetero_dens))) hetero density run records")
    end
    if isfile(hetero_s_csv)
        println("Loading hetero SS from $hetero_s_csv ...")
        hetero_ss, _, _ = load_csv(hetero_s_csv)
        println("  $(sum(length(v) for v in values(hetero_ss))) hetero SS run records")
    end
    println()

    println("Generating main tables ...")
    write_summary(results, dens_res, ss_res, times, summary_out)
    write_detailed(results, dens_res, ss_res, detailed_out)
    # write_density_comparison(results, dens_res, density_out)  # table removed from §5.8

    if isfile(hetero_csv) || isfile(hetero_d_csv) || isfile(hetero_s_csv)
        println("Generating hetero table ...")
        write_hetero_summary(hetero_base, hetero_dens, hetero_ss, hetero_out)
    else
        println("  Note: no hetero results found — skipping results_hetero.tex")
    end

    println("\nDone.")
end

main()
