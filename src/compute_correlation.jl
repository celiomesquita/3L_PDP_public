using Statistics, Printf

# ── M&B (2018) V4 per-instance reference values ───────────────────────────────
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
    "100_RAND_2_1" => 3991.39, "100_CLUS_2_1" => 4130.58, "100_CPCD_2_1" => 4272.27,
    "100_RAND_3_1" => 4044.72, "100_CLUS_3_1" => 4149.49, "100_CPCD_3_1" => 4320.01,
)

# ── load CSV averaging over multiple seeds per instance ───────────────────────
# Used for M&B benchmark CSVs (5 seeds per instance).
function load_csv_avg(path)
    acc = Dict{String, Vector{Float64}}()
    open(path) do f
        header = split(replace(replace(readline(f), "﻿" => ""), "\r" => ""), ",")
        icol = findfirst(==("instance"), header)
        ocol = findfirst(==("obj"),      header)
        for line in eachline(f)
            line = replace(line, "\r" => "")
            isempty(line) && continue
            parts = split(line, ",")
            inst = strip(parts[icol])
            obj  = parse(Float64, strip(parts[ocol]))
            push!(get!(acc, inst, Float64[]), obj)
        end
    end
    return Dict(k => mean(v) for (k, v) in acc)
end

# ── load CSV single value per instance ───────────────────────────────────────
# Used for heterogeneous benchmark CSVs (1 seed per instance).
function load_csv_single(path)
    rows = Dict{String, Float64}()
    open(path) do f
        header = split(replace(replace(readline(f), "﻿" => ""), "\r" => ""), ",")
        icol = findfirst(==("instance"), header)
        ocol = findfirst(==("obj"),      header)
        for line in eachline(f)
            line = replace(line, "\r" => "")
            isempty(line) && continue
            parts = split(line, ",")
            rows[strip(parts[icol])] = parse(Float64, strip(parts[ocol]))
        end
    end
    return rows
end

# ══════════════════════════════════════════════════════════════════════════════
# TABLE I — M&B 54-instance benchmark (avg over 5 seeds)
# PC5 = 3L-PDP-D (density stacking); PC6 = 3L-PDP-S (structural BCT / McKee)
# ══════════════════════════════════════════════════════════════════════════════
println("=" ^ 60)
println("TABLE I: M&B 54-instance benchmark (avg over 5 seeds)")
println("=" ^ 60)

base_mb = load_csv_avg("results/results.csv")
dens_mb = load_csv_avg("results/results_density.csv")
ss_mb   = load_csv_avg("results/results_ss.csv")

common_mb = sort(filter(i -> haskey(dens_mb, i) && haskey(ss_mb, i) && haskey(MB2018_V4, i),
                        collect(keys(base_mb))))

ttd_d_mb    = [dens_mb[i]    for i in common_mb]
ttd_s_mb    = [ss_mb[i]      for i in common_mb]
gap_base_d  = [100*(dens_mb[i] - base_mb[i]) / base_mb[i] for i in common_mb]
gap_base_s  = [100*(ss_mb[i]   - base_mb[i]) / base_mb[i] for i in common_mb]
gap_v4_d    = [100*(dens_mb[i] - MB2018_V4[i]) / MB2018_V4[i] for i in common_mb]
gap_v4_s    = [100*(ss_mb[i]   - MB2018_V4[i]) / MB2018_V4[i] for i in common_mb]

@printf("Instances              : %d\n",   length(common_mb))
@printf("TTD  correlation       : r = %.4f\n", cor(ttd_d_mb,   ttd_s_mb))
@printf("ΔBase gap correlation  : r = %.4f  (baseline = unconstrained BRKGA)\n",
        cor(gap_base_d, gap_base_s))
@printf("ΔV4  gap correlation   : r = %.4f  (baseline = M&B V4)\n",
        cor(gap_v4_d,   gap_v4_s))

# ══════════════════════════════════════════════════════════════════════════════
# TABLE V — 270 heterogeneous instances (1 seed per instance)
# PC5 = 3L-PDP-D (density stacking); PC6 = 3L-PDP-S (structural BCT + Twede & Selke)
# ══════════════════════════════════════════════════════════════════════════════
println()
println("=" ^ 60)
println("TABLE V: 270 heterogeneous instances (1 seed per instance)")
println("=" ^ 60)

base_h = load_csv_single("results/results_hetero.csv")
dens_h = load_csv_single("results/results_hetero_density.csv")
ss_h   = load_csv_single("results/results_hetero_ss.csv")

common_h = sort(filter(i -> haskey(dens_h, i) && haskey(ss_h, i),
                       collect(keys(base_h))))

gap_d_h = [100*(dens_h[i] - base_h[i]) / base_h[i] for i in common_h]
gap_s_h = [100*(ss_h[i]   - base_h[i]) / base_h[i] for i in common_h]
ttd_d_h = [dens_h[i] for i in common_h]
ttd_s_h = [ss_h[i]   for i in common_h]

@printf("Instances              : %d\n",   length(common_h))
@printf("ΔBase gap correlation  : r = %.4f  (baseline = unconstrained 3L-PDP-H)\n",
        cor(gap_d_h, gap_s_h))
@printf("TTD  correlation       : r = %.4f\n", cor(ttd_d_h, ttd_s_h))
