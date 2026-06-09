# Shim for Record.Builder (the `record` package). Records are Dict{String,Any};
# the builder copies once then mutates the copy, exactly as the JS foreign does.
# Mirrors purescript-record's Record/Builder.js.

copyRecord(rec) = Base.copy(rec)

unsafeInsert(l) = a -> rec -> (rec[l] = a; rec)

unsafeModify(l) = f -> rec -> (rec[l] = f(rec[l]); rec)

unsafeDelete(l) = rec -> (Base.delete!(rec, l); rec)

unsafeRename(l1) = l2 -> rec -> (rec[l2] = rec[l1]; Base.delete!(rec, l1); rec)
