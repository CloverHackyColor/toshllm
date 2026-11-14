#!/bin/zsh
# Builds all ToshLLM inference engines:
#   1. CloverHackyColor/llama.cpp, branch tosh (all ToshLLM patches committed)
#   2. Official whisper.cpp + the existing ToshLLM patches
#   3. CloverHackyColor/stable-diffusion.cpp + its pinned GGML submodule
#
# The original scripts/build-engines.sh is intentionally left unchanged.
#
# Usage:
#   ./scripts/build-all-engines.sh
#   ARCH=x86_64 ./scripts/build-all-engines.sh
#   ARCH=universal ./scripts/build-all-engines.sh   # experimental
#
# Optional overrides:
#   SD_REPO=https://github.com/CloverHackyColor/stable-diffusion.cpp
#   SD_COMMIT=origin/master
#   GGML_REPO=https://github.com/CloverHackyColor/ggml.git
#   SKIP_LLAMA=1 / SKIP_WHISPER=1 (passed through to build-engines.sh)

set -e

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LLAMA_REPO="${LLAMA_REPO:-https://github.com/CloverHackyColor/llama.cpp.git}"
LLAMA_COMMIT="${LLAMA_COMMIT:-origin/tosh}"
#real commit is be4b36402d18b2c195b6119123114c6bd65ecc1b
LLAMA_APPLY_PATCHES=0

SD_REPO="${SD_REPO:-https://github.com/CloverHackyColor/stable-diffusion.cpp.git}"
# Track the fork's master by default. For a fully reproducible build, set SD_COMMIT
# to a specific commit SHA (recommended for releases).
SD_COMMIT="${SD_COMMIT:-origin/tosh}"
GGML_REPO="${GGML_REPO:-https://github.com/CloverHackyColor/ggml.git}"
ARCH="${ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="14.0"

export SD_REPO SD_COMMIT GGML_REPO ARCH
export LLAMA_REPO LLAMA_COMMIT LLAMA_APPLY_PATCHES
export SD_REPO SD_COMMIT GGML_REPO ARCH

# Match build-engines.sh: retry networked Git operations on transient failures.
retry_git() {
    local attempt=1
    local max_attempts=4
    local delay

    while ! "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "ERROR: git operation failed after $max_attempts attempts: $*" >&2
            return 1
        fi
        delay=$((attempt * 10))
        echo "Git network operation failed (attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

reset_stale_cmake_cache() {
    local cache="$1/CMakeCache.txt" key cached
    [ -f "$cache" ] || return 0
    for key in CMAKE_OSX_SYSROOT CMAKE_C_COMPILER CMAKE_CXX_COMPILER; do
        cached=$(sed -n "s/^$key:[A-Z]*=//p" "$cache")
        if [ -n "$cached" ] && [ "${cached#/}" != "$cached" ] && [ ! -e "$cached" ]; then
            echo "stale cmake cache in $1 ($key -> $cached); reconfiguring"
            rm -rf "$cache" "$1/CMakeFiles"
            return 0
        fi
    done
}

# Resolve the full Xcode Metal toolchain, as in build-engines.sh.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun metal -v >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
fi

resolve_metal_toolchain() {
    xcrun metal -v >/dev/null 2>&1 || return 1
    METAL_COMPILER="$(xcrun -f metal 2>/dev/null)" || return 1
    METALLIB_COMPILER="$(xcrun -f metallib 2>/dev/null)" || return 1
    [ -x "$METAL_COMPILER" ] && [ -x "$METALLIB_COMPILER" ]
}

if resolve_metal_toolchain; then
    METAL_PRECOMPILE=1
    echo "Metal compiler available — will precompile default.metallib"
else
    METAL_PRECOMPILE=0
    echo "Metal compiler unavailable — embedded source only (slower first load)"
fi

# Pin ISA flags exactly as build-engines.sh does.
ISA_FLAGS=()
if [ "$ARCH" = "x86_64" ]; then
    if [ -z "${TOSH_NO_AVX2:-}" ]; then
        ISA_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON
                   -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF)
    else
        ISA_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF
                   -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF)
    fi
fi

build_image_engine() {
    local vendor="vendor/stable-diffusion.cpp"

    if [ ! -d "$vendor/.git" ]; then
        retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
            git clone "$SD_REPO" "$vendor"
    fi

    cd "$vendor"
    # vendor/stable-diffusion.cpp may already have been cloned from leejet by
    # the old build-engines.sh; redirect its origin before fetching our fork.
    git remote set-url origin "$SD_REPO"
    retry_git git fetch origin --prune

    # This checkout is a generated build tree. Discard local edits here: durable
    # changes belong in the CloverHackyColor GitHub forks, not in vendor/.
    git reset --hard
    git clean -qfd
    git checkout -qf "$SD_COMMIT"

    # The GGML commit is selected by the gitlink recorded in stable-diffusion.cpp.
    # Override the submodule's clone URL locally so this build always uses our fork,
    # even if an older .gitmodules still names leejet/ggml. The fork itself should
    # also have .gitmodules updated to CloverHackyColor/ggml for normal manual use.
    git submodule sync --recursive
    git config submodule.ggml.url "$GGML_REPO"
    if [ -d ggml ]; then
        # If GGML is already initialized, redirect its own origin before update
        # as well; changing only the superproject config is not sufficient.
        git -C ggml remote set-url origin "$GGML_REPO" 2>/dev/null || true
        git -C ggml reset --hard 2>/dev/null || true
        git -C ggml clean -qfd 2>/dev/null || true
    fi
    retry_git git submodule update --init --recursive --force
    git -C ggml remote set-url origin "$GGML_REPO"

    cd "$ROOT/$vendor"

    local isa=("${ISA_FLAGS[@]}")
    reset_stale_cmake_cache build-static
    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DSD_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        "${isa[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli

    # Precompile the generated Metal source for faster first model load.
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for image engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            echo "WARNING: metallib precompile failed — using embedded source" >&2
            METAL_PRECOMPILE=0
        fi
    fi

    echo "image engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# Experimental universal build: build each architecture separately, then lipo
# the command-line binaries. Metal libraries are GPU-targeted and are retained
# from the final slice, as in the existing build workflow.
if [ "$ARCH" = "universal" ]; then
    for slice in x86_64 arm64; do
        ARCH="$slice" "$SCRIPT_PATH"
        for tool in llama-server llama-bench llama-perplexity; do
            mv "vendor/llama.cpp/build-static/bin/$tool" "vendor/llama.cpp/build-static/bin/$tool.$slice" 2>/dev/null || true
        done
        for tool in whisper-cli whisper-server; do
            mv "vendor/whisper.cpp/build-static/bin/$tool" "vendor/whisper.cpp/build-static/bin/$tool.$slice" 2>/dev/null || true
        done
        mv vendor/stable-diffusion.cpp/build-static/bin/sd-cli \
           "vendor/stable-diffusion.cpp/build-static/bin/sd-cli.$slice" 2>/dev/null || true
    done

    for tool in llama-server llama-bench llama-perplexity; do
        if [ -f "vendor/llama.cpp/build-static/bin/$tool.x86_64" ] && [ -f "vendor/llama.cpp/build-static/bin/$tool.arm64" ]; then
            lipo -create -output "vendor/llama.cpp/build-static/bin/$tool" \
                "vendor/llama.cpp/build-static/bin/$tool.x86_64" "vendor/llama.cpp/build-static/bin/$tool.arm64"
            rm "vendor/llama.cpp/build-static/bin/$tool".{x86_64,arm64}
        fi
    done
    for tool in whisper-cli whisper-server; do
        if [ -f "vendor/whisper.cpp/build-static/bin/$tool.x86_64" ] && [ -f "vendor/whisper.cpp/build-static/bin/$tool.arm64" ]; then
            lipo -create -output "vendor/whisper.cpp/build-static/bin/$tool" \
                "vendor/whisper.cpp/build-static/bin/$tool.x86_64" "vendor/whisper.cpp/build-static/bin/$tool.arm64"
            rm "vendor/whisper.cpp/build-static/bin/$tool".{x86_64,arm64}
        fi
    done
    if [ -f vendor/stable-diffusion.cpp/build-static/bin/sd-cli.x86_64 ] && [ -f vendor/stable-diffusion.cpp/build-static/bin/sd-cli.arm64 ]; then
        lipo -create -output vendor/stable-diffusion.cpp/build-static/bin/sd-cli \
            vendor/stable-diffusion.cpp/build-static/bin/sd-cli.x86_64 \
            vendor/stable-diffusion.cpp/build-static/bin/sd-cli.arm64
        rm vendor/stable-diffusion.cpp/build-static/bin/sd-cli.{x86_64,arm64}
    fi
    echo "universal engines ready"
    exit 0
fi

# Build the two upstream engines with their existing, unchanged patch workflow.
# SKIP_IMAGE prevents build-engines.sh from also rebuilding the upstream SD fork.
SKIP_IMAGE=1 "$ROOT/scripts/build-engines.sh"

# Build the maintained SD fork directly. No patches/ are applied to this tree.
build_image_engine
