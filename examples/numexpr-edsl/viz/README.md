# jurist-double-pendulum — the Hylograph frontend (ADR-0007, Tier-2 increment 4)

A pure **player** of the double-pendulum trajectory solved by the Jurist Julia
backend. There is no physics here: the index-1 DAE was solved by ModelingToolkit
on the Julia runtime (`../src/Data/DAESystem.purs` + `../ffi-jl/Data_DAESystem_foreign.jl`)
and handed over as `double-pendulum.json`. This app loads those frames and, each
~16ms tick, advances a frame index and re-renders the two rigid rods, the three
joints, and a fading trail of the second bob — the chaotic curve the browser
could never have integrated itself.

Rendering is **Hylograph HATS** (`hylograph-selection`): a declarative SVG tree
(`HATS.elem` composed with `<>`) re-rendered into a container by `rerender`.
Halogen owns only a static host `<div>`; HATS owns the SVG inside it.

This is a **standalone spago workspace**, independent of the purejl backend build
(which targets Julia). It pins registry package set `77.5.0` — the Hylograph
libraries are published to the PureScript registry, so they come as a coherent
set, no path overrides. The only coupling to the backend is the JSON file.

## Build & view

```bash
# 1. produce the trajectory (from the example root), then copy it in:
#    cd .. && spago build && stack exec purejl -- output output-jl \
#      && julia --project=julia-env output-jl/main.jl
cp ../double-pendulum.json public/

# 2. bundle and serve:
spago bundle --module DoublePendulum.Main --outfile public/bundle.js
npm run serve     # http://127.0.0.1:4178
```

`public/double-pendulum.json` and `public/bundle.js` are committed, so the demo
is viewable with just `npm run serve` (or any static server over `public/`).

## Layout

| Path | Role |
|------|------|
| `src/DoublePendulum/Main.purs` | Halogen entry point (`runUI`) |
| `src/DoublePendulum/Component.purs` | the frame-player component + HATS rendering |
| `src/DoublePendulum/Fetch.purs` (+ `.js`) | `fetch` + JSON parse of the trajectory |
| `public/index.html`, `public/style.css` | Swiss/light page chrome |
