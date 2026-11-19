# FFI for Data.NumExpr (core) — the reference interpreter's transcendental
# primitives. purejl resolves Data.Number.sin/pow via its builtin shim, but the
# core module declares its OWN math foreigns so the same source compiles on the
# JS and BEAM backends too; this shim backs them on purejl with Base.*.
numPow(x) = y -> Base.Float64(x) ^ Base.Float64(y)
numSin(x) = Base.sin(x)
numCos(x) = Base.cos(x)
numExp(x) = Base.exp(x)
numLog(x) = Base.log(x)
numSqrt(x) = Base.sqrt(x)
