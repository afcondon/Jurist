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

# Maybe (Just x)  ==  PSData("Just", 1, x, …)   — tag at [1], field at [2]
# (1-based). One non-parametric type at every depth (ADR-0001, 2026-10).
checkJust(m) = _assert(
    m isa PSData && Base.length(m) == 2 && m[1] == "Just" && m[2] == 7,
    "Just expected PSData with tag \"Just\" and one field, got " * Base.repr(m))

# Maybe Nothing  ==  PSData("Nothing", 0, …)   — a nullary constructor is a value.
checkNothing(m) = _assert(
    m isa PSData && Base.length(m) == 1 && m[1] == "Nothing",
    "Nothing expected PSData with tag \"Nothing\" and no fields, got " * Base.repr(m))

# Record  ==  PSRecord over a NamedTuple (ADR-0012). A record of scalars is
# plain bits, with each field at its own type. It is still an AbstractDict
# keyed by field name, which is what hand-written FFI reads it through.
checkRecord(r) = _assert(
    r isa PSRecord && Base.isbits(r) && r isa Base.AbstractDict &&
        r["a"] == 1 && r["b"] == 2 && Base.haskey(r, "a") && !Base.haskey(r, "c") &&
        Base.copy(r) isa Base.Dict{Base.String, Any},
    "record expected an isbits PSRecord readable by field name, got " * Base.repr(r))

# A record of numbers holding a record of numbers is plain bits all the way
# down: this is what lets a numeric loop over records run without allocating.
checkRecordBits(r) = _assert(
    r isa PSRecord && Base.isbits(r) && r["p"]["x"] == 1.0 && r["m"] == 3.0,
    "record of numbers expected to be plain bits, got " * Base.repr(Base.typeof(r)))

# A record's type must not depend on how deep the value is (ADR-0012): a
# field that is a closure is held as `Any`.
checkSameType(a) = b -> _assert(
    Base.typeof(a) === Base.typeof(b),
    "record type grew with depth: " * Base.repr(Base.typeof(a)) * " against " * Base.repr(Base.typeof(b)))

# Newtype is erased: no wrapper, so the value IS the underlying Int.
checkNewtypeErased(w) = n -> _assert(
    w === n,
    "newtype expected identity (no wrapper), got " * Base.repr(w))

# Effect a  ==  callable with no arguments, not yet run: a bare 0-arg closure
# from pure/map/a shim, or a PSEff box from bind (ADR-0001, 2026-10). FFI must
# run an effect by calling it, never by testing `isa Function`.
checkEffectThunk(eff) = _assert(
    (eff isa Base.Function || eff isa PSEff) && Base.applicable(eff),
    "Effect expected a 0-arg callable, got " * Base.repr(eff))

# Array  ==  a Julia Vector (1-based; FFI bridges the 0-based PS API).
checkArrayVector(xs) = _assert(
    xs isa Base.AbstractVector && Base.length(xs) == 3 && xs[1] == 10,
    "Array expected a Vector, got " * Base.repr(xs))
