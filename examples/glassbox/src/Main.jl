# The probe's own FFI: file IO and argv. Library calls only.
machineNames(dir) = () -> Base.Any[Base.replace(f, r"\.json$" => "") for f in Base.sort(Base.readdir(dir)) if Base.endswith(f, ".json")]
readText(path) = () -> Base.read(path, Base.String)
writeText(path) = content -> () -> (Base.write(path, content); Base.nothing)
arg(i) = () -> Base.ARGS[i + 1]
