# spike/wasm-cc1/Dockerfile — Phase 2.1 build environment.
#
# Combines:
#   • Emscripten SDK (the wasm cross-toolchain)
#   • Retro68's GCC 12.2.0 source tree + Retro68 patches
#   • A native host GCC (Ubuntu's stock) for stage-1 bootstrap
#
# We do NOT pull the Retro68 toolchain *image* (ghcr.io/autc04/retro68)
# because that ships the pre-built m68k cross-compiler — we want to
# rebuild it ourselves so stage 1 and stage 2 share an identical source
# tree (mismatched generated headers between stages = silent miscompile;
# see ../README.md landmine #4).
#
# Pinned versions: Emscripten 3.1.61 (last known good for Emception's
# pattern; LLVM 18.x era; SUPPORT_LONGJMP=wasm stable). Retro68 source
# pinned to the commit shipped by the autc04/retro68 image we use for
# Phase 1+2.0 (sha256:e8b6cc8…) so the GCC sources we build are the same
# tree that produces our reference hello-toolbox-retro68.bin.

FROM ubuntu:22.04 AS base

# ── Host build deps ────────────────────────────────────────────────
# build-essential: gcc/g++/make for stage-1 native + Emscripten host
# python3       : Emscripten config + GCC test harness
# bison/flex    : GCC's parser generators (configure rejects without)
# texinfo       : GCC's doc step (--disable-nls doesn't kill all of it)
# libgmp/mpfr/mpc-dev : GCC dependency libs (host-only; stage 2 uses
#                       in-tree static builds)
# git/cmake/ninja/curl/xz-utils : sources + Emscripten install
# brotli        : final size measurement (Phase 2.4 budget)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      python3 python-is-python3 \
      bison flex texinfo \
      libgmp-dev libmpfr-dev libmpc-dev libisl-dev \
      git cmake ninja-build curl xz-utils ca-certificates \
      brotli \
      && rm -rf /var/lib/apt/lists/*

# ── Emscripten SDK ─────────────────────────────────────────────────
# Pinned via tag to keep build-system upgrades visible in git history.
# 3.1.61 chosen because it's the latest version Emception is known to
# build cleanly under (LLVM 18.1, native SUPPORT_LONGJMP=wasm stable).
ARG EMSDK_VERSION=3.1.61
RUN git clone --depth 1 --branch ${EMSDK_VERSION} https://github.com/emscripten-core/emsdk.git /opt/emsdk \
    && /opt/emsdk/emsdk install ${EMSDK_VERSION} \
    && /opt/emsdk/emsdk activate ${EMSDK_VERSION}

# Make emsdk active for non-login shells (RUN steps + interactive use).
ENV EMSDK=/opt/emsdk
ENV PATH=/opt/emsdk:/opt/emsdk/upstream/emscripten:/opt/emsdk/upstream/bin:${PATH}
ENV EM_CONFIG=/opt/emsdk/.emscripten

# ── Retro68 sources ────────────────────────────────────────────────
# Pin by SHA, not tag — Retro68's only tags are 2019-era (v2019.8.*)
# and we need a modern GCC 12.2 era source tree to match the runtime
# image we use for Phase 2.0 (ghcr.io/autc04/retro68 @ e8b6cc8…).
# Picked from `git ls-remote --heads` master tip at 2026-05-14.
# The Retro68 repo uses submodules for gcc/binutils/etc.; recurse.
ARG RETRO68_COMMIT=83b9c8d2c58f8efb0925a305aca1e0edab2e6571
RUN git clone https://github.com/autc04/Retro68.git /Retro68 \
    && cd /Retro68 \
    && git checkout ${RETRO68_COMMIT} \
    && git submodule update --init --recursive --depth 1

# ── Phase 2.1 build scripts ────────────────────────────────────────
# Mount the spike/wasm-cc1/ directory at /spike when running the
# container; build.sh inside that directory drives both stages.
WORKDIR /spike
ENTRYPOINT ["/bin/bash"]
