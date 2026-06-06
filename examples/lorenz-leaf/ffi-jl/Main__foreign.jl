# User FFI shim for module Main (PS Main -> Julia Main_, so this file is
# Main__foreign.jl). Copied into the output by purejl from ffi-jl/.
#
# This is the "hot leaf": real Julia numerics behind a PS foreign import.

# RK4 integration of the Lorenz system from (1,1,1); beta fixed at 8/3.
# Fn4 foreign: genuine 4-argument function.
lorenzOrbitImpl(sigma, rho, dt, steps) = begin
    beta = 8.0 / 3.0
    deriv(x, y, z) = (sigma * (y - x), x * (rho - z) - y, x * y - beta * z)
    x, y, z = 1.0, 1.0, 1.0
    out = Any[]
    for _ in 1:steps
        k1x, k1y, k1z = deriv(x, y, z)
        k2x, k2y, k2z = deriv(x + dt / 2 * k1x, y + dt / 2 * k1y, z + dt / 2 * k1z)
        k3x, k3y, k3z = deriv(x + dt / 2 * k2x, y + dt / 2 * k2y, z + dt / 2 * k2z)
        k4x, k4y, k4z = deriv(x + dt * k3x, y + dt * k3y, z + dt * k3z)
        x += dt / 6 * (k1x + 2k2x + 2k3x + k4x)
        y += dt / 6 * (k1y + 2k2y + 2k3y + k4y)
        z += dt / 6 * (k1z + 2k2z + 2k3z + k4z)
        Base.push!(out, Base.Dict{Base.String, Any}("x" => x, "y" => y, "z" => z))
    end
    out
end

# Dependency-free JSON writer over the PS runtime representation
# (Dict records, Vector arrays, Float64/Int64, String, Bool, nothing).
# Julia multiple dispatch doing the work the JS shim would do with typeof.
_json(x::Base.AbstractString) = "\"" * Base.replace(x, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t") * "\""
_json(x::Base.Bool) = x ? "true" : "false"
_json(x::Base.Integer) = Base.string(x)
_json(x::Base.AbstractFloat) = Base.string(x)
_json(x::Base.Char) = _json(Base.string(x))
_json(::Base.Nothing) = "null"
_json(x::Base.AbstractVector) = "[" * Base.join(Any[_json(v) for v in x], ",") * "]"
_json(x::Base.AbstractDict) = "{" * Base.join(Any["\"" * k * "\":" * _json(x[k]) for k in Base.sort!(Base.collect(Base.keys(x)))], ",") * "}"

toJson(x) = _json(x)
