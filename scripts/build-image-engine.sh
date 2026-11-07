#!/bin/zsh
# Builds only the stable-diffusion.cpp image engine from the CloverHackyColor fork
# with AMD/FLUX3 support already integrated into the code.
#
# Usage:
#   ./scripts/build-image-engine.sh                  # host architecture
#   ARCH=x86_64 ./scripts/build-image-engine.sh      # cross-compile
#   ARCH=universal ./scripts/build-image-engine.sh   # x86_64 + arm64 fat binaries

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

# Use the CloverHackyColor fork with AMD/FLUX3 support
#SD_REPO="${SD_REPO:-https://github.com/CloverHackyColor/stable-diffusion.cpp}"
#SD_COMMIT="${SD_COMMIT:-master}"  # Your branch with integrated patches

# Use the original leejet repository with the commit validated against patches
SD_REPO="${SD_REPO:-https://github.com/leejet/stable-diffusion.cpp}"
SD_COMMIT="${SD_COMMIT:-2f88688}"  # Validated commit for image engine patches

ARCH="${ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="14.0"

if [ "$ARCH" = "universal" ]; then
    # Build each slice separately and lipo them
    for slice in x86_64 arm64; do
        ARCH="$slice" "$0"
    done
    
    local vendor="vendor/stable-diffusion.cpp"
    [ -d "$vendor/build-static/bin" ] || exit 0
    
    for tool in sd-cli; do
        mv "$vendor/build-static/bin/$tool" "$vendor/build-static/bin/$tool.$slice" 2>/dev/null || true
    done
    
    for tool in sd-cli; do
        if [ -f "$vendor/build-static/bin/$tool.x86_64" ] && [ -f "$vendor/build-static/bin/$tool.arm64" ]; then
            lipo -create -output "$vendor/build-static/bin/$tool" \
                "$vendor/build-static/bin/$tool.x86_64" "$vendor/build-static/bin/$tool.arm64"
            rm "$vendor/build-static/bin/$tool".{x86_64,arm64}
        fi
    done
    
    echo "universal image engine ready"
    exit 0
fi

# Metal toolchain setup (same as build-engines.sh)
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
    echo "Metal compiler available — will precompile default.metallib (fast model load)"
else
    METAL_PRECOMPILE=0
    echo "Metal compiler unavailable — embedded source only (slower first load)"
fi

TOSH_VERSION="$(tr -d '[:space:]' < "$(dirname "$0")/../VERSION")"

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

# ISA flags for x86_64
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

# Build stable-diffusion.cpp from the fork
vendor="vendor/stable-diffusion.cpp"

if [ ! -d "$vendor/.git" ]; then
    echo "Cloning CloverHackyColor/stable-diffusion.cpp fork..."
    retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
        git clone --recursive "$SD_REPO" "$vendor"
fi

cd "$vendor"

echo "Fetching latest changes from fork..."
retry_git git fetch origin

echo "Checking out $SD_COMMIT..."
git checkout -qf "$SD_COMMIT"
git reset --hard "$SD_COMMIT"

# Remove untracked files from previous patch attempts.
# Do not use -x: build-static is ignored and may survive.
git clean -qfd 2>/dev/null || true

# IMPORTANT:
# Do NOT use --remote here. We need the exact ggml commit recorded by this SD commit.
git submodule sync --recursive
retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
    git submodule update --init --recursive --force

# Clean submodules too. Patch-created files can remain there otherwise.
git submodule foreach --recursive 'git reset --hard; git clean -fd'

echo "stable-diffusion.cpp commit:"
git log --oneline -1

echo "ggml submodule commit:"
git -C ggml log --oneline -1

echo "Applying image engine patches..."
for patch in "$ROOT"/patches/image/*.patch(N); do
    [ -f "$patch" ] || continue

    if git apply --check "$patch" >/tmp/sd-image-patch-check.log 2>&1; then
        git apply "$patch"
        echo "✅ applied ${patch#$ROOT/patches/}"
    elif git apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "ℹ️  already applied ${patch#$ROOT/patches/}"
    else
        echo "❌ failed ${patch#$ROOT/patches/}"
        cat /tmp/sd-image-patch-check.log
        echo
        echo "Patch series is not compatible with this checkout. Stop."
        exit 1
    fi
done

# Configure and build
local isa=("${ISA_FLAGS[@]}")
reset_stale_cmake_cache build-static

echo "Configuring with cmake..."
cmake -B build-static \
    -DCMAKE_BUILD_TYPE=Release \
    -DSD_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    "${isa[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_CXX_FLAGS="-DTOSH_VERSION=$TOSH_VERSION -Wno-unused-const-variable -Wno-unused-function" \
    -DCMAKE_C_FLAGS="-Wno-unused-const-variable -Wno-unused-function"

echo "Building sd-cli..."
cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli

# Precompile Metal shaders for faster first load.
# The new ggml generates one .metal file per kernel instead of one merged file.
local embed_dir="build-static/ggml/src/ggml-metal/autogenerated"
if [ "$METAL_PRECOMPILE" = 1 ] && [ -n "$(echo $embed_dir/ggml-metal-embed-*.metal(N))" ]; then
    local kernels="build-static/bin/kernels"
    rm -rf "$kernels"
    mkdir -p "$kernels"
    local ok=1
    if resolve_metal_toolchain; then
        for src in $embed_dir/ggml-metal-embed-*.metal; do
            local name="${${src:t:r}#ggml-metal-embed-}"
            "$METAL_COMPILER" -O3 -Wno-unused-const-variable -Wno-unused-function -mmacosx-version-min=14.0 -std=metal3.1 \
            -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
            -I ggml/src -I ggml/src/ggml-metal \
            -c "$src" -o "$kernels/$name.air" &&
            "$METALLIB_COMPILER" "$kernels/$name.air" -o "$kernels/$name.metallib" || { ok=0; break; }
            # the engine loads a library only if its source matches the one embedded in the binary
            echo "$name $(shasum -a 256 "$src" | cut -d' ' -f1)" >> "$kernels/fingerprint"
        done
    else
        ok=0
    fi
    rm -f "$kernels"/*.air
    if [ "$ok" = 1 ]; then
        echo "precompiled $(ls "$kernels" | wc -l | tr -d ' ') metal libraries ($(du -sh "$kernels" | cut -f1))"
    else
        rm -rf "$kernels"
        echo "WARNING: metallib precompile failed — falling back to runtime compile"
        METAL_PRECOMPILE=0
    fi
fi
echo "image engine ready at $PWD/build-static/bin (arch: $ARCH)"
cd "$ROOT"
