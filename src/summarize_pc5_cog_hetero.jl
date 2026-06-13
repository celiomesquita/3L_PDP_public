using Printf
using Statistics
const CSV = joinpath(@__DIR__, "..", "results", "comparison_pc5_cog_hetero.csv")
rows = Tuple{String,String,Float64,Int,Int}[]
for line in eachline(CSV)
    startswith(line, "instance") && continue
    p = split(line, ",")
    push!(rows, (strip(p[1]), strip(p[3]), parse(Float64, p[4]), parse(Int, p[6]), parse(Int, p[7])))
end
@printf("Loaded %d rows\n\n", length(rows))
for o in ("3csp_pc5", "3csp_cog")
    sub = [r for r in rows if r[2] == o]
    @printf("%-10s  mean_TTD=%.2f  mean_calls=%.0f  mean_pce=%.4f\n",
            o, mean(r -> r[3], sub), mean(r -> r[4], sub),
            mean(r -> r[5] / r[4], sub))
end
pairs = Dict{String, Tuple{Float64, Float64}}()
for (inst, o, obj, _, _) in rows
    s, c = get(pairs, inst, (0.0, 0.0))
    o == "3csp_pc5" ? (pairs[inst] = (obj, c)) : (pairs[inst] = (s, obj))
end
deltas = [100 * (c - s) / s for (_, (s, c)) in pairs if s > 0 && c > 0]
println()
@printf("Paired n=%d: PC5 better %d  CoG better %d  ties %d  mean_delta%%=%.3f\n",
        length(deltas), count(>(0), deltas), count(<(0), deltas), count(==(0), deltas), mean(deltas))
