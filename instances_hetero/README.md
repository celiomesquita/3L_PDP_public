# 3L-PDP Heterogeneous-Material Instances (3L-PDP-H)

Synthetic heterogeneous variants of the 54-instance benchmark of
Männel & Bortfeldt (2016, 2018) for the Three-Dimensional Loading
Pickup-and-Delivery Problem (3L-PDP).

## Motivation

The original M&B benchmark assigns box weights proportional to box volume,
which causes the volumetric density ρ = w/V to be nearly constant across
all requests within an instance. As a consequence, two stacking constraints
that are theoretically independent — a density-ordering rule (PC5) and a
structural load-bearing constraint based on Box Compression Test strength
(PC6) — impose virtually identical delivery orderings on the M&B instances
(Pearson r = 0.9986 on per-instance travel distance).

These 270 instances break the weight–volume correlation by independently
randomising per-request density and per-request cardboard quality (ECT),
allowing PC5 and PC6 to impose genuinely different delivery sequences.

## Instance generation

Each of the 54 M&B base instances is perturbed with 5 random seeds
(H1–H5), yielding 270 instances total. For each variant:

1. **Weight randomisation** — the total weight of every request is resampled as  
   `w' = round(ρ' × V_r)`  
   where `V_r` is the unchanged request volume and  
   `ρ' = ρ_base × exp(σ ε)`, `ε ~ N(0,1)`, `σ = 0.7`.  
   The resulting weight is capped at `[1, Q]` (vehicle capacity).  
   This produces per-request densities spanning roughly 0.3× – 3.2× the
   base density at the 5th/95th percentile.

2. **ECT assignment — inverse by density tercile** — following the
   "easy/medium/difficult load" classification of Twede & Selke (2005):
   dense, rigid cargo ("easy loads") self-supports during stacking and
   requires lighter cardboard, while light, hollow cargo ("difficult loads")
   relies entirely on the box walls and requires higher ECT.

   | Density tercile | ECT (kN/m) | Load classification |
   |-----------------|-----------|---------------------|
   | Bottom third (lightest) | 6.0 | Difficult load — box walls carry all stacking load |
   | Middle third | 5.0 | Medium load |
   | Top third (densest) | 4.0 | Easy load — product self-supports |

   This inverse density–ECT correlation makes PC5 and PC6 structurally
   **opposed**: PC5 places dense requests last (high density), while PC6
   requires dense requests early (low BCT cannot support weight above them).
   Box dimensions and all routing parameters are kept identical to the base
   instance.

To regenerate the instances from the M&B base files, run:

```
julia --project=. src/gen_hetero_instances.jl
```

## File naming

```
{NNN}_{TYPE}_{BOX}_{IDX}_H{SEED}.txt
```

| Field  | Values              | Meaning                        |
|--------|---------------------|--------------------------------|
| `NNN`  | 050, 075, 100       | Number of requests             |
| `TYPE` | CLUS, CPCD, RAND    | Instance class                 |
| `BOX`  | 2, 3                | Max boxes per request          |
| `IDX`  | 1–5 (n=50), 1–3 (n=75), 1 (n=100) | Base instance index |
| `SEED` | 1–5                 | Heterogeneous variant seed     |

## File format

Identical to the M&B format, with one extension: each request line ends
with the ECT value (in kN/m) appended as an extra token.

```
Line 1:   max_routes  n_requests  Q  Lv  Wv  Hv
Line 2:   depot_id  x  y  depot_id  x  y  max_duration  (unused)
Lines 3+: req_id  px  py  svc_p  dx  dy  svc_d  total_weight  n_boxes
          [l  w  h  fragile] × n_boxes  ECT
```

Parsers that stop after reading `n_boxes × 4` box tokens will silently
ignore the ECT field and default to 6.0 kN/m (backward-compatible with
the original M&B format).

## Reference

If you use these instances, please cite the paper that introduced them:

> Mesquita, A. C. P., *et al.* (2026). *A polynomial-time packing oracle
> for the 3L-PDP with practical stacking constraints.* (under review)

and the original M&B benchmark:

> Männel, D., & Bortfeldt, A. (2016). A hybrid algorithm for the
> vehicle routing problem with pickup and delivery and three-dimensional
> loading constraints. *European Journal of Operational Research*,
> 254(3), 840–858.

> Männel, D., & Bortfeldt, A. (2018). Solving the three-dimensional
> loading vehicle routing problem with pickup and delivery.
> *Transportation Science*, 53(3), 840–864.
