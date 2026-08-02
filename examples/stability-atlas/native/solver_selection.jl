# How the ecosystem reference was configured — the measurements behind the
# table in RESULTS.md §1. Run this before claiming atlas_ecosystem.jl is a
# fair opponent; it exists so that claim is reproducible rather than asserted.
const NDIR = @__DIR__
include(joinpath(NDIR,"kernel_fixed.jl")); using .KernelFixed
using OrdinaryDiffEq, SciMLBase, StaticArrays

# out-of-place SVector: the idiomatic formulation for a small system
function cr3bp_s(u, mu, t)
    x,y,vx,vy = u; m1 = 1.0-mu
    dx1 = x+mu; dx2 = x-1.0+mu
    r1sq = dx1*dx1+y*y; r2sq = dx2*dx2+y*y
    r1c = r1sq*sqrt(r1sq); r2c = r2sq*sqrt(r2sq)
    SVector(vx, vy, x+2.0*vy-m1*dx1/r1c-mu*dx2/r2c, y-2.0*vx-m1*y/r1c-mu*y/r2c)
end
# heap-allocated Vector, in-place: the obvious first cut, for contrast
function cr3bp_m!(du, u, mu, t)
    x,y,vx,vy = u; m1 = 1.0-mu
    dx1 = x+mu; dx2 = x-1.0+mu
    r1sq = dx1*dx1+y*y; r2sq = dx2*dx2+y*y
    r1c = r1sq*sqrt(r1sq); r2c = r2sq*sqrt(r2sq)
    du[1]=vx; du[2]=vy
    du[3]= x+2.0*vy-m1*dx1/r1c-mu*dx2/r2c
    du[4]= y-2.0*vx-m1*y/r1c-mu*y/r2c
    nothing
end

init_s(mu,a,e) = (rp=a*(1.0-e); x=rp-mu; SVector(x,0.0,0.0,sqrt((1.0-mu)*(1.0+e)/rp)-x))

function run(mu,a,e,horizon,tol,alg,events,state)
    rH=(mu/3.0)^(2.0/3.0)
    cb = events === :none ? nothing :
         events === :two ? CallbackSet(
            ContinuousCallback((u,t,i)->(u[1]+mu)^2+u[2]^2-9.0, i->SciMLBase.terminate!(i)),
            ContinuousCallback((u,t,i)->(u[1]-1.0+mu)^2+u[2]^2-rH, i->SciMLBase.terminate!(i))) :
         VectorContinuousCallback(
            (out,u,t,i)->(out[1]=(u[1]+mu)^2+u[2]^2-9.0; out[2]=(u[1]-1.0+mu)^2+u[2]^2-rH),
            (i,idx)->SciMLBase.terminate!(i), 2)
    kw = cb === nothing ? (;) : (callback=cb,)
    u0 = init_s(mu,a,e)
    prob = state === :static ? ODEProblem(cr3bp_s, u0, (0.0,horizon), mu) :
                               ODEProblem(cr3bp_m!, Vector(u0), (0.0,horizon), mu)
    sol = solve(prob, alg; kw..., abstol=tol, reltol=tol,
        save_everystep=false, save_start=false, dense=false, maxiters=10_000_000)
    (sol.t[end], sol.stats.naccept + sol.stats.nreject)
end

mu=9.54e-4; h=150.0*2*pi; a=0.45; e=0.05
timed(f) = (f(); minimum(@elapsed(f()) for _ in 1:3) * 1000)

println("Survivor pixel a=$a e=$e, 150 Jupiter periods. Best of 3.\n")
println("state representation and event encoding (Vern9 @1e-6):")
for (label, ev, st) in (("Vector state, two ContinuousCallbacks", :two, :mutable),
                        ("SVector state, two ContinuousCallbacks", :two, :static),
                        ("SVector state, one VectorContinuousCallback", :vector, :static),
                        ("SVector state, no events at all", :none, :static))
    println("  ", rpad(label, 44), lpad(round(timed(() -> run(mu,a,e,h,1e-6,Vern9(),ev,st)), digits=2), 7), " ms")
end

println("\nalgorithm and tolerance (SVector, one VectorContinuousCallback):")
for (nm, alg) in (("Vern9", Vern9()), ("Vern7", Vern7()), ("Tsit5", Tsit5()))
    for tol in (1e-6, 1e-8, 1e-10)
        t = timed(() -> run(mu,a,e,h,tol,alg,:vector,:static))
        _, ns = run(mu,a,e,h,tol,alg,:vector,:static)
        println("  ", rpad("$nm @ $tol", 20), lpad(round(t, digits=2), 7), " ms   ",
                lpad(ns, 6), " steps")
    end
end

println("\nthe incumbent:")
tf = timed(() -> KernelFixed.survival(mu,a,e,h,120.0))
println("  ", rpad("fixed RK4, 120/period", 20), lpad(round(tf, digits=2), 7), " ms   ",
        lpad(59629, 6), " steps")
