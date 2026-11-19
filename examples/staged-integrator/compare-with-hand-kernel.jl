# Hold the kernel PureScript wrote (kernel/cr3bp-survival.jl, emitted by
# this example's Main and held to a fresh run by bin/demos.py) to the one written by hand for the stability atlas (kept as
# stability-atlas/native/kernel_fixed.jl), over
# the atlas's own default sweep, and time both.
#
#   julia -t auto compare-with-hand-kernel.jl
#
# The hand kernel reports round(t / horizon, digits = 4) for a lost orbit
# and 1.0 for a survivor; the staged one reports the raw end time and which
# event fired, so its answer is put through the same rounding here.

include(joinpath(@__DIR__, "..", "stability-atlas", "native", "kernel_fixed.jl"))
const _survival = KernelFixed.survival
const staged = eval(Meta.parse(read(joinpath(@__DIR__, "kernel", "cr3bp-survival.jl"), String)))

# The atlas's default sweep (web/src/Atlas/App.purs, native/compare.jl).
const MU = 9.54e-4
const COLS, ROWS = 120, 75
const PERIODS = 150.0
const SPP = 120.0
const HORIZON = PERIODS * 2.0 * pi

as(c) = 0.30 + (0.85 - 0.30) * (c - 1) / (COLS - 1)
es(r) = 0.0 + (0.35 - 0.0) * (r - 1) / (ROWS - 1)

function sweep_hand()
    out = Matrix{Float64}(undef, ROWS, COLS)
    Threads.@threads for r in 1:ROWS
        for c in 1:COLS
            out[r, c] = _survival(MU, as(c), es(r), HORIZON, SPP)
        end
    end
    out
end

function sweep_staged(f)
    out = Matrix{Float64}(undef, ROWS, COLS)
    Threads.@threads for r in 1:ROWS
        input = Vector{Float64}(undef, 5)
        for c in 1:COLS
            input[1] = as(c); input[2] = es(r); input[3] = MU; input[4] = PERIODS; input[5] = SPP
            res = f(input)
            out[r, c] = res[2] < 0 ? 1.0 : round(res[1] / HORIZON; digits = 4)
        end
    end
    out
end

best(f, n) = minimum(begin t = time_ns(); f(); (time_ns() - t) / 1e6 end for _ in 1:n)

hand = sweep_hand()
mine = sweep_staged(staged)
same = count(hand .== mine)
println("threads: ", Threads.nthreads())
println("pixels identical: ", same, " of ", length(hand))
println("survivors: hand ", count(==(1.0), hand), ", staged ", count(==(1.0), mine))
th = best(sweep_hand, 5)
ts = best(() -> sweep_staged(staged), 5)
println("hand-written kernel: ", round(th; digits = 1), " ms")
println("staged kernel:       ", round(ts; digits = 1), " ms")
println("staged / hand:       ", round(ts / th; digits = 3))
