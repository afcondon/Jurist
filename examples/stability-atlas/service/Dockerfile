# Stability Atlas — Julia service (PureScript→Julia via Jurist/purejl).
#
# Build-once-ship: this image bundles the prebuilt output-jl; the PS→Julia
# compile (spago build + purejl) is a separate lifecycle phase, not done here.
# Only Julia deps (HTTP.jl, pinned by julia-env/Manifest.toml) are installed.
FROM julia:1.10

WORKDIR /app

# Julia deps first (cached layer) — instantiate from the pinned Manifest, then
# precompile so first connect isn't paying the whole JIT cost.
COPY julia-env ./julia-env
RUN julia --project=julia-env -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Prebuilt compiled Julia output: loader.jl + generated modules + the FFI shims
# (Atlas_Kernel_foreign.jl, Main__foreign.jl) are all baked into output-jl.
COPY output-jl ./output-jl

# WebSocket service. Binds 0.0.0.0:ATLAS_PORT (default 3210). The threaded sweep
# kernel needs -t auto.
ENV ATLAS_PORT=3210
EXPOSE 3210

# The service self-tests (kernel vs pure-PS oracle, <1e-12) and warms the JIT at
# boot before accepting connections, so give it a long start period.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
  CMD bash -c 'echo > /dev/tcp/127.0.0.1/3210' || exit 1

CMD ["julia", "--project=julia-env", "-t", "auto", "output-jl/main.jl"]
