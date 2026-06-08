# FFI for Data.STMatrix  (Tier-1 typed handles, matrices)
#
# STMatrix h  ==  a Julia Matrix{Float64} (column-major, LAPACK/BLAS-ready).
# ST h a      ==  a zero-argument thunk.
#
# Representation independence: results that are PureScript ADTs (Maybe) or
# records are NOT built by hardcoding their runtime shape. The PS side hands
# us the constructors / record-builder as ordinary (already-compiled) Julia
# closures; we call them. The whole computation still completes in one go on
# the Julia runtime — those closures live here too. Only the irreducible
# primitive contracts (Float64, Vector, thunk) and handed-in functions cross
# the seam.
import LinearAlgebra

new(r) = c -> () -> Base.zeros(Base.Float64, r, c)
identityMatrix(n) = () -> Base.Matrix{Base.Float64}(LinearAlgebra.I, n, n)

fromRows(rows) = () -> begin
    nr = Base.length(rows)
    nc = nr == 0 ? 0 : Base.length(rows[1])
    m = Base.zeros(Base.Float64, nr, nc)
    for i in 1:nr
        ri = rows[i]
        for j in 1:nc
            m[i, j] = Base.Float64(ri[j])
        end
    end
    m
end

freeze(a) = () -> begin
    nr, nc = Base.size(a)
    Any[Any[a[i, j] for j in 1:nc] for i in 1:nr]
end

rows(a) = () -> Base.size(a, 1)
cols(a) = () -> Base.size(a, 2)

scaleM(alpha) = a -> () -> (LinearAlgebra.rmul!(a, alpha); nothing)
transpose(a) = () -> Base.permutedims(a)
mulMV(a) = x -> () -> a * x
mul(a) = b -> () -> a * b
det(a) = () -> LinearAlgebra.det(a)
solve(a) = b -> () -> a \ b

# record result: builder (mk l u p) handed in from PureScript.
luImpl(mk) = a -> () -> begin
    f = LinearAlgebra.lu(a)
    p0 = Base.Int[pi - 1 for pi in f.p]          # 0-based permutation for PS
    ((mk(Base.Matrix(f.L)))(Base.Matrix(f.U)))(p0)
end

# Maybe result: Just / Nothing handed in from PureScript.
choleskyImpl(just) = nothing_ -> a -> () -> begin
    f = LinearAlgebra.cholesky(LinearAlgebra.Symmetric(a); check = false)
    LinearAlgebra.issuccess(f) ? just(Base.Matrix(f.U)) : nothing_
end
