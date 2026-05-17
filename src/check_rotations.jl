include("parser.jl")
inst = parse_instance(joinpath(@__DIR__, "..", "3L_PDP_instances", "050_CLUS_2_1.txt"))
Wv, Hv, Lv = inst.Wv, inst.Hv, inst.Lv
println("Vehicle: Lv=$Lv  Wv=$Wv  Hv=$Hv")

total_min_depth = 0
for req in inst.requests[1:8]
    req_min = 0
    print("Request $(req.id): ")
    for b in req.boxes
        perms = [(b.l,b.w,b.h),(b.l,b.h,b.w),(b.w,b.l,b.h),(b.w,b.h,b.l),(b.h,b.l,b.w),(b.h,b.w,b.l)]
        ok = filter(x -> x[2]<=Wv && x[3]<=Hv, perms)
        ml = isempty(ok) ? 999 : minimum(x[1] for x in ok)
        print("$(b.l)x$(b.w)x$(b.h)→min_l=$ml  ")
        req_min += ml
    end
    println("  req_depth≥$req_min")
    total_min_depth += req_min
end
println("\nIf route had 10 requests with similar boxes, total ≈ $total_min_depth for 8 shown")
