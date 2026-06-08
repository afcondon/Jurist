# FFI for Data.STNumberVector  (Tier-1 typed handles)
#
# STNumberVector h  ==  a Julia Vector{Float64} (mutable, contiguous, BLAS-ready).
# ST h a            ==  a zero-argument thunk (same calling convention as
#                       Control.Monad.ST / Effect: the action is `() -> ...`).
#
# The whole point of Tier 1: the cargo is Float64, not Any, so LinearAlgebra
# and BLAS specialize. Nothing in the hot path crosses the PS<->Julia seam —
# each operation is one FFI call over the entire vector.
import LinearAlgebra

new(n) = () -> Base.zeros(Base.Float64, n)
thaw(arr) = () -> Base.Float64[Base.Float64(x) for x in arr]
freeze(v) = () -> Any[x for x in v]
length(v) = () -> Base.length(v)

# 0-based PS index -> 1-based Julia index at the boundary.
read(v) = i -> () -> v[i + 1]
write(v) = i -> x -> () -> (v[i + 1] = x; nothing)

dot(x) = y -> () -> LinearAlgebra.dot(x, y)
axpy(alpha) = x -> y -> () -> (LinearAlgebra.axpy!(alpha, x, y); nothing)
scale(alpha) = x -> () -> (LinearAlgebra.rmul!(x, alpha); nothing)
offset(c) = x -> () -> (x .+= c; nothing)
expV(x) = () -> (x .= Base.exp.(x); nothing)
clampV(lo) = hi -> x -> () -> (Base.clamp!(x, lo, hi); nothing)
sumNum(x) = () -> Base.sum(x)
normL2(x) = () -> LinearAlgebra.norm(x)
