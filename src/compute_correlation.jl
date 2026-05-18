using Statistics, Printf

function load_csv(path)
    rows = Dict{String,Float64}()
    open(path) do f
        header = split(replace(replace(readline(f), "﻿"=>""), "\r"=>""), ",")
        icol = findfirst(==("instance"), header)
        ocol = findfirst(==("obj"),      header)
        for line in eachline(f)
            line = replace(line, "\r"=>"")
            isempty(line) && continue
            parts = split(line, ",")
            rows[strip(parts[icol])] = parse(Float64, strip(parts[ocol]))
        end
    end
    return rows
end

base    = load_csv("results/results_hetero.csv")
density = load_csv("results/results_hetero_density.csv")
ss      = load_csv("results/results_hetero_ss.csv")

instances = sort(collect(keys(base)))
common    = filter(i -> haskey(density,i) && haskey(ss,i), instances)

gap_d = [100*(density[i]-base[i])/base[i] for i in common]
gap_s = [100*(ss[i]     -base[i])/base[i] for i in common]
ttd_d = [density[i] for i in common]
ttd_s = [ss[i]      for i in common]

r_gap = cor(gap_d, gap_s)
r_ttd = cor(ttd_d, ttd_s)

@printf("Instances used  : %d\n", length(common))
@printf("Gap correlation : r = %.4f\n", r_gap)
@printf("TTD correlation : r = %.4f\n", r_ttd)
