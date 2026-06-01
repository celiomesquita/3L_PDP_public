# Memetic-stack oracle depth panel (1C / 2C / 3C-SP).
#
# Runs the full BRKGA+ALNS hybrid on a stratified instance subset under
# three oracle depths, isolating merge-depth effects without ALNS-only confounding.
#
# Usage:
#   julia --threads 18,2 --project=. src/run_memetic_oracle_panel.jl [time_limit] [seeds]

using Printf
using Statistics
using Random

include("parser.jl")
include("types.jl")
include("utils.jl")
include("packing.jl")
include("run_memetic_benchmark.jl")

const PANEL = [
    "050_RAND_2_1.txt", "050_CLUS_2_1.txt", "050_CPCD_2_1.txt",
    "050_RAND_3_1.txt", "050_CLUS_3_1.txt", "050_CPCD_3_1.txt",
    "075_RAND_2_1.txt", "075_CLUS_2_1.txt", "075_CPCD_2_1.txt",
    "100_RAND_2_1.txt", "100_CLUS_2_1.txt", "100_CPCD_2_1.txt",
]

const ORACLE_TAGS = ("1csp", "2csp", "3csp")

function set_oracle!(tag::String)
    if tag == "1csp"
        _USE_MERGE[] = false
        _USE_3CSP[]  = true
    elseif tag == "2csp"
        _USE_MERGE[] = true
        _USE_3CSP[]  = false
    elseif tag == "3csp"
        _USE_MERGE[] = true
        _USE_3CSP[]  = true
    else
        error("Unknown oracle tag: $tag")
    end
    _USE_DENSITY[] = false
    _USE_SS[]      = false
end

function main()
    time_limit = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 300.0
    seeds      = length(ARGS) >= 2 ? [parse(Int, s) for s in split(ARGS[2], ",")] : [1]
    inst_dir   = DEFAULT_INST_DIR
    out_dir    = joinpath(@__DIR__, "..", "results")
    isdir(out_dir) || mkdir(out_dir)
    csv_path   = joinpath(out_dir, "memetic_oracle_panel.csv")
    header     = "instance,oracle,seed,time_limit_s,ttd,feasible,max_loaded_volume_pct"

    if !isfile(csv_path)
        open(csv_path, "w") do io; println(io, header); end
    end

    done = Set{Tuple{String,String,Int}}()
    if isfile(csv_path)
        for line in eachline(csv_path)
            startswith(line, "instance,") && continue
            p = split(line, ",")
            length(p) >= 3 && push!(done, (p[1], p[2], parse(Int, p[3])))
        end
    end

    println("Memetic oracle panel  T=$(time_limit)s  seeds=$(join(seeds, ","))")
    println("  instances=$(length(PANEL))  output=$csv_path")
    flush(stdout)

    for inst_file in PANEL
        inst_name = replace(inst_file, ".txt" => "")
        inst      = parse_instance(joinpath(inst_dir, inst_file))
        for tag in ORACLE_TAGS
            set_oracle!(tag)
            for seed in seeds
                key = (inst_name, tag, seed)
                key in done && continue
                @printf("  RUN  %-22s  %-5s  seed=%d  ... ", inst_name, tag, seed)
                flush(stdout)
                res = run_memetic(inst, seed, time_limit)
                open(csv_path, "a") do io
                    @printf(io, "%s,%s,%d,%.1f,%.5f,%s,%.2f\n",
                            inst_name, tag, seed, time_limit,
                            res.ttd, string(res.feasible), res.vol_pct)
                end
                @printf("ttd=%.2f\n", res.ttd)
                flush(stdout)
            end
        end
    end
    println("\nDone. Results: $csv_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
