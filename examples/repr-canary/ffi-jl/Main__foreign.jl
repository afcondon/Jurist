# Representation canary shim (ADR-0001 / ADR-0002).
#
# White-box assertions over the codegen's runtime encoding. Each function is
# handed a COMPILED PureScript value and checks its raw Julia shape, aborting
# the run if the shape has drifted from what hand-written FFI assumes. This is
# the conscious-update tripwire ADR-0002 promises: a representation change can
# no longer break user shims silently — it breaks THIS, loudly, first.

function _assert(cond, msg)
    cond || Base.error("REPRESENTATION DRIFT: " * msg)
    "ok"
end

# Maybe (Just x)  ==  ("Just", x)   — tag at [1], field at [2] (1-based).
checkJust(m) = _assert(
    m isa Base.Tuple && Base.length(m) == 2 && m[1] == "Just" && m[2] == 7,
    "Just expected (\"Just\", x), got " * Base.repr(m))

# Maybe Nothing  ==  ("Nothing",)   — nullary constructor is a 1-tuple value.
checkNothing(m) = _assert(
    m isa Base.Tuple && Base.length(m) == 1 && m[1] == "Nothing",
    "Nothing expected (\"Nothing\",), got " * Base.repr(m))

# Record  ==  Dict{String,Any} keyed by field name.
checkRecord(r) = _assert(
    r isa Base.AbstractDict && r["a"] == 1 && r["b"] == 2,
    "record expected Dict{String,Any} keyed by field, got " * Base.repr(r))

# Newtype is erased: no wrapper, so the value IS the underlying Int.
checkNewtypeErased(w) = n -> _assert(
    w === n,
    "newtype expected identity (no wrapper), got " * Base.repr(w))

# Effect a  ==  a zero-argument thunk (callable, not yet run).
checkEffectThunk(eff) = _assert(
    eff isa Base.Function && Base.applicable(eff),
    "Effect expected a 0-arg thunk, got " * Base.repr(eff))

# Array  ==  a Julia Vector (1-based; FFI bridges the 0-based PS API).
checkArrayVector(xs) = _assert(
    xs isa Base.AbstractVector && Base.length(xs) == 3 && xs[1] == 10,
    "Array expected a Vector, got " * Base.repr(xs))
