# Hold the kernels PureScript wrote (kernel/cr3bp-survival.jl and
# kernel/cr3bp-chaos.jl, emitted by this example's Main and held to a fresh
# run by bin/demos.py) to the ones written by hand for the stability atlas
# (kept as stability-atlas/native/kernel_fixed.jl), over the atlas's own
# default sweep, and time all four.
#
#   julia -t auto compare-with-hand-kernel.jl
#
# The hand kernels return the number the atlas paints. The generated ones
# return the end time, which event fired and the final state, so their
# answers are put through the same rounding here (Atlas.Survival.verdict
# and chaosVerdict do it in the service).

include(joinpath(@__DIR__, "..", "stability-atlas", "native", "kernel_fixed.jl"))
const _survival = KernelFixed.survival
const _survival_fli = KernelFixed.survival_fli
generated(name) = eval(Meta.parse(read(joinpath(@__DIR__, "kernel", name), String)))
const survival_generated = generated("cr3bp-survival.jl")
const chaos_generated = generated("cr3bp-chaos.jl")

# The atlas's default sweep (web/src/Atlas/App.purs, native/compare.jl).
const MU = 9.54e-4
const COLS, ROWS = 120, 75
const PERIODS = 150.0
const SPP = 120.0
const HORIZON = PERIODS * 2.0 * pi

as(c) = 0.30 + (0.85 - 0.30) * (c - 1) / (COLS - 1)
es(r) = 0.0 + (0.35 - 0.0) * (r - 1) / (ROWS - 1)

function sweep_hand(kernel)
    out = Matrix{Float64}(undef, ROWS, COLS)
    Threads.@threads for r in 1:ROWS
        for c in 1:COLS
            out[r, c] = kernel(MU, as(c), es(r), HORIZON, SPP)
        end
    end
    out
end

# The state is (x, y, vx, vy) or, with the indicator, those and
# (px, py, pvx, pvy, accLog, maxLog): maxLog is the last.
paint_survival(res) = res[2] < 0 ? 1.0 : round(res[1] / HORIZON; digits = 4)
paint_chaos(res) = res[2] < 0 ? 1.0 + round(min(res[end], 8.0) / 8.0; digits = 4) :
                                round(res[1] / HORIZON; digits = 4)

function sweep_generated(f, paint)
    out = Matrix{Float64}(undef, ROWS, COLS)
    Threads.@threads for r in 1:ROWS
        input = Vector{Float64}(undef, 5)
        for c in 1:COLS
            input[1] = as(c); input[2] = es(r); input[3] = MU; input[4] = PERIODS; input[5] = SPP
            out[r, c] = paint(f(input))
        end
    end
    out
end

best(f, n) = minimum(begin t = time_ns(); f(); (time_ns() - t) / 1e6 end for _ in 1:n)

println("threads: ", Threads.nthreads())
for (title, hand, mine) in (
        ("survival", () -> sweep_hand(_survival), () -> sweep_generated(survival_generated, paint_survival)),
        ("chaos indicator", () -> sweep_hand(_survival_fli), () -> sweep_generated(chaos_generated, paint_chaos)))
    a = hand(); b = mine()
    println("== ", title, " ==")
    println("pixels identical: ", count(a .== b), " of ", length(a))
    th = best(hand, 5); tg = best(mine, 5)
    println("hand-written kernel: ", round(th; digits = 1), " ms")
    println("generated kernel:    ", round(tg; digits = 1), " ms")
    println("generated / hand:    ", round(tg / th; digits = 3))
end
