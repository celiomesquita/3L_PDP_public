using Printf

data = Dict()
for reset in [3, 2]
    d = "C:/Users/celio/AppData/Local/Temp/alns_r$reset"
    for inst in ["050_CLUS_2_1", "050_RAND_2_1", "075_RAND_2_1"]
        vals = Float64[]
        for seed in 1:5
            logf = joinpath(d, "$(inst)_s$(seed).log")
            isfile(logf) || continue
            for line in eachline(logf)
                if occursin("Best objective", line)
                    push!(vals, parse(Float64, split(line)[end]))
                end
            end
        end
        data[(inst, reset)] = vals
    end
end

@printf "%-22s  %-9s  %8s  %8s  %8s  %8s  %8s  |  %8s  %8s\n" "Instance" "Config" "s1" "s2" "s3" "s4" "s5" "best" "avg"
println(repeat("-", 100))
for inst in ["050_CLUS_2_1", "050_RAND_2_1", "075_RAND_2_1"]
    for reset in [3, 2]
        vals = data[(inst, reset)]
        isempty(vals) && continue
        best = minimum(vals)
        avg  = sum(vals) / length(vals)
        row  = join([@sprintf("%8.2f", v) for v in vals], "  ")
        @printf "%-22s  reset=%-3d  %s  |  %8.2f  %8.2f\n" inst reset row best avg
    end
    println()
end
