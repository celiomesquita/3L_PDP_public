# Summarize memetic oracle panel results from results/memetic_oracle_panel.csv
#
# Usage: julia --project=. src/gen_memetic_oracle_panel_table.jl
#
# Output: results/tables/memetic_oracle_panel_summary.csv

using Printf
using Statistics

const CSV_PATH = joinpath(@__DIR__, "..", "results", "memetic_oracle_panel.csv")
const OUT_PATH = joinpath(@__DIR__, "..", "results", "tables", "memetic_oracle_panel_summary.csv")

function load_panel(path::String)
    data = Dict{Tuple{String,String}, Vector{Float64}}()
    isfile(path) || return Dict{Tuple{String,String}, Float64}()
    for line in eachline(path)
        startswith(line, "instance,") && continue
        isempty(strip(line)) && continue
        p = split(line, ",")
        length(p) >= 6 || continue
        inst, oracle = strip(p[1]), strip(p[2])
        feasible = lowercase(strip(p[6])) == "true"
        feasible || continue
        ttd = tryparse(Float64, strip(p[5]))
        isnothing(ttd) && continue
        push!(get!(data, (inst, oracle), Float64[]), ttd)
    end
    return Dict(k => mean(v) for (k, v) in data)
end

function main()
    raw = load_panel(CSV_PATH)
    isempty(raw) && error("No feasible rows in $CSV_PATH")

    oracles = ("1csp", "2csp", "3csp")
    insts   = sort(unique(k[1] for k in keys(raw)))
    mkpath(dirname(OUT_PATH))

    open(OUT_PATH, "w") do io
        println(io, "instance,mean_ttd_1csp,mean_ttd_2csp,mean_ttd_3csp")
        for inst in insts
            vals = [get(raw, (inst, o), NaN) for o in oracles]
            @printf(io, "%s,%.4f,%.4f,%.4f\n", inst, vals...)
        end
        means = [mean([get(raw, (inst, o), NaN) for inst in insts if haskey(raw, (inst, o))]) for o in oracles]
        @printf(io, "MEAN,%.4f,%.4f,%.4f\n", means...)
    end
    @printf("Written %s (%d instances)\n", OUT_PATH, length(insts))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
