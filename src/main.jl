# Entry point for 3L-PDP experiments.
#
# Selects the solution method, instance file, and request subset via
# command-line arguments (or falls back to the defaults below).
#
# Usage (from project root):
#   julia --project=. src/main.jl [method] [instance] [first_req] [last_req]
#
# Arguments (all optional, positional):
#   method      : mip | brkga | alns          (default: mip)
#   instance    : filename inside 3L_PDP_instances/   (default: 050_CLUS_2_1.txt)
#   first_req   : first request ID (1-based)   (default: 1)
#   last_req    : last  request ID (1-based)   (default: 4 for mip, all for brkga/alns)
#   seed        : random seed (≥0); -1 = system random   (default: -1)
#
# Examples:
#   julia --project=. src/main.jl
#   julia --project=. src/main.jl mip  050_CLUS_2_1.txt 1 4
#   julia --project=. src/main.jl brkga 050_CLUS_2_1.txt
#   julia --project=. --threads auto src/main.jl brkga 050_CPCD_2_1.txt
#   julia --project=. src/main.jl alns 075_RAND_2_1.txt
#
# MIP notes:
#   The MIP is intended solely for formulation validation on small subsets (n ≤ 4).
#   The 300-s time limit is deliberately conservative: the binary variable count
#   roughly doubles with each added request, so n=5 would likely require hours and
#   n=6 days even with a generous limit.  Increasing the limit is therefore not
#   useful — a timed-out run with a large gap provides no validation evidence.
#   Validated result on Intel Ultra 7 155H / 64 GiB / HiGHS 1.13.1:
#     subset 1:4 → optimal in ~170 s, 1 721 constraints, 825 variables (763 binary),
#     obj = 258.28, gap = 0.004%
#
# BRKGA/ALNS notes:
#   Both methods are implemented in brkga.jl and alns.jl respectively.
#   Both embed the Layer/SP packing heuristic from src/packing.jl, which
#   enforces PC1–PC4 via shelf-FFD layers and optional 2C-SP boundary merging.

include("parser.jl")
include("utils.jl")
include("model.jl")
include("brkga.jl")
include("alns.jl")

const INSTANCES_DIR = joinpath(@__DIR__, "..", "3L_PDP_instances")

# ── defaults ─────────────────────────────────────────────────────────────────
const DEFAULT_METHOD   = "mip"
const DEFAULT_INSTANCE = "050_CLUS_2_1.txt"
const DEFAULT_FIRST    = 1
const DEFAULT_LAST_MIP = 4       # MIP is tractable only for small subsets
const DEFAULT_LAST_META = nothing # metaheuristics use the full instance

# ── argument parsing ──────────────────────────────────────────────────────────
function parse_args()
    args    = ARGS
    method  = length(args) >= 1 ? lowercase(args[1]) : DEFAULT_METHOD
    inst_fn = length(args) >= 2 ? args[2]            : DEFAULT_INSTANCE
    first_r = length(args) >= 3 ? parse(Int, args[3]) : DEFAULT_FIRST
    last_r  = length(args) >= 4 ? parse(Int, args[4]) : nothing
    seed    = length(args) >= 5 ? parse(Int, args[5]) : -1
    reset   = length(args) >= 6 ? parse(Int, args[6]) : 2

    method in ("mip", "brkga", "alns") ||
        error("Unknown method \"$method\". Choose: mip | brkga | alns")

    inst_path = joinpath(INSTANCES_DIR, inst_fn)
    isfile(inst_path) ||
        error("Instance file not found: $inst_path")

    return method, inst_path, first_r, last_r, seed, reset
end

# ── instance loading ──────────────────────────────────────────────────────────
function load_instance(inst_path, first_r, last_r, method)
    println("Parsing instance: $inst_path")
    inst_full = parse_instance(inst_path)
    println("  Full instance : $(n_requests(inst_full)) requests, " *
            "$(n_items(inst_full)) items, " *
            "vehicle $(inst_full.Lv)×$(inst_full.Wv)×$(inst_full.Hv), " *
            "Q=$(inst_full.Q), K=$(inst_full.max_routes)")

    # Determine the effective request range
    n = n_requests(inst_full)
    if isnothing(last_r)
        last_r = (method == "mip") ? min(DEFAULT_LAST_MIP, n) : n
    end
    last_r = min(last_r, n)
    subset_ids = first_r:last_r

    inst = (first_r == 1 && last_r == n) ?
        inst_full :
        extract_subset(inst_full, subset_ids)

    label = (first_r == 1 && last_r == n) ? "full instance" : "subset $subset_ids"
    println("  Using $label : $(n_requests(inst)) requests, " *
            "$(n_items(inst)) items, K=$(inst.max_routes)")
    println()

    return inst
end

# ── method dispatch ───────────────────────────────────────────────────────────
function run(method, inst, seed=-1, reset=3)
    if method == "mip"
        println("Method : MIP (exact, formulation validation only)")
        println("Solver : HiGHS via JuMP  |  time limit 300 s\n")
        solve_3lpdp(inst; time_limit=300.0)

    elseif method == "brkga"
        println("Method : Parallel BRKGA  (BrkgaMpIpr.jl)")
        println("Threads: $(Threads.nthreads())  " *
                "(launch with --threads auto to use all cores)\n")
        solve_brkga(inst; time_limit=300.0)

    elseif method == "alns"
        println("Method : Adaptive Large Neighbourhood Search  (MHLib.jl)\n")
        solve_alns(inst; time_limit=300.0, seed=seed, full_reset_after=reset)
        # returns (obj, time, pack_calls, pack_feasible) — PCE printed inside solve_alns
    end
end

# ── entry point ───────────────────────────────────────────────────────────────
function main()
    method, inst_path, first_r, last_r, seed, reset = parse_args()
    inst = load_instance(inst_path, first_r, last_r, method)
    run(method, inst, seed, reset)
end

main()
