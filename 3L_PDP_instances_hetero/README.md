# 3L-PDP-H — Heterogeneous-material instances

Synthetic heterogeneous variants of the 54-instance Männel & Bortfeldt (2016, 2018) benchmark for the Three-Dimensional Loading Pickup-and-Delivery Problem (3L-PDP).

## Motivation

The original M&B benchmark assigns box weights proportional to box volume, so volumetric density is nearly constant within each instance. Two stacking policies — density ordering (PC5) and structural BCT stacking (PC6) — then impose almost identical delivery sequences (Pearson *r* ≈ 0.99 on per-instance travel distance).

These 270 instances break the weight–volume correlation by independently randomising per-request density and cardboard quality (ECT), so PC5 and PC7 can diverge.

## Generation

Each of the 54 M&B base instances is perturbed with five cargo seeds (H1–H5):

1. **Weight randomisation** — `w' = round(ρ' × V_r)` with `ρ' = ρ_base × exp(σ ε)`, `ε ~ N(0,1)`, `σ = 0.7`, capped to `[1, Q]`.

2. **ECT by inverse density tercile** (Twede & Selke, 2005 load classes):

   | Density tercile | ECT (kN/m) | Load class |
   |-----------------|-----------|------------|
   | Lightest third | 6.0 | Difficult — box walls carry load |
   | Middle third | 5.0 | Medium |
   | Densest third | 4.0 | Easy — cargo self-supports |

Box dimensions and routing coordinates match the base instance.

```powershell
julia --project=. src/gen_hetero_instances.jl
```

## Naming

```
{NNN}_{TYPE}_{BOX}_{IDX}_H{SEED}.txt
```

- `NNN` ∈ {050, 075, 100} — request count  
- `TYPE` ∈ {RAND, CLUS, CPCD}  
- `BOX` ∈ {2, 3}  
- `IDX` — base replicate index  
- `SEED` ∈ {1,…,5} — heterogeneous cargo seed  

## Format

Same as M&B, with optional ECT token appended to each request line:

```
Line 1:   max_routes  n_requests  Q  Lv  Wv  Hv
Line 2:   depot …
Lines 3+: req_id  px  py  svc_p  dx  dy  svc_d  total_weight  n_boxes
          [l  w  h  fragile] × n_boxes  ECT
```

Parsers that ignore trailing tokens default to ECT = 6.0 kN/m (M&B-compatible).

## Citation

Cite the M&B benchmark papers above when using the base geography.  
If you use the heterogeneous set, cite the accompanying 3L-PDP manuscript (under review, 2026) once published.
