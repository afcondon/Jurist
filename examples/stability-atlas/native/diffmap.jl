# Where do the polyglot and ecosystem grids disagree? A number like "3.67 %"
# is not a finding until you know whether it is scattered or structured.
using HTTP, JSON3, Statistics
spec = (tag="RequestSweep", aMin=0.30,aMax=0.85,eMin=0.0,eMax=0.35,
        cols=120,rows=75,horizonPeriods=150.0,mu=9.54e-4,withFli=false)
function grid(port)
    g = Dict{Int,Vector{Float64}}()
    HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
        HTTP.WebSockets.send(ws, JSON3.write(spec))
        for raw in ws
            m = JSON3.read(String(raw))
            if m.tag == "SweepRows"
                for (i,r) in enumerate(m.rows); g[m.rowStart+i-1] = Float64.(r); end
            elseif m.tag == "SweepDone"; break; end
        end
    end
    g
end
p = grid(3210); e = grid(3213)
da = (0.85-0.30)/119; de = (0.35-0.0)/74
diffs = NamedTuple[]
for r in 0:74, c in 1:120
    d = abs(p[r][c]-e[r][c])
    d == 0.0 && continue
    push!(diffs, (a=0.30+da*(c-1), ecc=de*r, pv=p[r][c], ev=e[r][c],
                  flip=(p[r][c]>=1.0) != (e[r][c]>=1.0)))
end
println("disagreeing pixels: ", length(diffs), " of 9000")
println("  eccentricity: median ", round(median([d.ecc for d in diffs]),digits=3),
        "   vs grid median 0.175")
println("  of those, both LOST (differ only in when): ",
        count(d -> d.pv<1.0 && d.ev<1.0, diffs))
println("  flipping survived<->lost: ", count(d->d.flip, diffs))
println()
println("  by eccentricity band (disagreeing / total in band):")
for lo in 0.0:0.05:0.30
    hi = lo+0.05
    inband = count(d -> lo <= d.ecc < hi, diffs)
    rowsin = count(r -> lo <= de*r < hi, 0:74) * 120
    println("    e in [", lo, ",", round(hi,digits=2), ")  ",
            lpad(inband,4), " / ", lpad(rowsin,4), "   ",
            lpad(round(100*inband/max(rowsin,1),digits=1),5), " %")
end
println()
println("  semi-major axis of disagreeing pixels, by 3:1 / 5:2 / 7:3 / 2:1 resonance")
for (nm,a0) in (("2:1",0.6300),("7:3",0.5674),("5:2",0.5443),("3:1",0.4807))
    near = count(d -> abs(d.a - a0) < 0.02, diffs)
    println("    ", nm, " at a=", a0, ": ", lpad(near,4), " within +/-0.02")
end
