# FFI for Data.Migration — Tier-3, Catlab functorial data migration.
#
# A Δ (pullback) migration along the in_mod functor: a migration functor
# SchGraph → SchCode sends the plain graph's V↦Module, E↦Call, and src/tgt to the
# composite path Call→Func→Module. `migrate(Graph, codegraph, …)` then aggregates
# every function-level call into a module-level edge — the module dependency graph
# derived functorially, returned as a plain Catlab Graph.
#
# `using Catlab` so @present/@acset_type resolve; 1-based Catlab vs 0-based PS.

using Catlab, Catlab.Graphs, Catlab.CategoricalAlgebra

@present SchCode(FreeSchema) begin
    Module::Ob
    Func::Ob
    Call::Ob
    in_mod::Hom(Func, Module)
    src::Hom(Call, Func)
    tgt::Hom(Call, Func)
end
@acset_type CodeGraph(SchCode, index = [:in_mod, :src, :tgt])

# The migration functor SchGraph → SchCode (built once at include time).
_Vg, _Eg, _srcg, _tgtg = generators(SchGraph)
_Mod, _Fn, _Cl, _inmod, _srcc, _tgtc = generators(SchCode)
_CCode = FinCat(SchCode)
_FOb = Base.Dict(_Vg => _Mod, _Eg => _Cl)
_FHom = Base.Dict(
    _srcg => Path(_CCode, [_srcc, _inmod]),   # graph src ↦ Call→Func→Module
    _tgtg => Path(_CCode, [_tgtc, _inmod]),   # graph tgt ↦ Call→Func→Module
)

function _cg(nmod, fnmod, csrc, ctgt)
    g = CodeGraph()
    add_parts!(g, :Module, Base.Int(nmod))
    add_parts!(g, :Func, Base.length(fnmod); in_mod = [Base.Int(m) + 1 for m in fnmod])
    add_parts!(g, :Call, Base.length(csrc);
        src = [Base.Int(s) + 1 for s in csrc], tgt = [Base.Int(t) + 1 for t in ctgt])
    g
end

# moduleGraphJ nmod fnmod csrc ctgt : Effect (Array (Array Int))
#   -> one [srcMod, tgtMod] (0-based) per call, via the Δ migration.
moduleGraphJ(nmod) = fnmod -> csrc -> ctgt -> () -> begin
    g = _cg(nmod, fnmod, csrc, ctgt)
    mg = migrate(Graph, g, _FOb, _FHom; homtype = :path)
    out = Base.Any[]
    for e in edges(mg)
        Base.push!(out, Base.Any[src(mg, e) - 1, tgt(mg, e) - 1])
    end
    out
end

writeTextJ(path) = content -> () -> begin
    Base.open(path, "w") do io
        Base.write(io, content)
    end
    Base.nothing
end
