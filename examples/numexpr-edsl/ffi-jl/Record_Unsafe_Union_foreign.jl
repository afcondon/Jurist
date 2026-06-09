# Shim for Record.Unsafe.Union (the `record` package). `unsafeUnionFn` is a
# genuine 2-argument function (uncurried, called via runFn2): left record wins
# on key collisions. Mirrors purescript-record's Record/Unsafe/Union.js.

function unsafeUnionFn(r1, r2)
    out = Base.Dict{Base.String, Any}()
    for (k, v) in r2
        out[k] = v
    end
    for (k, v) in r1
        out[k] = v
    end
    out
end
