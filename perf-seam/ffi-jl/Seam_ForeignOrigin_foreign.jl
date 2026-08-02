# Julia's alternative representations of "a real number".
#
# Julia has more of these than any other runtime we target, and they are not
# exotic — Float32 is the default in imaging, GPU and ML libraries, Rational
# comes out of exact-arithmetic code, BigFloat out of anything advertising
# arbitrary precision, and a great many functions return Int where the caller
# reads a Number. An FFI signature saying `-> Number` cannot enforce any of it.
#
# `Base.string` renders each in ITS OWN notation, which is why the runtime's
# `_js_number_string` had to start with a coercion: it splits the mantissa on
# '.' and would otherwise produce "1//2" for a Rational and 0.1's digits for
# Float32(0.1), whose double is 0.10000000149011612.

representations = ["Float64", "Float32", "Rational", "BigFloat", "Integer"]

asRepresentation(name) = n -> begin
    if name == "Float64"
        n
    elseif name == "Float32"
        Base.Float32(n)
    elseif name == "Rational"
        # Exact: the fraction the double denotes, so widening it back is
        # lossless and the invariant is testable. BigInt because the default
        # `Rational(1.0e21)` overflows Int64's numerator and raises
        # InexactError — which is worth knowing but is not what is under test.
        Base.Rational{Base.BigInt}(n)
    elseif name == "BigFloat"
        Base.BigFloat(n)
    elseif name == "Integer"
        # Lossy on purpose. The invariant is about the value that ARRIVED, so
        # a representation that changes the value is still a fair test of it —
        # and an integer is what a Julia library is likeliest to hand back
        # where the signature promised a Number. BigInt rather than Int for
        # the same reason as above: `round(Int, 1.0e21)` overflows, and
        # `Base.string` renders every Integer subtype identically anyway, so
        # BigInt covers Int's behaviour without the range fight.
        Base.round(Base.BigInt, n)
    else
        Base.error("Seam.ForeignOrigin: unknown representation " * name)
    end
end

widen(n) = Base.Float64(n)

exitWith(code) = () -> Base.exit(code)
