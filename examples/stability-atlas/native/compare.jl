#!/usr/bin/env julia
#
# The stability atlas measured against two native references.
#
# One WebSocket client, three services, the same Atlas.Protocol messages to
# each. Every service is asked for the same sweeps; the returned grids are
# diffed pixel by pixel and the timings are attributed.
#
#   polyglot   service/            PureScript protocol on Julia, hand-rolled RK4
#   native     atlas_native.jl     Julia protocol, THE SAME hand-rolled RK4
#   ecosystem  atlas_ecosystem.jl  Julia protocol, OrdinaryDiffEq + root-found events
#
# What each comparison answers:
#
#   polyglot vs native      what the PureScript layer costs, with the
#                           arithmetic held bit-for-bit fixed. `poly_kernel /
#                           native_kernel` should read ~1.0 — that is the
#                           control that says the two harnesses really are
#                           running the same numerics.
#
#   polyglot vs ecosystem   `ecosystem_forgone` — the fifth ratio. The four in
#                           Grid Explorer all compare the SAME library call on
#                           both sides. The Atlas has no library call, so
#                           structural distortion reads ~1.0 no matter how far
#                           the exhibit sits from the ecosystem it claims to
#                           reach. This number is what can see that, and it is
#                           the only one here that can also answer whether the
#                           atlas is ACCURATE rather than merely reproducible.
#
# Usage — start the three services first (see native/README.md), then:
#
#   julia --project=. compare.jl                # the default scenarios
#   julia --project=. compare.jl --json         # machine-readable
#   julia --project=. compare.jl --full         # add the 240x150 sweeps
#
# Services that are not listening are reported and skipped, so this is useful
# with only the polyglot service up.

using HTTP
using JSON3
using Statistics

const SERVICES = [
    (name = "polyglot",  port = 3210),
    (name = "native",    port = 3212),
    (name = "ecosystem", port = 3213),
]

# The frontend's own preview and full specs (web/src/Atlas/App.purs) — the
# operating point a viewer actually sees, not a benchmark invented here.
preview(fli) = (tag = "RequestSweep",
    aMin = 0.30, aMax = 0.85, eMin = 0.0, eMax = 0.35,
    cols = 120, rows = 75, horizonPeriods = 150.0, mu = 9.54e-4, withFli = fli)

full(fli) = merge(preview(fli), (cols = 240, rows = 150))

# --- one sweep over one service ---------------------------------------------

"""
Send a RequestSweep and collect the painted grid plus wall clock.

Returns `(grid, wall_ms, elapsed_ms, blocks)` where `wall_ms` is measured by
this client (transport included, as the viewer experiences it) and
`elapsed_ms` is what the service reports for itself.
"""
function sweep(port::Int, spec)
    grid = Dict{Int, Vector{Float64}}()
    elapsed = NaN
    blocks = 0
    t0 = time_ns()
    HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
        HTTP.WebSockets.send(ws, JSON3.write(spec))
        for raw in ws
            msg = JSON3.read(String(raw))
            tag = msg.tag
            if tag == "SweepRows"
                blocks += 1
                for (i, row) in enumerate(msg.rows)
                    grid[msg.rowStart + i - 1] = Float64.(row)
                end
            elseif tag == "SweepDone"
                elapsed = Float64(msg.elapsedMs)
                break
            elseif tag == "ProtocolError"
                error("service on :$port returned ProtocolError: $(msg.message)")
            end
        end
    end
    wall = (time_ns() - t0) / 1.0e6
    (grid = grid, wall = wall, elapsed = elapsed, blocks = blocks)
end

listening(port) = try
    close(Sockets.connect("127.0.0.1", port)); true
catch
    false
end

using Sockets

# --- grid comparison ---------------------------------------------------------

"""
Pixel-by-pixel diff of two sweeps. Verdicts are rounded to 4 decimals by both
sides, so `identical` means bit-for-bit equal Float64s, not "close".
"""
function diff_grids(a, b)
    keys_a = sort(collect(keys(a)))
    keys_b = sort(collect(keys(b)))
    keys_a == keys_b || return (ok = false, reason = "row sets differ", n = 0)
    n = 0
    ndiff = 0
    maxabs = 0.0
    worst = nothing
    disagree_class = 0          # one says survived, the other says lost
    for r in keys_a
        ra, rb = a[r], b[r]
        length(ra) == length(rb) || return (ok = false, reason = "row $r length", n = n)
        for c in eachindex(ra)
            n += 1
            d = abs(ra[c] - rb[c])
            if d != 0.0
                ndiff += 1
                if (ra[c] >= 1.0) != (rb[c] >= 1.0)
                    disagree_class += 1
                end
                if d > maxabs
                    maxabs = d
                    worst = (row = r, col = c, a = ra[c], b = rb[c])
                end
            end
        end
    end
    (ok = true, n = n, ndiff = ndiff, maxabs = maxabs, worst = worst,
     disagree_class = disagree_class)
end

# Survived / lost split — the exhibit's headline picture in one number, and
# the smoke test the plan asks every exhibit for. A grid that is all-survived
# or all-lost is a green light, not an analysis.
function census(grid)
    vals = reduce(vcat, [grid[r] for r in sort(collect(keys(grid)))])
    survived = count(>=(1.0), vals)
    (n = length(vals), survived = survived, lost = length(vals) - survived,
     lostFrac = (length(vals) - survived) / length(vals))
end

# --- service-side split ------------------------------------------------------

"""
Read the `sweep-perf` diagnostic lines a service writes to stderr.

The wire's `elapsedMs` covers kernel AND the protocol-encode callback; the
split between them cannot be recovered from outside, so every service logs it.

Lines are matched to THIS scenario by `cols`/`rows`/`fli` and only then are the
last `n` — the repetitions just run — medianed, the same way the wall clock is.
Both halves of that are load-bearing. Taking the last `n` lines alone picks up
whichever scenario ran most recently, which silently reported a +FLI kernel
time against a non-FLI sweep. Taking a single line instead of medianing lets a
median wall clock be split by one run's parts, so the parts can exceed the
whole.
"""
function scenario_perf(logpath, spec, n::Int)
    isfile(logpath) || return nothing
    want = ("cols=$(spec.cols)", "rows=$(spec.rows)", "fli=$(spec.withFli)")
    lines = String[]
    for line in eachline(logpath)
        startswith(line, "sweep-perf") && all(w -> occursin(w, line), want) && push!(lines, line)
    end
    isempty(lines) && return nothing
    fields = Dict{String, Vector{Float64}}()
    for line in lines[max(1, end - n + 1):end], tok in split(line)
        parts = split(tok, "=")
        length(parts) == 2 || continue
        v = tryparse(Float64, parts[2])
        v === nothing || push!(get!(fields, parts[1], Float64[]), v)
    end
    Dict(k => median(v) for (k, v) in fields)
end

# --- driver ------------------------------------------------------------------

function scenario_name(spec)
    string(spec.cols, "x", spec.rows, spec.withFli ? " +FLI" : "")
end

function main()
    json_out = "--json" in ARGS
    do_full = "--full" in ARGS
    reps = 3

    logdir = get(ENV, "ATLAS_LOGDIR", "")
    logs = Dict(s.name => isempty(logdir) ? "" : joinpath(logdir, "atlas-$(s.name).log")
                for s in SERVICES)

    up = [s for s in SERVICES if listening(s.port)]
    down = [s.name for s in SERVICES if !(s in up)]
    isempty(down) || json_out ||
        println("not listening, skipped: ", join(down, ", "), "\n")
    isempty(up) && error("no atlas service is listening; see native/README.md")

    specs = do_full ?
        [preview(false), preview(true), full(false)] :
        [preview(false), preview(true)]

    results = []
    for spec in specs
        row = Dict{String, Any}("scenario" => scenario_name(spec))
        grids = Dict{String, Any}()
        for s in up
            runs = [sweep(s.port, spec) for _ in 1:reps]
            grids[s.name] = runs[end].grid
            perf = scenario_perf(logs[s.name], spec, reps)
            row[s.name] = Dict(
                "wallMs"    => median([r.wall for r in runs]),
                "elapsedMs" => median([r.elapsed for r in runs]),
                "blocks"    => runs[end].blocks,
                "kernelMs"  => perf === nothing ? nothing : get(perf, "kernel_ms", nothing),
                "emitMs"    => perf === nothing ? nothing : get(perf, "emit_ms", nothing),
                "census"    => census(runs[end].grid),
            )
        end
        row["diffs"] = Dict{String, Any}()
        if haskey(grids, "polyglot")
            for other in ("native", "ecosystem")
                haskey(grids, other) || continue
                row["diffs"][other] = diff_grids(grids["polyglot"], grids[other])
            end
        end
        push!(results, row)
    end

    if json_out
        JSON3.pretty(stdout, results)
        println()
        return
    end

    for row in results
        println("=" ^ 74)
        println("  ", row["scenario"], "   case: a in [0.30,0.85], e in [0.0,0.35], 150 periods")
        println("=" ^ 74)

        for s in up
            r = row[s.name]
            c = r["census"]
            print(rpad(s.name, 11))
            print("wall ", lpad(round(r["wallMs"], digits = 1), 8), " ms")
            print("   service ", lpad(round(r["elapsedMs"], digits = 1), 8), " ms")
            if r["kernelMs"] !== nothing
                print("  = kernel ", lpad(round(r["kernelMs"], digits = 1), 8),
                      " + encode ", lpad(round(r["emitMs"], digits = 1), 6))
            end
            println()
            println("           ", c.n, " px: ", c.survived, " survived, ",
                    c.lost, " lost (", round(100 * c.lostFrac, digits = 1), " %)")
        end

        println()
        for (other, d) in row["diffs"]
            if !d.ok
                println("  polyglot vs ", other, ": INCOMPARABLE (", d.reason, ")")
            elseif d.ndiff == 0
                println("  polyglot vs ", rpad(other, 10),
                        "IDENTICAL, all ", d.n, " pixels bit-for-bit")
            else
                println("  polyglot vs ", rpad(other, 10),
                        d.ndiff, "/", d.n, " pixels differ (",
                        round(100 * d.ndiff / d.n, digits = 2), " %), max |d| ",
                        round(d.maxabs, sigdigits = 3))
                println("           ", d.disagree_class,
                        " flip the survived/lost verdict",
                        d.worst === nothing ? "" :
                        string("; worst at row ", d.worst.row, " col ", d.worst.col,
                               ": ", d.worst.a, " vs ", d.worst.b))
            end
        end

        # Self-check before any ratio is printed. The service-side split comes
        # from a log, the wall clock from this process; if they are not the
        # same runs, the parts will not sum to the whole. That happened once —
        # a `converge.jl` run overlapping a `compare.jl` run put a +FLI kernel
        # time against a non-FLI sweep and made the polyglot service look
        # FASTER than native (0.79x). Contention and mismatched logs both show
        # up here, so say so rather than letting a ratio carry the damage.
        for s in up
            r = row[s.name]
            r["kernelMs"] === nothing && continue
            parts = r["kernelMs"] + r["emitMs"]
            if parts > 1.05 * r["elapsedMs"]
                println("  !! ", s.name, ": kernel+encode (", round(parts, digits = 1),
                        " ms) exceeds service elapsed (", round(r["elapsedMs"], digits = 1),
                        " ms).")
                println("     The log split and the timed runs are not the same runs — is",
                        " something else\n     hitting these services? Restart them, clear",
                        " the logs, and re-run alone.")
            end
        end

        # the ratios
        if haskey(row, "polyglot")
            p = row["polyglot"]
            println()
            if haskey(row, "native")
                n = row["native"]
                println("  architecture tax        ",
                        lpad(round(p["elapsedMs"] / n["elapsedMs"], digits = 2), 6), "x",
                        "   (polyglot / native, same kernel)")
                if p["kernelMs"] !== nothing && n["kernelMs"] !== nothing
                    println("  structural distortion   ",
                            lpad(round(p["kernelMs"] / n["kernelMs"], digits = 2), 6), "x",
                            "   (kernel vs kernel — the control; ~1.0 expected)")
                end
                if p["kernelMs"] !== nothing
                    println("  protocol share          ",
                            lpad(round(100 * p["emitMs"] / p["elapsedMs"], digits = 1), 6), " %",
                            "   (PureScript encode, of polyglot wall clock)")
                    println("                          ",
                            lpad(round(100 * n["emitMs"] / n["elapsedMs"], digits = 1), 6), " %",
                            "   (JSON3 encode, of native wall clock)")
                end
            end
            if haskey(row, "ecosystem")
                e = row["ecosystem"]
                println("  ecosystem forgone       ",
                        lpad(round(p["elapsedMs"] / e["elapsedMs"], digits = 2), 6), "x",
                        "   (polyglot / OrdinaryDiffEq; <1 means the hand-rolled")
                println("                                    kernel is the FASTER way to this answer)")
            end
        end
        println()
    end
end

main()
