# Julia-hosted PureScript: the REPL direction, and what the slider shows

*Probed live 2026-06-11. Companion to `docs/units-and-dimensions.md`; the
"before/after slider" concept is Andrew's — one diagram, two views of the same
seam.*

## The probe: loading compiled PureScript into a Julia session

purejl output is ordinary Julia source, so dynamic loading is just:

```julia
include("output-jl/loader.jl")
```

Verified receipts (examples/dimensioned and examples/numexpr-edsl/julia):

```
Main_.period                     →  1.6300923853906788     (PS top-level values readable)
Data_Quantity.value(p)           →  1.6300923853906788     (curried unary application)
Data_Quantity.qAdd(a)(b)         →  2.35                   (PS functions from the REPL)
prettySIJ(v)(0)(0)(1)()          →  "1.6300923853906788 s" (Effect = thunk, force with ())
include("…loader.jl") again      →  hot-reload works       (edit → purejl → re-include)
```

Cross-language higher-order functions are free — both sides represent
functions as plain closures. A PS AST built from the REPL with the real
constructors, run through the PS **reference interpreter** with a **Julia
lambda** as the environment:

```julia
expr = Data_NumExpr.Mul(num(10.0))(Data_NumExpr.Add(var("x"))(num(2.0)))
Data_NumExpr.render(expr)                                   # "(10.0 * (x + 2.0))"
Data_NumExpr.eval_(name -> name == "x" ? 4.0 : 0.0)(expr)   # 60.0
expr   # ("Mul", ("Lit", 10.0), ("Add", ("Var", "x"), ("Lit", 2.0)))  ← legible tag-tuple
```

Calling-convention cheat sheet (from the Julia side): curried unary closures,
`f(x)(y)`; Effects are zero-arg thunks, force with `()`; ADTs are tag-tuples
(tag at `[1]`, fields from `[2]`); records are `Dict{String,Any}`; PS `Main`
compiles to `Main_`; PS `eval` to `eval_`. Gotcha: lowercase `add`/`mul` in
generated `Data_NumExpr` are Number-semiring specializations — the
constructors are the capitalized bindings.

**The caveat that shapes everything below**: the type discipline does NOT
follow you into the REPL. Calls from Julia are untyped; the guarantees are
properties of the *compiled artifact*. So the compelling uses are ones where
the PS artifact is constructed and typechecked ahead of time and Julia is the
host/executor — not free-form PS-from-Julia. Also: typeclass-constrained
functions compile to dictionary-passing form (awkward raw); the REPL-friendly
surface is monomorphic bindings, which examples could deliberately export.

## The slider: two views of one seam

The two views are the same architecture with the spotlight moved. PureScript
always owns the descriptions and the types; what flips is **who holds the
REPL** — which side is the host process.

- **View 1 (today's demos)**: a PureScript program is the host; Julia is the
  production semantics. Descriptions across, handles and receipts back.
- **View 2 (this direction)**: a Julia session/app is the host; the compiled
  PureScript is loaded as a *typed library* — contracts, queries, codecs,
  reference interpreters — whose well-formedness was settled at compile time.

## Candidate compelling reasons (ranked)

1. **Typed wire contract — the Servant-shaped one.** One PS module defines
   the protocol (request/response ADTs + codecs). Compile it with the JS
   backend for the browser/Node end AND with purejl for the Julia service
   end. The same type governs both endpoints; schema drift is structurally
   impossible. This is "illegal states unrepresentable across runtimes" made
   operational, and our differential-testing muscle can prove it the Jurist
   way: round-trip byte-identical receipts; an ill-formed payload rejected
   identically (same error text) on both ends. Strongest candidate — it is
   the thesis, not an application of it.
2. **Typed SQL / query descriptions (the Om-shaped one).** Schema-typed query
   builders in PS — a query that typechecks is well-formed against that
   schema — executed by Julia against DuckDB.jl/SQLite.jl, results landing in
   DataFrames. Speaks directly to Julia's data-science audience, and to the
   home DuckDB world (CodeExplorer, larder). The queries are built and
   checked in PS modules; Julia hosts and executes.
3. **Verified components as plain Julia source.** The gnarly invariant-heavy
   parts of a Julia app — parsers, protocol state machines, rule engines,
   pricing/eligibility logic — written in PS (ADTs, exhaustive matching,
   totality), shipped as a directory of `.jl` files. No FFI ceremony, no
   binary boundary: `include` and call.
4. **The reference oracle in-session.** PS `eval`/`integratePure` — the
   executable specification — loaded next to the fast native implementation;
   Julia property-tests against it interactively. Cheap (works today,
   receipts above) and pairs with Julia's warm-session culture: keep MTK
   loaded, hot-reload the PS in seconds.
5. **Hylograph rendering from Julia.** Julia computes, calls a PS pure
   SVG-printer (HATS-shaped description → SVG string) for typed,
   Swiss-quality figures. Charming crossover, but Makie is strong competition
   — garnish, not the main course. (Would need a DOM-free HATS render path.)

## If pursued, the artifact list

- `jurist-repl.jl` helper: `jurist_reload()` (purejl + re-include) plus
  `ps(f, args...)` uncurry and `run!(eff)` conveniences.
- A deliberate monomorphic "REPL surface" per example (exported, documented).
- The slider diagram on the site: View 1 = the existing demos; View 2 = the
  typed-contract demo (one PS module, two runtimes, byte-identical codec
  receipts).
- Possibly a Pluto notebook showcase — reactive cells over PS descriptions.
