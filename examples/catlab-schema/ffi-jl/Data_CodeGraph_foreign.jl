# FFI for Data.CodeGraph — Tier-3, Catlab typed-schema homomorphism search.
#
# The schema (Module / Func / Call with the typed morphisms in_mod, src, tgt) is
# declared here with @present / @acset_type. PureScript hands across a typed code
# graph and a typed motif (both instances of this schema, as flat arrays);
# `homomorphisms(P, G; monic=true)` finds every injective occurrence, respecting
# the typing — so a motif whose functions live in distinct pattern-modules matches
# only cross-module structure. Each match returns the motif's Func map and Module
# map.
#
# `using Catlab` (not qualified) so the @present / @acset_type macros resolve;
# none of Catlab's exports clash with this module's PureScript-defined names.
# 1-based Catlab vs 0-based PureScript: +1 in, -1 out.

using Catlab, Catlab.CategoricalAlgebra

@present SchCode(FreeSchema) begin
    Module::Ob
    Func::Ob
    Call::Ob
    in_mod::Hom(Func, Module)
    src::Hom(Call, Func)
    tgt::Hom(Call, Func)
end
@acset_type CodeGraph(SchCode, index = [:in_mod, :src, :tgt])

function _cg(nmod, fnmod, csrc, ctgt)
    g = CodeGraph()
    add_parts!(g, :Module, Base.Int(nmod))
    add_parts!(g, :Func, Base.length(fnmod); in_mod = [Base.Int(m) + 1 for m in fnmod])
    add_parts!(g, :Call, Base.length(csrc);
        src = [Base.Int(s) + 1 for s in csrc], tgt = [Base.Int(t) + 1 for t in ctgt])
    g
end

# matchesJ gnm gfm gcs gct  pnm pfm pcs pct : Effect (Array (Array Int))
#   -> per match: [funcMap…  moduleMap…] (0-based)
matchesJ(gnm) = gfm -> gcs -> gct -> pnm -> pfm -> pcs -> pct -> () -> begin
    G = _cg(gnm, gfm, gcs, gct)
    P = _cg(pnm, pfm, pcs, pct)
    homs = homomorphisms(P, G; monic = true)
    out = Base.Any[]
    for h in homs
        fm = [Base.Int(v) - 1 for v in Base.collect(h[:Func])]
        mm = [Base.Int(v) - 1 for v in Base.collect(h[:Module])]
        Base.push!(out, Base.vcat(fm, mm))
    end
    out
end

writeTextJ(path) = content -> () -> begin
    Base.open(path, "w") do io
        Base.write(io, content)
    end
    Base.nothing
end
