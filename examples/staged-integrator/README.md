# Staged integrator

An ODE integrator with events and discrete updates, written once in
PureScript, that runs as native Julia code.

The usual way to get a fast inner loop out of a PureScript program on Julia
is to write the loop in Julia and call it. That puts the method in the
foreign file, where no type checks it and no other backend can run it, and
it is what the stability atlas did until this replaced it: its kernels were
Julia kept in step, by hand, with a PureScript reference.

This example does it the other way round. The Runge-Kutta step is written in
PureScript, but over expressions instead of numbers, so running it produces
a *program*: a numbered list of additions, multiplications, square roots
and choices between two values.
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
| `systems/src/Systems.purs` | the four systems and their inputs, shared by both programs |
| `src/Main.purs` | on Julia: each system run both ways and compared |
| `node/src/Main.purs` | on Node: the interpreter alone, for the cross-runtime check |
| `kernel/cr3bp-survival.jl` | the Julia function the three-body description became, as text |
| `kernel/cr3bp-chaos.jl` | the same for the three-body run with its chaos indicator |

The Julia foreign file holds the loop (step, advance the time, test the
events, apply the updates that are due) and no numerical method. That loop is the one thing written twice,
once there and once in `Data.Simulation.simulate`, and the comparison in
`Main` is what holds the two together.

## More than differential equations

A description has integrated variables, which have a rate, and held
variables, which keep their value until an update sets them. An update runs
after every so many steps and computes new values from the state as the step
left it. The expression language has one conditional, `ifGreater a b x y`
(`x` if `a > b`, otherwise `y`), and it is a choice between two values, not a
jump: both are computed and one is kept, so the program stays a straight line
and Julia compiles it without a branch.

`Systems.thermostat` is the small example: a room that leaks heat, a heater
that is on or off, a thermostat that looks every 30 steps, and a count of the
times the heater came on. `Atlas.Survival.chaos` is the real one: a tangent
vector carried along an orbit, measured every 16 steps, and scaled back to
length 1 whenever it passes 1e12.

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
orbits, 150 Jupiter periods) through the atlas's former hand-written kernels
(`../stability-atlas/native/kernel_fixed.jl`) and through the two recorded
in `kernel/`. Measured 2026-11-20 on an M4 Mac Mini, Julia 1.12.6, 4 threads,
best of 5:

| | survival | chaos indicator |
|---|---:|---:|
| pixels with identical verdicts | 9,000 of 9,000 | 9,000 of 9,000 |
| hand-written kernel | 3,816 ms | 4,100 ms |
| kernel generated from PureScript | 3,518 ms | 4,748 ms |
| generated / hand-written | 0.92 | 1.16 |

The generated chaos kernel is slower than the hand-written one, and why has
not been looked into.

The timing is not in the demo lane; run it by hand with
`julia -t auto compare-with-hand-kernel.jl`. The agreement is: the atlas's
service, which runs these kernels, checks all 9,000 pixels of each against
the hand-written ones in its own lane entry.

## What this does not do yet

- **Fixed step, RK4 only, autonomous systems.** A rate cannot name the time,
  and there is no table to look a value up in, so nothing can be driven by
  recorded data yet.
- **An event ends the run.** There is no event that changes the state and
  carries on; an update does that, but on a fixed schedule.
- **Only sqrt agrees across runtimes.** The Node check holds because the
  systems it covers use arithmetic and square roots, which IEEE defines
  exactly. `log`, `exp`, `sin`, `cos` and `pow` may differ in the last digit
  between Julia and JavaScript, so the chaos-indicator run is compared
  within Julia only.
- **The pure interpreter is slow on Julia.** It is there to be the
  reference and to run in a browser. Compiled to Julia it takes about
  340 microseconds for one three-body step (173 instructions), where the
  compiled function takes well under one.
