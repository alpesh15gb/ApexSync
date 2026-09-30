# syntax=docker/dockerfile:1

# Pinned deliberately: the SDK in this image is what compiles the binary that
# runs in production, so changing it should be a decision rather than a side
# effect of a rebuild. Pin by digest for full reproducibility.
ARG DART_IMAGE=dart:3.13

# ---------------------------------------------------------------------------
# Build: resolve dependencies, then compile a self-contained native executable.
# ---------------------------------------------------------------------------
FROM ${DART_IMAGE} AS build
WORKDIR /src

# Dependencies in their own layer, so editing a source file does not re-resolve
# the whole package graph.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY analysis_options.yaml ./
COPY bin ./bin
COPY lib ./lib

# `dart compile exe` produces a native binary, so the runtime image needs no
# Dart SDK and start-up is a process exec rather than a VM warm-up.
RUN dart pub get --offline \
 && dart compile exe bin/atria_api.dart -o /src/atria_api

# ---------------------------------------------------------------------------
# Runtime: only what the binary needs. No SDK, no shell tooling beyond curl for
# the healthcheck.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin atria

COPY --from=build /src/atria_api /usr/local/bin/atria_api

# Non-root, with a fixed uid so the host can reason about file ownership.
USER 10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/usr/local/bin/atria_api"]
