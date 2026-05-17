# Generate heterogeneous variants of the M&B 54-instance benchmark.
#
# The M&B instances assign box weight proportional to volume, so all requests
# within an instance share the same volumetric density.  This makes PC5
# (density ordering) and PC6 (BCT ordering) impose virtually identical
# delivery sequences.
#
# This script breaks that correlation by independently randomising per-request
# density, and then assigning ECT inversely by density tercile — following the
# "easy/medium/difficult load" classification of Twede & Selke (2005, Cartons,
# Crates and Corrugated Board):
#
#   Dense cargo ("easy load"):  product self-supports → lighter cardboard suffices
#   Light cargo ("difficult load"): box walls carry 100% of stacking load → high ECT
#
#   Bottom density tercile (lightest) → ECT 6.0 kN/m  (heavy-duty BC-flute)
#   Middle density tercile            → ECT 5.0 kN/m  (standard BC-flute)
#   Top density tercile (densest)     → ECT 4.0 kN/m  (light-duty BC-flute)
#
# This inverse density–ECT correlation makes PC5 and PC6 structurally opposed:
# PC5 places dense requests last (high density), while PC6 requires dense
# requests early (low BCT cannot support weight above them).
# PC5 and PC6 therefore point in opposite directions, unlike the M&B benchmark
# where they are nearly equivalent.
#
# Output format: identical to the M&B format except each request line ends
# with the ECT value appended as an extra token.  The parser reads it via the
# backward-compatible optional-ECT logic added in parser.jl.
#
# Usage:
#   julia src/gen_hetero_instances.jl

include("types.jl")
include("parser.jl")

using Random

const SIGMA_DENSITY = 0.7               # log-normal σ for density perturbation
const ECT_GRADES    = [4.0, 5.0, 6.0]  # kN/m; assigned by density tercile
const N_SEEDS       = 5                 # hetero variants per base instance

function gen_hetero(path_in::String, path_out::String, seed::Int)
    rng  = MersenneTwister(seed)
    inst = parse_instance(path_in)

    lines = filter(l -> !isempty(strip(l)), readlines(path_in))

    # ── Step 1: sample perturbed density for every request ─────────────────────
    densities  = Float64[]
    total_vols = Float64[]
    for r in inst.requests
        vol    = Float64(sum(b.l * b.w * b.h for b in r.boxes))
        ρ_base = vol > 0 ? r.total_weight / vol : 1.0
        push!(densities,  ρ_base * exp(randn(rng) * SIGMA_DENSITY))
        push!(total_vols, vol)
    end

    # ── Step 2: assign ECT inversely by density tercile (denser → lighter cardboard)
    # Follows Twede & Selke (2005): dense/rigid "easy loads" self-support and need
    # lower ECT; light/hollow "difficult loads" rely entirely on box walls → high ECT.
    n          = length(densities)
    sorted_d   = sort(densities)
    t1         = sorted_d[max(1, div(n, 3))]      # 33rd-percentile threshold
    t2         = sorted_d[max(1, 2 * div(n, 3))]  # 67th-percentile threshold
    new_ects   = [d <= t1 ? 6.0 : (d <= t2 ? 5.0 : 4.0) for d in densities]
    new_weights = [max(1, min(inst.Q, round(Int, densities[i] * total_vols[i])))
                   for i in 1:n]

    # ── Step 3: rewrite instance file ──────────────────────────────────────────
    out_lines = String[lines[1], lines[2]]   # header + depot unchanged

    req_idx = 0
    for line in lines[3:end]
        tok = split(strip(line))
        isempty(tok) && continue
        req_idx += 1

        tokens    = collect(tok)
        tokens[8] = string(new_weights[req_idx])   # replace weight field
        n_boxes   = parse(Int, tokens[9])
        tokens    = tokens[1:min(end, 9 + n_boxes * 4)]  # strip old ECT if any
        push!(tokens, string(new_ects[req_idx]))

        push!(out_lines, join(tokens, " "))
    end

    mkpath(dirname(path_out))
    open(path_out, "w") do f
        for l in out_lines; println(f, l); end
    end
end

function main()
    inst_dir = joinpath(@__DIR__, "..", "3L_PDP_instances")
    out_dir  = joinpath(@__DIR__, "..", "3L_PDP_instances_hetero")

    isdir(inst_dir) || error("Instance directory not found: $inst_dir")

    inst_files = sort(filter(f -> endswith(f, ".txt") && f != "readme.txt",
                             readdir(inst_dir)))

    total = length(inst_files) * N_SEEDS
    println("Generating $total hetero instances ($N_SEEDS seeds × $(length(inst_files)) base)…")
    println("  ECT assignment: inverse density tercile (lightest→6.0, middle→5.0, densest→4.0 kN/m)")

    for fname in inst_files
        path_in  = joinpath(inst_dir, fname)
        base     = splitext(fname)[1]
        for seed in 1:N_SEEDS
            path_out = joinpath(out_dir, "$(base)_H$(seed).txt")
            gen_hetero(path_in, path_out, seed)
        end
    end

    println("Done → $out_dir")
end

main()
