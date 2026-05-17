# Parse a 3L-PDP instance file (Mannèl & Bortfeldt format).
#
# Line 1: max_routes  n_requests  Q  Lv  Wv  Hv
# Line 2: depot_id  x  y  depot_id  x  y  max_duration  obsolete
# Lines 3...: req_id  px  py  svc_p  dx  dy  svc_d  total_weight  n_boxes
#             [l  w  h  fragile] × n_boxes

include("types.jl")

function parse_instance(path::String)::Instance
    lines = readlines(path)
    # strip comments / empty lines (none expected, but be safe)
    lines = filter(l -> !isempty(strip(l)), lines)

    # --- Line 1: global data ---
    tok1 = split(strip(lines[1]))
    max_routes = parse(Int, tok1[1])
    # tok1[2] is the stated n_requests (may differ from actual; we count from data)
    Q   = parse(Int, tok1[3])
    Lv  = parse(Int, tok1[4])
    Wv  = parse(Int, tok1[5])
    Hv  = parse(Int, tok1[6])

    # --- Line 2: depot ---
    tok2  = split(strip(lines[2]))
    depot = Depot(parse(Int, tok2[2]), parse(Int, tok2[3]))

    # --- Lines 3+: requests ---
    requests = Request[]
    for line in lines[3:end]
        tok = split(strip(line))
        isempty(tok) && continue

        idx = 1
        req_id        = parse(Int, tok[idx]); idx += 1
        px            = parse(Int, tok[idx]); idx += 1
        py            = parse(Int, tok[idx]); idx += 1
        service_p     = parse(Int, tok[idx]); idx += 1
        dx            = parse(Int, tok[idx]); idx += 1
        dy            = parse(Int, tok[idx]); idx += 1
        service_d     = parse(Int, tok[idx]); idx += 1
        total_weight  = parse(Int, tok[idx]); idx += 1
        n_boxes       = parse(Int, tok[idx]); idx += 1

        # Compute box volumes for weight allocation
        raw_boxes = Tuple{Int,Int,Int,Bool}[]
        total_vol = 0
        for _ in 1:n_boxes
            l = parse(Int, tok[idx]); idx += 1
            w = parse(Int, tok[idx]); idx += 1
            h = parse(Int, tok[idx]); idx += 1
            f = parse(Int, tok[idx]) == 1; idx += 1
            push!(raw_boxes, (l, w, h, f))
            total_vol += l * w * h
        end

        boxes = Box[]
        for (l, w, h, f) in raw_boxes
            vol    = l * w * h
            weight = vol * total_weight / total_vol
            push!(boxes, Box(l, w, h, f, weight))
        end

        ect = idx <= length(tok) ? parse(Float64, tok[idx]) : 6.0

        push!(requests, Request(req_id, px, py, service_p, dx, dy, service_d,
                                total_weight, boxes, ect))
    end

    return Instance(max_routes, Q, Lv, Wv, Hv, depot, requests)
end
