# Which integrator is wrong at the pixels where they disagree?
#
# Test 1: refine the FIXED step (120 -> 960 per period).
# Test 2: tighten the ADAPTIVE tolerance (1e-6 -> 1e-12).
#
# If a verdict were merely under-resolved, both would settle. If it does not
# settle under EITHER, the verdict is not a property of the system at that
# precision — the orbit is chaotic and "survived 150 periods" is discontinuous
# in the initial conditions there. That is a claim about the physics, not
# about either integrator, and it is the one the atlas cannot currently make.
const NDIR = @__DIR__
include(joinpath(NDIR,"kernel_fixed.jl")); using .KernelFixed
using HTTP, JSON3, OrdinaryDiffEq, SciMLBase, StaticArrays, Statistics

function cr3bp(u,mu,t)
    x,y,vx,vy=u; m1=1.0-mu; dx1=x+mu; dx2=x-1.0+mu
    r1sq=dx1*dx1+y*y; r2sq=dx2*dx2+y*y
    r1c=r1sq*sqrt(r1sq); r2c=r2sq*sqrt(r2sq)
    SVector(vx,vy,x+2.0*vy-m1*dx1/r1c-mu*dx2/r2c,y-2.0*vx-m1*y/r1c-mu*y/r2c)
end
function eco(mu,a,e,h,tol)
    rp=a*(1.0-e); x=rp-mu; rH=(mu/3.0)^(2.0/3.0)
    u0=SVector(x,0.0,0.0,sqrt((1.0-mu)*(1.0+e)/rp)-x)
    cb=VectorContinuousCallback((out,u,t,i)->(out[1]=(u[1]+mu)^2+u[2]^2-9.0;
                                              out[2]=(u[1]-1.0+mu)^2+u[2]^2-rH),
                                (i,idx)->SciMLBase.terminate!(i),2)
    s=solve(ODEProblem(cr3bp,u0,(0.0,h),mu),Vern9();callback=cb,abstol=tol,reltol=tol,
            save_everystep=false,save_start=false,dense=false,maxiters=10_000_000)
    s.t[end]>=h ? 1.0 : round(s.t[end]/h,digits=4)
end

spec=(tag="RequestSweep",aMin=0.30,aMax=0.85,eMin=0.0,eMax=0.35,
      cols=120,rows=75,horizonPeriods=150.0,mu=9.54e-4,withFli=false)
function grid(port)
    g=Dict{Int,Vector{Float64}}()
    HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
        HTTP.WebSockets.send(ws,JSON3.write(spec))
        for raw in ws
            m=JSON3.read(String(raw))
            if m.tag=="SweepRows"; for (i,r) in enumerate(m.rows); g[m.rowStart+i-1]=Float64.(r); end
            elseif m.tag=="SweepDone"; break; end
        end
    end; g
end

p=grid(3210); ep=grid(3213)
da=(0.85-0.30)/119; de=0.35/74; h=150.0*2*pi; mu=9.54e-4
flips=[(a=0.30+da*(c-1), ecc=de*r) for r in 0:74, c in 1:120 if (p[r][c]>=1.0)!=(ep[r][c]>=1.0)]
agree=[(a=0.30+da*(c-1), ecc=de*r) for r in 0:74, c in 1:120 if p[r][c]==ep[r][c] && p[r][c]<1.0]

function classify(pts, label)
    unstable_fixed=0; unstable_eco=0; unstable_either=0
    for f in pts
        vf=[KernelFixed.survival(mu,f.a,f.ecc,h,sp) for sp in (120.0,240.0,480.0,960.0)]
        ve=[eco(mu,f.a,f.ecc,h,tol) for tol in (1e-6,1e-8,1e-10,1e-12)]
        uf=length(unique(v->v>=1.0, vf))>1
        ue=length(unique(v->v>=1.0, ve))>1
        uf && (unstable_fixed+=1); ue && (unstable_eco+=1); (uf||ue) && (unstable_either+=1)
    end
    n=length(pts)
    println(rpad(label,34), lpad(n,4), " px   class unstable under refinement:")
    println("      fixed step 120->960/period : ", lpad(unstable_fixed,4), " (",
            lpad(round(100*unstable_fixed/n,digits=1),5), " %)")
    println("      adaptive tol 1e-6->1e-12   : ", lpad(unstable_eco,4), " (",
            lpad(round(100*unstable_eco/n,digits=1),5), " %)")
    println("      unstable under EITHER      : ", lpad(unstable_either,4), " (",
            lpad(round(100*unstable_either/n,digits=1),5), " %)")
end

println("Are the disagreements under-resolution, or genuine indeterminacy?\n")
classify(flips[1:min(30,end)], "pixels where they DISAGREE")
println()
classify(agree[1:min(30,end)], "control: pixels where they AGREE")
