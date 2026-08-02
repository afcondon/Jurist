# dimensioned — typed dimensional analysis, denoted into DynamicQuantities

A small typed language (`core/src/Data/Quantity.purs`) where the physical
dimension lives in the **type**: `Quantity mass length time` carries the
exponents as `Prim.Int` type-level integers. Multiplication adds exponents,
division subtracts them, square root halves them — all solved by the
compiler. `springK |+| bobMass` is not a runtime error; it **does not
compile**:

```
[ERROR] TypesDoNotUnify
  Could not match type 0 with type -2
  while trying to match type Quantity 1 0 0
    with type Quantity 1 0 -2
```

The Julia denotation (`Data.Quantity.Julia` + `ffi-jl/`) receives the
dimension as plain reflected exponents (`Data.Reflectable` — compiler-solved,
backend-agnostic) and does the runtime half via **DynamicQuantities**:
SI rendering, unit conversion, and independent enforcement of the same
algebra for anything the types can't see (a runtime conversion target):

```
period, raw value:        1.6300923853906788
rendered by Julia (SI):   1.6300923853906788 s
converted to ms:          1630.0923853906788 ms
converted to min:         0.02716820642317798 min
converted to m:           ✗ DimensionError: 1.6300923853906788 s and 1.0 m have incompatible dimensions
```

Run it:

```bash
spago build
stack exec purejl -- output output-jl
julia --project=julia-env output-jl/main.jl
```

## Frontend (`dimensions-viz/`) — where static knowledge ends

A static page that states the boundary this example is really about, in four
acts: the type system doing the dimensional algebra (with the verbatim `purs`
error for `meters 1.0 |+| seconds 2.0`), then the three places the types
**cannot** reach —

1. **the unit is chosen at runtime** — `inUnits "m"` is a string that could come
   from a dropdown or a URL, so only DynamicQuantities can refuse it;
2. **the equations are values** — `numexpr-edsl` increment 9 hands
   ModelingToolkit an ODE system assembled at run time from a `NumExpr` AST;
   changing the drag law from `c·v` to `c·v²` changes a *value*, so nothing
   recompiles and MTK is the only thing that can complain;
3. **the exponent is not an integer** — `Prim.Int` has no rationals, so
   `√(s)` is inexpressible and `qSqrt` rejects it (`√(s²) = s` is fine, which
   is why the pendulum period works).

It reads two generated files, one from each example:

```bash
cp dimensioned.js dimensions-viz/                    # this example
cp ../numexpr-edsl/julia/units.js dimensions-viz/    # numexpr-edsl increment 9
open dimensions-viz/index.html                       # no server needed
```

> The point is **not** that PureScript lacks dimensional types — it has them,
> at compile time, on every backend including the browser, which is stronger
> than what any runtime checker can offer. The point is the boundary: types
> check what you *write*; they cannot check what you *build*. That is the
> general shape of the seam, and this is the cleanest place to see it.

Background and the wider units landscape: `docs/units-and-dimensions.md`.
