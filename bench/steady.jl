include(ARGS[1] * "/loader.jl")
Loop.countTo(4)()                        # warm
t(f) = (t0 = time_ns(); f(); Float64(time_ns()-t0)/1e9)
for n in (100, 400, 1600)
    s = minimum(t(() -> Loop.countTo(n)()) for _ in 1:5)
    println("  N=", lpad(n,5), "  ", lpad(round(s*1e3, digits=3),9), " ms   ",
            lpad(round(s/n*1e6, digits=3),8), " µs/iter")
end
