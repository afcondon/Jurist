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

Background and the wider units landscape: `docs/units-and-dimensions.md`.
