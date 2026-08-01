# Effect values are zero-argument closures (ADR-0001), so `nowNs` must BE a
# closure, not a function that returns the time when called with no arguments.
nowNs = () -> Float64(Base.time_ns())

# Effect, so: a zero-argument closure.
flushOut = () -> (Base.flush(Base.stdout); nothing)

ffiInc(x) = x + 1

# `init` matters: PS `Array Int` can be empty, and Base.sum of an empty
# Vector{Any} has no zero to fall back on.
ffiSumArray(xs) = Base.sum(xs; init = 0)
