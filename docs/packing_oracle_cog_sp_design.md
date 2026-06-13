# Packing oracle: Support Polygon + Center of Gravity (CoG–SP)

Design note for a **testable** stability-aware packing layer on top of the existing 1C-SP / 2C-SP / 3C-SP depth oracles.

**Reference (local PDF):** Ali, Galrão Ramos & Oliveira (2025), *Computers & Operations Research* 178, 107005 — **center-of-gravity polygon support** (§3.3), benchmarked against static mechanical equilibrium (Ramos et al., 2016b).

---

## 1. What CoG–SP means (from Ali et al.)

For a newly placed box \(b\) at \((x,y,z)\) with size \((l,w,h)\):

1. Find all **supporting** items (including the vehicle floor) whose **top** equals \(b\)’s bottom (\(z_\text{sup} + h_\text{sup} = z_b\)).
2. Collect **contact vertices** from axis-aligned **xy overlaps** between \(b\) and each supporter (up to four corner pairs per supporter).
3. Build the **support polygon** SP = convex hull of those vertices (gift-wrapping / monotone chain).
4. Place the box only if the item **center of gravity** \((x_\text{CoG}, y_\text{CoG})\) lies **inside or on** SP (point-in-polygon, counter-clockwise hull, negative cross products).

Assumption (Ali §4): mass uniformly distributed → **CoG at box geometric center**.

This is **static vertical stability**, not dynamic braking/turning, and not McKee **BCT** (PC6).

**Policy:** When the CoG–SP oracle is active, **PC2 is deactivated** in the packing heuristic. CoG–SP **substitutes** for PC2 (vertical stability / base-support proxy), not an extra layer on top of it. PC1, PC3, and PC4 remain enforced as today.

---

## 2. Fit with the current 3L-PDP solver

| Layer | Today (`*_csp`) | With CoG–SP (`*_csp_cog`) |
|--------|------------------|---------------------------|
| Routing | BRKGA + ALNS | unchanged |
| Merge depth | 1C / 2C / 3C-SP DP on **a-depth** | same DP skeleton |
| Cross-section | `_pack_2d_height` — shelf FFD, **no coordinates** | `_pack_2d_height_cog` — placements + SP test |
| **PC2** | **on** — implicit full base support via shelf packing (MIP omits PC2; see §3) | **off** — replaced by per-box **CoG ∈ SP** |
| PC3 | fragile → top shelf | on |
| PC4 | segment / vertical zones | on |
| PC5–PC7 | route-order policies | off unless explicitly enabled |

**PC2 vs CoG–SP (why deactivate PC2):**

- Current **PC2** in `packing.jl` is not M&B’s α%-area rule; it is “every item on floor or on a shelf with full footprint support” via `_pack_2d_height`.
- **CoG–SP** allows **partial** contact polygons (convex hull of overlaps) and checks equilibrium via CoG — stricter or looser than “full shelf” depending on layout; applying **both** would be redundant and ill-defined (double stability criterion).
- Ali et al. treat polygon-based rules as **alternatives** to full/partial-base support, not add-ons.

**Important:** 3C-SP today is a **sufficient depth certificate**, not a full 3D placement. CoG–SP needs **item positions** in the loading space. The new oracle is therefore:

> **Same 1C/2C/3C merge logic, but cross-section feasibility = shelf packing + CoG–SP check per placement.**

Not a small flag on the DP alone — a **placement-aware 2D packer** inside `_make_layers` / merge zones.

---

## 3. Proposed oracle family

### 3.1 Naming (for experiments)

| Oracle id | Merge | PC2 | Static stability in packer |
|-----------|--------|-----|----------------------------|
| `1csp` | off | **on** | shelf (PC2 proxy) |
| `2csp` | pairwise | **on** | shelf |
| `3csp` | triple DP | **on** | shelf |
| `1csp_cog` | off | **off** | **CoG–SP only** |
| `2csp_cog` | pairwise | **off** | **CoG–SP only** |
| `3csp_cog` | triple DP | **off** | **CoG–SP only** |

Toggle in `run_comparison_oracle_depth.jl` (or new `run_comparison_cog_sp.jl`):

```julia
_USE_MERGE[]  = oracle ∉ ("1csp", "1csp_cog")
_USE_3CSP[]   = oracle ∈ ("3csp", "3csp_cog")
_USE_COG_SP[] = endswith(oracle, "_cog")   # when true: PC2 checks skipped in packer
```

Implementation guard in `packing.jl` / `packing_cog_sp.jl`:

```julia
# Cross-section feasibility branch in _make_layers, _depth_2csp, _depth_3csp:
if _USE_COG_SP[]
    h, _ = _pack_2d_height_cog(...)   # PC2 deactivated
else
    h = _pack_2d_height(...)         # PC2 via shelf-FFD
end
```

### 3.2 Core new functions (`src/packing_cog_sp.jl`)

```text
PlacedBox(b, x, y, z)     # b::Box, origin in (b,c) = (y,x) vehicle axes — map consistently to (a,b,c)

_support_contacts(placed, floor_rect, b, x, y, z) -> Vector{(Float64,Float64)}

_convex_hull_2d(points) -> Vector{(Float64,Float64)}   # monotone chain, O(k log k)

_cog_inside_sp(x_cog, y_cog, hull) -> Bool            # Ali VP rule

_stable_placement?(placed, Wv, b, x, y, z) -> Bool

_pack_2d_height_cog(boxes, Wv, Hv) -> (height::Int, placed::Vector{PlacedBox})
    # shelf FFD order as now; reject placement if CoG–SP fails; try next shelf position

_pack_2d_height = alias when !_USE_COG_SP[]
```

**Box weight for CoG:** use `Box.weight` (already volume-proportional within request).

**Floor support:** when \(z=0\), SP is the intersection of box footprint with \([0,W_v]\) (or full footprint if on floor only).

### 3.3 Integration points

1. **`_make_layers`** — call `_pack_2d_height_cog` instead of `_pack_2d_height` when `_USE_COG_SP[]`.
2. **`_depth_2csp` / `_depth_3csp`** — merged zones call the same cog-aware 2D packer for stacked compartments (floor + upper zone); each zone maintains its own `placed` list at \(z=0\) and \(z=h_\text{far}\).
3. **`pack_route`** — unchanged interface: `0` feasible, else penalty.

### 3.4 Complexity / WPL expectation

- Per placement: \(O(S)\) supporters, \(O(S)\) hull vertices, \(S\) = boxes in cross-section (small per layer).
- Ali report **milliseconds per item** online; our routes have **few boxes per layer** → expect **still ≪ 1 ms** per `pack_route` vs 36 µs baseline, but measurable increase in `pack_calls` budget use.
- Document **pack_calls** and **pce** in CSV as today.

---

## 4. Relation to M&B and to PC5/PC6

| Rule | M&B V4 | `*_csp` (baseline oracle) | `*_csp_cog` oracle |
|------|--------|---------------------------|---------------------|
| PC2 / support | α = 0.75 area (C6) | shelf proxy (PC2 **on**) | PC2 **off**; **CoG–SP** |
| Fragile flag | yes | PC3 | PC3 |
| Density order | no | no (unless PC5) | no (unless PC5) |
| BCT / McKee | no | no (unless PC6) | no (unless PC6) |

CoG–SP can **reject** layouts M&B’s tree-search might allow (CoG outside SP) and **allow** some partial-support layouts M&B rejects — **not comparable** as “stricter superset”; it is a **different stability model**.

**Paper wording:** label `*_csp_cog` runs as **PC1 + PC3 + PC4 + CoG–SP** (PC2 explicitly disabled), vs baseline **PC1–PC4** with PC2 via the shelf heuristic.

---

## 5. Experiment plan (aligned with height study)

**Phase A — correctness / smoke**

- One instance `050_CLUS_2_1`, one seed, ALNS 300 s.
- Compare `3csp` vs `3csp_cog`: TTD, `pack_calls`, feasibility rate.
- Unit tests: toy 2–3 boxes, hand-checked hull + CoG inside/outside.

**Phase B — full benchmark (Table V analogue)**

- 54 instances × 3 seeds × 6 oracles (`1/2/3csp` + `*_cog`) × optional Hv 30,36.
- Same worker/resume pattern as `run_comparison_oracle_depth.jl`.
- **3,888** runs if both heights; **1,944** if Hv=30 only.

**Metrics to report**

- Mean **TTD** per class (as Table V).
- **Adv2v1%**, **Adv3v2%** with and without CoG–SP.
- **ΔTTD(3csp_cog − 3csp)** — does stability tighten routes?
- **pack_calls**, **pce**, wall time (CoG overhead).

**Hypotheses**

1. CoG–SP **reduces** false-feasible depth merges → **longer** routes (higher TTD) vs plain 3C-SP, but more physically credible layouts.
2. Benefit vs **1C** may **grow** on **Hv=36** (taller shelves → more stacked CoG sensitivity).
3. Gap vs M&B V4 remains dominated by **routing budget / certificate**, not only stability proxy.

---

## 6. Paper / literature hooks

- §2 (structural stacking): cite Ali et al. (2025) for **CoG–SP** vs binary fragility and vs partial-base α.
- §5: new small subsection or appendix table — **oracle ablation + stability proxy**.
- Do **not** claim equivalence to Ali’s **static mechanical equilibrium** in the hot loop (too slow); CoG–SP is the **fast proxy** they use online.

---

## 7. Implementation checklist

- [ ] `src/packing_cog_sp.jl` — hull, point-in-polygon, `_pack_2d_height_cog`
- [ ] `include` from `packing.jl`; `_USE_COG_SP` Ref (**PC2 off** when true)
- [ ] Branch in `_make_layers`, `_depth_2csp`, `_depth_3csp` (no `_pack_2d_height` on cog path)
- [ ] Nomenclature / §3: optional PC8 or “CoG–SP replaces PC2 in packer”
- [ ] Extend `run_comparison_oracle_depth.jl` oracle strings
- [ ] `test/test_cog_sp.jl` — regression hull + one feasible/infeasible layout
- [ ] `src/analyze_comparison_cog_sp.jl` — tables + optional `latex/tables/ablation_3oracle_cog.tex`
- [ ] Run after current **height study** completes (avoid competing for CPU)

---

## 8. Open decisions

1. **Partial-base polygon** (Ali §3.4): implement later or skip (stricter hybrid)?
2. **Rotations:** keep PC1 fixed orientation only (consistent with current code).
3. **Multi-request vertical zones:** CoG computed **per box** in global \((b,c)\) at the zone’s \(z\) offset — confirm no cross-zone SP (zones are separated by construction).
4. **Publishable label:** “**3C-SP–CoG**” or “**PC8** (static stability)” in nomenclature?

---

**Test plan (launch checklist):** [`cog_sp_oracle_test_plan.md`](cog_sp_oracle_test_plan.md)

*Status: design only — implementation not started. Height study (`comparison_oracle_depth_height`) should finish first.*
