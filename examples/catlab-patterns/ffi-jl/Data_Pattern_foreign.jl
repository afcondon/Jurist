# FFI for Data.Pattern — Tier-3, Catlab homomorphism search.
#
# PureScript hands across a graph and a pattern as edge-lists (0-based). Both
# become Catlab `Graph` ACSets; `homomorphisms(P, G; monic=true)` finds every
# injective occurrence of the pattern in the graph — subgraph matching as a
# universal-algebra computation, generic over the schema. Each match is the
# pattern→graph vertex map.
#
# Qualified library calls throughout — this file is `include`d inside the
# generated `Data_Pattern` module. Catlab is 1-based; PureScript is 0-based, so we
# add 1 on the way in and subtract 1 on the way out.

import Catlab   # bind `Catlab`; submodules referenced as Catlab.Graphs / .CategoricalAlgebra

function _graph(n, srcs, tgts)
    g = Catlab.Graphs.Graph(Base.Int(n))
    Catlab.Graphs.add_edges!(g,
        [Base.Int(s) + 1 for s in srcs],
        [Base.Int(t) + 1 for t in tgts])
    g
end

# matchesJ gn gsrc gtgt pn psrc ptgt : Effect (Array (Array Int))
#   -> one entry per injective match; each a 0-based pattern-vertex → graph-vertex map
matchesJ(gn) = gsrc -> gtgt -> pn -> psrc -> ptgt -> () -> begin
    G = _graph(gn, gsrc, gtgt)
    P = _graph(pn, psrc, ptgt)
    homs = Catlab.CategoricalAlgebra.homomorphisms(P, G; monic = true)
    out = Base.Any[]
    for h in homs
        Base.push!(out, Base.Any[Base.Int(v) - 1 for v in Base.collect(h[:V])])
    end
    out
end

# writeTextJ path content : Effect Unit
writeTextJ(path) = content -> () -> begin
    Base.open(path, "w") do io
        Base.write(io, content)
    end
    Base.nothing
end
