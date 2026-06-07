# Julia-shaped libraries: giving Julia's powers a PureScript face

Design notes (2026-06) on the question: what FFI-heavy libraries would
let PureScripters leverage Julia's special powers *attractively* — not
API wrappers, but structures (ST-monad-like and beyond) that make the
combination better than either side alone?

## The doctrine: descriptions across, handles back

Julia's superpower is the **specializing JIT**: it wants the whole
problem before it runs. Hand DifferentialEquations.jl a derivative
function and it specializes, vectorizes, chooses stiffness-aware
solvers. This dictates the FFI shape, negatively and positively:

**Anti-pattern: callbacks.** Julia calling back into a PS closure per
evaluation is doubly fatal — the curried-Dict glue costs ~325 ns/call
(measured, see worklog 2026-06-05), and a black-box closure is opaque
to the specializer, so Julia degrades to a slow interpreter of foreign
function pointers. At 10⁸ derivative evaluations this is seconds vs
hours. Any design where the hot loop crosses the seam is dead on
arrival.

**Pattern: staging.** PureScript's own superpower is building
well-typed ASTs (tagless final, free structures, row types — the HATS
sensibility). So:

1. PS builds a typed *description* of the computation (an eDSL term);
2. the seam is crossed **once**, carrying the description;
3. Julia metaprograms it into specialized native code
   (Symbolics/ModelingToolkit, `RuntimeGeneratedFunctions`,
   `@generated`);
4. what returns are **handles** to Julia-owned data;
5. handles are manipulated under an **ST-style region** (rank-2
   phantom, `run :: (forall h. JuliaST h a) -> Effect a`) so they
   cannot escape;
6. only an explicit `freeze`/`sample` materializes data into PS-land —
   which, in the Hylograph topology, means into the visualization.

The region monad is not speculative: the `Data.Array.ST` shims that
passed the differential suite (422/426 vs JS) *are* mutable Julia
vectors under exactly this discipline. The pattern is proven; the cargo
needs upgrading from `Vector{Any}` to Julia's real types.

Deployment note: in-process (this backend) the handles are Julia
objects; over the wire (browser ↔ BEAM ↔ Julia leaf) the *same typed
API* becomes a remote-handle protocol. Region types then express not
just lifetime but **placement** — which runtime owns the data — in the
types.

## Tier 1 — typed ST arrays (incremental; near-term)

`STNumberVector h` backed by `Vector{Float64}` (not `Vector{Any}`),
with `STFn` foreigns for the operations Julia does natively:

```purescript
foreign import data STNumberVector :: Region -> Type
new       :: forall h. Int -> ST h (STNumberVector h)
mapNum    :: forall h. (Number -> Number) -> ...   -- see caveat
axpy      :: forall h. Number -> STNumberVector h -> STNumberVector h -> ST h Unit
dot       :: forall h. STNumberVector h -> STNumberVector h -> ST h Number
sumNum, normL2, broadcast ops, slices...
freeze    :: forall h. STNumberVector h -> ST h (Array Number)
```

Caveat on `mapNum`: a PS closure per element is the callback
anti-pattern in miniature. Either restrict to a vocabulary of fused
kernels (`scale`, `offset`, `clamp`, `expV`, …), or accept a small
expression AST (`NumExpr`) that the shim compiles to a broadcast — the
Tier-2 idea at micro scale. Precedent: `purescript-arraybuffer` did
this move on JS typed arrays; the payoff here is BLAS.

Effort: comparable to a weekend; no new concepts beyond the existing
ST shims. Also the natural substrate for matrices
(`STMatrix h`, `mul!`, `lu`, `eigen` returning handle pairs).

## Tier 2 — the Solve eDSL (the flagship)

A tagless-final PS DSL for ODE/SDE/dynamical systems whose denotation
is a ModelingToolkit/Symbolics system. PS row types enforce at compile
time what MTK checks at runtime:

```purescript
lorenz :: SystemSpec ( x :: State, y :: State, z :: State )
                     ( sigma :: Param, rho :: Param, beta :: Param )
lorenz = system
  { x: \s p -> p.sigma * (s.y - s.x)
  , y: \s p -> s.x * (p.rho - s.z) - s.y
  , z: \s p -> s.x * s.y - p.beta * s.z
  }
```

— where the lambdas are *not* runtime closures but build `NumExpr` ASTs
(tagless final over a `NumF` algebra; the record-of-equations trick
keeps state access typed by row). The seam crossing hands MTK the
symbolic system; MTK compiles the RHS (and, free of charge: Jacobians
via symbolic differentiation, sparsity detection, stiffness handling).
Back comes a `SolutionHandle h` — sampled lazily, windowed, decimated
for the visualization, never copied wholesale.

Extensions that fall out of the same shape:
- **DynamicalSystems.jl**: basins of attraction, Lyapunov spectra —
  `basins :: SystemSpec s p -> Grid -> Leaf (Matrix Int)` (the
  Marginalia 219 north star).
- **Units**: phantom units on `NumExpr` map onto Unitful.jl's
  type-level dimensions — the same invariant encoded in both type
  systems, checked twice, erased nowhere.
- **Autodiff**: `gradient :: NumExpr -> NumExpr` via
  Symbolics/ForwardDiff — PS types say *what* was differentiated.
- **Turing.jl**: a free-monad PPL in PS, interpreted by NUTS on the
  leaf — same staging, stochastic cargo.
- **IntervalArithmetic.jl**: solvers returning `Certified a`
  (rigorous enclosures, distinguished by type from float estimates) —
  rhymes with the differential suite's strong-claims ethos.

The keystone demo: the existing Lorenz showcase rebuilt this way —
typed system in PS, MTK-compiled solve in Julia, Hylograph rendering —
sits squarely in the site's "Native" evidence category (Marginalia
220).

## Tier 3 — Catlab.jl / AlgebraicJulia (the philosophical jackpot)

AlgebraicJulia *computes* with category theory: C-sets, structured
cospans, wiring diagrams, Petri nets. PureScript speaks this language
natively in its abstractions, and **C-set schemas are practically row
types** — a schema is a record of objects and typed morphisms.

The library: typed combinators for open Petri nets / wiring diagrams
(composition along boundaries = the structured-cospan composition
Catlab implements), with Julia doing schema instantiation, colimits,
and simulation (AlgebraicPetri → vectorfield → DiffEq — note this
*reuses Tier 2*), and Hylograph rendering string diagrams and net
dynamics. Compositional systems: typed in PS, computed in Julia, drawn
in Hylograph — each layer playing its own instrument. No other
backend pairing in the family can tell this story.

Sidebar, same alignment at small scale: **StaticArrays.jl** gets its
speed from array *sizes as type parameters* — a PS type-level
`Matrix 3 4 Number` maps its type-level naturals directly onto Julia's.
Two type systems shaking hands across the seam, twice over (sizes,
units).

## What makes these "attractive" rather than bindings

- The PS types add real safety MTK/Catlab lack statically (rows for
  state spaces and schemas, phantom units, regions for handle
  lifetime/placement).
- The Julia side runs at full native speed because nothing hot crosses
  the seam — staging preserves specialization.
- The same typed API deploys in-process (Jurist) and as a leaf service
  (BEAM-coordinated), per the project-219 topology.
- Every piece feeds Hylograph: handles → sampled frames → declarative
  visualization. The library family is the missing middle of the
  compute-leaf thesis.

Suggested order: Tier 1 (proves typed handles), then the Tier-2
`NumExpr`/`SystemSpec` core with the Lorenz keystone, then
DynamicalSystems, then Catlab when the appetite arrives.

## Future: sizes and refinements (Liquid-Haskell-flavored)

**Sizes are nearly free, and they're performance facts.** PS has
type-level `Int` arithmetic (`Prim.Int.Add`/`Mul`/`Compare`, 0.15+) and
prior art in `purescript-fast-vect`. Sized `Vec n` / `Matrix m n` over
the Tier-1 handles is library work, not research. The deep alignment:
StaticArrays.jl gets its speed from sizes as *type parameters* — a PS
type-level `n` doesn't erase at the seam, it becomes the `N` in
`SMatrix{M,N,Float64}` and Julia specializes per size. On JS, sized
types are safety; on this backend they are **transmitted performance
information**.

**Refinements: proof-carrying handles.** No SMT pass in purs, so
LH-style predicates can't be discharged statically — but the seam
offers a different mechanism: Julia computes the certificate once at
the boundary, PS records it in a phantom and never re-checks:

```purescript
cholesky :: forall h n. Matrix h n n -> JuliaST h (Maybe (Checked PosDef (Matrix h n n)))
solveSPD :: forall h n. Checked PosDef (Matrix h n n) -> Vec h n -> JuliaST h (Vec h n)
```

A successful factorization *is* the positive-definiteness evidence;
sortedness, simplex membership, non-singularity follow the same shape.
IntervalArithmetic.jl upgrades "checked numerically" to "rigorously
enclosed" (`Certified a`). Where LH discharges obligations with Z3 at
compile time, this discharges them with Julia at the seam, once, with
the type system preventing any path that skips the check.

**Speculative rung**: because Tier-2 programs are `NumExpr` ASTs, a
refinement *checker* can itself be a leaf service — interval
arithmetic over the AST proving e.g. "this RHS preserves positivity on
this domain" before the solver runs. Static-ish checking, outsourced
to the runtime that is good at arithmetic.
