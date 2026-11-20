# FFI for Main: write a text file.
writeText(path) = text -> () -> begin
    Base.open(io -> Base.write(io, text), path, "w")
    nothing
end
