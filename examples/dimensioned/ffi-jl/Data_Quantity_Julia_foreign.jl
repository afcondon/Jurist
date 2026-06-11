# FFI for Data.Quantity.Julia — the DynamicQuantities denotation of the typed
# Quantity language. The dimension arrives as three plain Int exponents
# (reflected from the PureScript type); DynamicQuantities rebuilds the
# quantity and does the runtime half: rendering, conversion, and its own
# dimensional enforcement.
#
# Qualified calls throughout — this file is `include`d inside the generated
# `Data_Quantity_Julia` module.

import DynamicQuantities

_jurist_q(v, m, l, t) = DynamicQuantities.Quantity(Base.Float64(v),
    DynamicQuantities.Dimensions(mass = m, length = l, time = t))

# prettySIJ v m l t : Effect String — render in SI base units.
prettySIJ(v) = m -> l -> t -> () -> Base.string(_jurist_q(v, m, l, t))

# inUnitsJ target v m l t : Effect String — convert to the requested unit
# (sym_uparse'd at runtime), or hand back the DimensionError verbatim.
inUnitsJ(target) = v -> m -> l -> t -> () -> begin
    try
        tu = DynamicQuantities.sym_uparse(target)
        converted = DynamicQuantities.uconvert(tu, _jurist_q(v, m, l, t))
        Base.string(DynamicQuantities.ustrip(converted)) * " " * target
    catch e
        "✗ " * Base.sprint(Base.showerror, e)
    end
end
