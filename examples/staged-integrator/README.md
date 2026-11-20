# Staged integrator

An ODE integrator with events, written once in PureScript, that runs as
native Julia code.

The usual way to get a fast inner loop out of a PureScript program on Julia
is to write the loop in Julia and call it. That puts the method in the
foreign file, where no type checks it and no other backend can run it, and
it is what the stability atlas did until this replaced it: its kernel was
320 lines of Julia kept in step, by hand, with a PureScript reference.

This example does it the other way round. The Runge-Kutta step is written in
PureScript, but over expressions instead of numbers, so running it produces
a *program*: a numbered list of additions, multiplications and square roots.
That program is data, and it has two readers.

- `Data.Simulation.simulate` interprets it. It is plain PureScript with no
  foreign code, so it runs wherever PureScript does, a browser included.
- `Data.Simulation.Julia.compile` hands the same instructions to Julia,
  which compiles them, inside the run loop, to one native function.

Both perform the same IEEE operations on the same operands in the same
order, so they agree to the last bit, and `Main` checks that they do.

The interpreter is also run on Node (`node/`), on the same systems and
inputs. The step count, end time and final state it prints for each must
appear character for character in the Julia program's output. That is the
claim a browser needs: an orbit computed in Julia can be recomputed in
JavaScript and come out the same.

## Where the pieces are

| | |
|---|---|
| `../numexpr-edsl/core/src/Data/NumExpr/Program.purs` | the program: instructions, sharing, the pure interpreter |
| `../numexpr-edsl/core/src/Data/Simulation.purs` | the description of a run, the RK4 step built as a program, `simulate`, `trajectory` |
| `../numexpr-edsl/staging/src/Data/Simulation/Julia.purs` and `.jl` | the Julia denotation: `compile`, `simulate`, `sweep` (threaded), `trajectory` |
| `../stability-atlas/core/src/Atlas/Survival.purs` | the atlas's three-body physics as a description |
| `systems/src/Systems.purs` | the three systems and their inputs, shared by both programs |
| `src/Main.purs` | on Julia: each system run both ways and compared |
| `node/src/Main.purs` | on Node: the interpreter alone, for the cross-runtime check |
| `kernel/cr3bp-survival.jl` | the Julia function the three-body description became, as text |

The Julia foreign file holds the loop (step, advance the time, test the
events) and no numerical method. That loop is the one thing written twice,
once there and once in `Data.Simulation.simulate`, and the comparison in
`Main` is what holds the two together.

## Running

```bash
spago build
stack exec --stack-yaml ../../stack.yaml purejl -- output output-jl
julia --project=julia-env -e 'using Pkg; Pkg.instantiate()'
julia --project=julia-env -t auto output-jl/main.jl
```

`bin/demos.py staged-integrator` does the same, holds the output to
`expected-output.txt` and the generated kernel to `kernel/`, and runs the
Node program against it.

## Against the hand-written kernel

`compare-with-hand-kernel.jl` runs the atlas's default sweep (120 x 75
orbits, 150 Jupiter periods) through the atlas's former hand-written kernel
(`../stability-atlas/native/kernel_fixed.jl`) and through `kernel/cr3bp-survival.jl`. Measured 2026-11-19 on an M4 Mac
Mini, Julia 1.12.6, 4 threads, best of 5:

| | |
|---|---:|
| pixels with identical verdicts | 9,000 of 9,000 |
| hand-written kernel | 3,816 ms |
| kernel generated from PureScript | 3,517 ms |
| generated / hand-written | 0.92 |

The timing is not in the demo lane; run it by hand with
`julia -t auto compare-with-hand-kernel.jl`. The agreement is: the atlas's
service, which now runs this kernel, checks all 9,000 pixels against the
hand-written one in its own lane entry.

## What this does not do yet

- **No chaos indicator.** The atlas's second layer integrates a tangent
  vector alongside the orbit and renormalises it every 16 steps. That needs
  a conditional in the expression language, which it does not have.
- **Fixed step, RK4 only, autonomous systems.** A rate cannot name the time.
- **The pure interpreter is slow on Julia.** It is there to be the
  reference and to run in a browser. Compiled to Julia it takes about
  340 microseconds for one three-body step (173 instructions), where the
  compiled function takes well under one.
