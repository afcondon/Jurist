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

**Pattern: staging.** PureScript's own superpower starts one level
below the AST: **algebraic data types** themselves are the precision
instrument — they make illegal states unrepresentable, so a description
is *correct by construction* before any interpretation runs on it. The
AST-building idioms (tagless final, free structures, row types — the
HATS sensibility) are what you get when you point that precision at
*computations*; the same exactness that rules out a malformed `Maybe`
rules out a malformed `NumExpr`. (PureScript's Prelude typeclasses give
that data a principled algebra to be manipulated through — less central
to the backend story, where dictionaries are just `Dict{String,Any}`,
but part of why authoring the descriptions is pleasant.) So:

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
- **Units**: phantom units on `NumExpr` map onto Julia's dimension
  types — the same invariant encoded in both type systems, checked
  twice, erased nowhere. Rich enough to be its own library; see
  "Units: dimension-aware PureScript across the seam" below.
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

## Units: dimension-aware PureScript across the seam

The most self-contained of these ideas, and a genuine *extension of
PureScript's domain* rather than a numeric convenience: a unit-aware
`Quantity` whose dimensions live in phantom types, staged across the
seam onto Julia's mature units stack. PureScript has no units ecosystem
of its own worth the name; Julia's is one of the best anywhere, and the
reason it's good is the reason the seam works — units there are
*type-level and erase at compile time*, not a runtime tax.

The Julia side offers a revealing fork, and it's the **same fork as the
sizes section below**:

- **[Unitful.jl](https://painterqubits.github.io/Unitful.jl/)** encodes
  dimensions in the *type parameters* of a `Quantity`. `1.0u"m"` and
  `1.0u"s"` are distinct types; `2.0u"m" + 3.0u"m"` compiles to the
  identical machine code as `2.0 + 3.0` (the unit bookkeeping erases
  entirely under specialization), while `2.0u"m" + 3.0u"s"` fails to
  find a method — dimensional analysis as type unification. It also
  models *affine* quantities correctly (°C/°F have offsets: `20°C + 5K`
  is fine, `20°C + 5°C` is not), the case most units libraries botch.
  Companions stack: **Measurements.jl** carries linear-propagated
  uncertainty (`(5.0 ± 0.1)u"m"`).
- **[DynamicQuantities.jl](https://github.com/SymbolicML/DynamicQuantities.jl)**
  stores dimensions as *values* in a fixed struct. It exists because
  Unitful's type-parameter approach causes compile-time blowup and
  type-instability in large symbolic/ML pipelines (it's a SciML/
  SymbolicML project). Cheaper, more flexible, weaker static guarantee.

That is exactly the static-vs-dynamic axis of the sizes work: push the
invariant into the type system (max safety, max specialization,
compile cost, instability if the value isn't statically known) or keep
it as runtime data. The PS-face design inherits the fork cleanly:

```purescript
foreign import data Quantity :: Dimension -> Type -> Type
-- Dimension is a type-level encoding (length·time⁻¹, …) built from
-- Prim type-level naturals — the L^a M^b T^c… exponent vector.

(.+.) :: forall d a. Semiring a => Quantity d a -> Quantity d a -> Quantity d a
(.*.) :: forall d e a. Semiring a => Quantity d a -> Quantity e a -> Quantity (Mul d e) a
```

Two landing targets across the seam, chosen by what PS knows
statically:

- **Static dimensions** (the common case — you wrote `m/s` in the
  eDSL): the PS phantom *becomes* Unitful's type parameter. Two type
  systems shaking hands; the invariant is checked on the PS side, again
  on the Julia side, and erased on both. This is the strongest version
  of the doc's whole thesis at the smallest scale.
- **Dynamic dimensions** (units read from data, where PS can't know
  them either): lower to DynamicQuantities, where dimensions are
  runtime values on both sides.

The dimension algebra is real PureScript work, not research: type-level
`Int` arithmetic (`Prim.Int.Add`/`Mul` for composing exponent vectors
on `.*.`/`./.`, `Compare` for nothing here but present) already ships,
and the encoding is a short row or seven-slot nat tuple (the SI base
dimensions). It's the same type-level-naturals machinery the sizes
section leans on — which is why the two belong side by side.

Where it pays off beyond safety: **SciML already checks dimensional
consistency on the equations of a ModelingToolkit system.** So a
unit-typed Tier-2 `SystemSpec` doesn't just annotate — its units flow
into MTK and are validated against the model MTK builds, then carried
through the solve and into the `SolutionHandle`. The PS types say what
the axes of the phase space *mean*; Julia confirms the dynamics respect
that meaning; the visualization can label axes from the same source of
truth. Units are the cheapest rung of the "descriptions across" ladder
and a good first library to actually write.

### Is uncertainty a monad? (and why it rides the eDSL path)

The neighbouring Julia idea — **Measurements.jl**, `5.0 ± 0.1` with
correlation-aware propagation — tempts you to reach for a monad. It's
worth being precise about why that instinct is half right, because the
answer says *which* path the library takes.

Two different things get conflated:

- **Full probability distributions are a monad** — the Giry/distribution
  monad: `pure` is a point mass, `bind` is "sample the first, feed it to
  the second, marginalize." This is the foundation of every PPL, and in
  this doc it's the **Turing.jl** bullet — a free-monad PPL built in PS,
  sampled by NUTS on the leaf. *That* is where the monad lives, and where
  a free monad in PureScript genuinely fits.
- **Measurements.jl is not that monad.** It is *first-order linear error
  propagation*: `f(x ± σ) ≈ f(x) ± |f'(x)|·σ`, with tagged independent
  sources so `a - a = 0 ± 0`. Structurally that's dual numbers /
  forward-mode AD carrying a covariance — a commutative *ring*, and a
  lossy first-order shadow of the distribution monad.

The obstruction is sharp and instructive. To be even a `Functor` you'd
need `map :: (a -> b) -> Uncertain a -> Uncertain b`, but propagation
needs `f'`, not `f` — an **opaque** `a -> b` doesn't expose the
derivative. Measurements.jl only works because it propagates through the
*registered primitives whose derivatives it knows*, never through a
black-box function. That is precisely the **callback anti-pattern**
restated in type-class terms: you can't push an arbitrary closure
through an uncertain value for the same reason you can't hand Julia a
per-evaluation PS closure — the host needs the *structure* (the
derivative, the symbolic form), not a function pointer.

So uncertainty is not something you thread as a monad in PS-land; it is
a **property the `NumExpr` eDSL preserves on the Julia side**, because
the AST exposes the structure AD needs. It composes with units exactly
as it does in Julia (`(5.0 ± 0.1)u"m"`) — both are dispatch overlays on
the numeric tower riding the same staging path. The genuinely monadic
sibling is the PPL one rung up, of which Measurements is the cheap
linearization.

This is the unifying observation for the whole section: **units, sizes,
and uncertainty are the same move** — a type-level invariant whose hot
propagation happens on the Julia side because the eDSL exposes
structure. Units and sizes erase to nothing; uncertainty erases to a
first-order ring computation; the closure-based versions of all three
hit the same wall. (Prior art: Justin Le's Haskell `uncertain` package
does this forward propagation and pointedly is *not* a monad; the
distribution-monad side is `monad-bayes`.)

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
