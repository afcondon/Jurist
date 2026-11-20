# FFI for Atlas.Kernel: a clock and a line on stderr.
#
# No kernel is written here. The survival sweep, the chaos-indicator sweep
# and the single-orbit trajectory are all compiled from the descriptions in
# Atlas.Survival (see Atlas/Kernel.purs). The hand-written kernels they
# replaced are kept in native/kernel_fixed.jl, as the reference the
# service's check mode compares against.

# nowMs :: Effect Number
nowMs = () -> Base.time_ns() / 1.0e6

# reportSweep :: { .. } -> Effect Unit
# The `sweep-perf` line native/compare.jl reads from stderr.
reportSweep(r) = () -> begin
    Base.println(Base.stderr, "sweep-perf cols=", r["cols"], " rows=", r["rows"],
        " fli=", r["fli"],
        " total_ms=", r["total"],
        " kernel_ms=", r["kernel"],
        " emit_ms=", r["emit"])
    Base.flush(Base.stderr)
    nothing
end
