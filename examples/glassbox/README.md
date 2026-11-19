# Glassbox on Julia

[Glassbox](https://github.com/afcondon/purescript-glassbox) is a state
machine as a data artifact: a JSON file, a pure runtime, and one claim.

> Given the same sequence of input events, the artifact reaches the same
> state, emits the same effects in the same order, and refuses with the same
> tag.

Glassbox makes that checkable by enumerating every (state × event ×
guard-assignment) a machine admits and writing down what its runtime
answers: the conformance vectors, committed in its repo and generated on
Node.

This example compiles Glassbox's **unmodified** core to Julia with `purejl`,
regenerates the vectors for every machine, and compares each file with the
committed one. They must be byte-identical.

```bash
spago build                                # fetches glassbox at the pinned commit
stack exec purejl -- output output-jl
bin/demos.py glassbox                      # from the repo root: runs it and compares
```

## What is whose

- **Glassbox's core** (`Glassbox.Codec.JSON`, `Glassbox.Run`,
  `Glassbox.Conformance`): the decoder, the runtime and the table. All
  PureScript, no foreign imports, taken from the public repo at the commit
  pinned in `spago.yaml`.
- **`src/Main.purs`**: reads each machine, calls `suiteFor` and
  `printSuite`, writes the result. Twenty lines.
- **`src/Main.jl`**: this program's only foreign code: list a directory, read
  a file, write a file, read `ARGS`. Four library calls, no logic.
- **The backend**: `Foreign.Object` and `Data.Argonaut.*`, which Glassbox's
  codec stands on, are supplied by `purejl` itself
  ([ADR-0011](../../docs/design-decisions/0011-foreign-object-and-json.md)).
  They were missing until this example asked for them.

## What this shows, and what it does not

It shows the assurance half of the family's claim on a real library: one
typed model, and the same answers on a second runtime, to the byte, for
every case the model admits.

It does not show a reason to run a state machine on Julia. By the family's
own test this is a "stay on JS" computation. The reason comes when Julia
does something with the machine that JS cannot, and that is a different
example.

Nothing here is about speed. The run takes about fifteen seconds, nearly all
of it Julia compiling.
