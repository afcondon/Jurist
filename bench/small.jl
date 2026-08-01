include("out-jl/loader.jl")
t(f) = (t0 = time_ns(); f(); Float64(time_ns()-t0)/1e9)
Loop.countTo(2)()                      # warm the code paths
for n in (10, 20, 40, 80, 160, 320)
    s = minimum(t(() -> Loop.countTo(n)()) for _ in 1:2)
    println("N=", lpad(n,4), "  ", lpad(round(s, digits=4),8), " s   ",
            lpad(round(s/n*1000, digits=3),9), " ms/iter")
end
