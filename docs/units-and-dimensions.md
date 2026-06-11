# Units & dimensional analysis: the Julia landscape, and what Jurist does with it

*Researched and probed live 2026-06-11. Receipts below are real runs on this
machine, not paraphrases.*

## The landscape

### DynamicQuantities.jl — the modern one, and the seam-friendly one

[SymbolicML/DynamicQuantities.jl](https://github.com/SymbolicML/DynamicQuantities.jl)
(v1.13, May 2026, actively maintained). A quantity's dimension is a **plain
runtime value** — seven rational exponents (mass, length, time, current,
temperature, luminosity, amount) in a small struct — rather than a type
parameter. That design choice is exactly Jurist-shaped: a dimension is a tiny
record of integers, trivially representable as a PureScript value *and* as a
PureScript phantom type. No opaque handles needed at the seam.

Probe receipts:

```
F*d   = 1.56 m² kg s⁻²        (5.2 N × 0.3 m — dimensions carried through arithmetic)
m + s → DimensionError: 1.0 m and 2.0 s have incompatible dimensions
100 km/h = 27.78 m s⁻¹        (uconvert; us"…" symbolic units survive round-trips)
g exponents: length=1 time=-2 mass=0      ← dimensions as plain values
```

API surface that matters to us: `u"m/s"` (SI-normalised), `us"km/h"`
(symbolic, preserves notation), `ua"degC"` (affine), `uparse`/`sym_uparse`
(string → unit at runtime — the seam entry point), `uconvert`, `ustrip`,
`dimension`, per-axis accessors `ulength`/`utime`/`umass`/…,
`Dimensions(; mass=, length=, time=, …)` (construct a dimension from
exponents), `@register_unit`. Converts to/from Unitful.

### ModelingToolkit v11 — native unit validation (we are already on MTK 11)

MTK validates dimensional consistency **at system construction**, using
DynamicQuantities (it moved off Unitful; the docs explicitly warn against
Unitful quantities). Units attach as variable metadata:

```julia
@variables v(t) [unit = u"m/s"]
@parameters g [unit = u"m/s^2"]
```

Dynamically (our seam): `Symbolics.setmetadata(var, ModelingToolkit.VariableUnit, uparse("m/s"))`.

Functions: `ModelingToolkit.validate(eqs) :: Bool` (warns, doesn't throw),
`get_unit(expr)` (throws on inconsistency), `safe_get_unit` (returns
`nothing`), `equivalent(u1, u2)`. `System(eqs, t)` **refuses to construct**
an inconsistent model (`ValidationError`).

Probe receipts (falling body with drag; broken by writing the drag term
`c·v²` with `c :: 1/s`):

```
consistent system validates: true     (get_unit of RHS: 1.0 m s⁻²)
Warning: in eq. #2right, in sum -g - c*(v(t)^2), units [1.0 m s⁻², 1.0 m² s⁻³] do not match.
System(bad) throws: ValidationError("Some equations had invalid units. ...")
```

Caveats from the docs: validation demands equal *units*, not just equal
dimensions (no automatic conversion insertion); unitful literals can't appear
inside equations (only variables/parameters carry units); trig assumes
radians; parameter *values* are plain numbers assumed pre-converted.

### Unitful.jl — the type-system one, and its ecosystem

The long-standing standard: units as type parameters (zero overhead when
inferable), a huge unit catalog, affine units (°C/°F). Slower than
DynamicQuantities when dimensions vary dynamically. Its ecosystem is the real
draw:

- **Measurements.jl** — linear uncertainty propagation, composes with Unitful
  so units AND error bars propagate together. Probe receipt — spring
  5.2±0.1 N/m, mass 350±5 g, `T = 2π√(m/k)`:

  ```
  pendulum T = 1.63 ± 0.02 s
  ```

  Nothing in the JS world does this composition.
- **UnitfulLatexify** — typeset quantities/units to LaTeX; drops straight
  into the existing Latexify → KaTeX pipeline on the site pages.
- **PhysicalConstants.jl** — CODATA constants *with units and uncertainties*.
- UnitfulAstro, UnitfulUS, UnitfulEquivalences (E=mc², eV ↔ nm), etc.

## The options

- **A. Unit-annotated `SystemSpec` + `validateUnits` verb** — each state/param
  variable carries a unit string; the MTK denotation attaches the metadata; the
  verb answers `Deferred` on Node/BEAM and on Julia the *proof* — or the
  refusal naming the offending term and the two clashing units. Guess-vs-proof
  tier; no JS library dimensionally validates a symbolic ODE system.
  **STATUS: implemented 2026-06-11** (core `StringRow`/`ToTexts`,
  `Data.MTKSystem.validateUnits`, `Data.Verbs.validateUnits` ×3,
  drag-system receipts in `VerbsDemo`).
- **B. Dimensions in the PureScript type system** — `Quantity (m :: Int)
  (l :: Int) (t :: Int)` with `Prim.Int` type-level integers: a
  mis-dimensioned equation is **a compile error in the browser**, before Julia
  ever sees it; Julia (DynamicQuantities) is the production denotation for
  display, conversion and independent re-validation. The next sentence after
  "a misspelt field is a compile error".
  **STATUS: implemented 2026-06-11** (`examples/dimensioned/`).
- **C. Units × uncertainty verb** — measured parameters in
  (`5.2±0.1 N/m`), propagated answer out (`1.63 ± 0.02 s`) via
  Measurements×Unitful. Very legible, lab-physics-shaped. **Parked.**
- **D. Typeset unitful answers** — UnitfulLatexify in the existing
  derivatives/KaTeX pipeline. Presentation gravy. **Parked.**

## PureScript-side notes (for B)

- `Prim.Int` (purs ≥ 0.15) gives a type-level `Int` kind with literals
  (incl. negative: `(-2)`) and classes `Add l r s | l r -> s, l s -> r,
  r s -> l` and `Mul l r p | l r -> p`. Add's three-way fundeps give
  subtraction (division of quantities) for free. Mul's single fundep means
  `qSqrt` needs its result type fixed by annotation or context — fine in
  practice, document it.
- `Data.Reflectable` (prelude ≥ 6) reflects type-level Ints to runtime Ints —
  compiler-solved instances, materialised in CoreFn, so they work on purejl
  (and every other backend) for free. This is how the phantom dimensions cross
  the seam as plain values.
- Prior art: sharkdp's `purescript-quantities` (runtime-valued quantities,
  powers insect). Nobody has done the type-level version as an eDSL with a
  production denotation.
- We deliberately do NOT overload `+`/`*` (Semiring wants one type);
  the eDSL uses `|+|` `|-|` `|*|` `|/|` and `qSqrt`.

## Operational notes

- DynamicQuantities precompiles in seconds and is now a committed dep of
  `examples/numexpr-edsl/julia/julia-env` (and `examples/dimensioned`'s env).
- Julia pkg installs on this machine need the LittleSnitch/IPv6 workaround:
  `JULIA_PKG_SERVER="" julia --project=. -e 'using Pkg; Pkg.add(...)'`.
- MTK warning text is captured by running `validate` under
  `Logging.with_logger(Logging.SimpleLogger(io, Logging.Warn))` — that's how
  the verb returns the human-readable complaint across the seam.
- References: [MTK Units & Validation docs](https://docs.sciml.ai/ModelingToolkit/stable/basics/Validation/),
  [DynamicQuantities.jl](https://github.com/SymbolicML/DynamicQuantities.jl).
