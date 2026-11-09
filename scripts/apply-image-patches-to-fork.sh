#!/bin/bash
#
# Create a persistent ToshLLM branch in CloverHackyColor/stable-diffusion.cpp
# and CloverHackyColor/ggml, then import the image-engine patch series as
# individual Git commits.
#
# Run from anywhere:
#   ./scripts/apply-image-patches-to-fork.sh
#
# Optional:
#   SD_DIR=/path/to/stable-diffusion.cpp
#   SD_COMMIT=2f88688
#   SD_BRANCH=tosh
#
# The script never checks out, resets, or modifies either repository's master
# branch. It refuses dirty worktrees and existing target branches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SD_REPO="${SD_REPO:-https://github.com/CloverHackyColor/stable-diffusion.cpp.git}"
GGML_REPO="${GGML_REPO:-https://github.com/CloverHackyColor/ggml.git}"
SD_DIR="${SD_DIR:-$ROOT/../stable-diffusion.cpp}"
SD_COMMIT="${SD_COMMIT:-421b29e}"
SD_BRANCH="${SD_BRANCH:-tosh}"
PATCH_ROOT="$ROOT/patches"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

require_file() {
    [ -f "$1" ] || die "Required patch not found: $1"
}

is_dirty() {
    [ -n "$(git -C "$1" status --porcelain --untracked-files=all)" ]
}

check_git_identity() {
    git -C "$1" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
        die "Git author identity is not configured in $1. Set user.name and user.email first."
}

# Commit changes independently in the GGML submodule and in stable-diffusion.cpp.
# The parent commit records the updated GGML gitlink as well as any top-level
# stable-diffusion.cpp files changed by the same patch.
commit_patch() {
    local message="$1"
    local ggml_changed=0
    local parent_changed=0

    if is_dirty "$SD_DIR/ggml"; then
        git -C "$SD_DIR/ggml" add -A
        if ! git -C "$SD_DIR/ggml" diff --cached --quiet; then
            git -C "$SD_DIR/ggml" commit -m "$message"
            ggml_changed=1
        fi
    fi

    if is_dirty "$SD_DIR"; then
        git -C "$SD_DIR" add -A
        if ! git -C "$SD_DIR" diff --cached --quiet; then
            git -C "$SD_DIR" commit -m "$message"
            parent_changed=1
        fi
    fi

    if [ "$ggml_changed" -eq 0 ] && [ "$parent_changed" -eq 0 ]; then
        echo "    No source changes from this patch; no commit was necessary."
    fi
}

apply_patch() {
    local patch="$1"
    local include_path="${2:-}"
    local message="tosh: apply ${patch#$ROOT/}"

    info "Applying ${patch#$ROOT/}"
    if [ -n "$include_path" ]; then
        git -C "$SD_DIR" apply --include="$include_path" -p1 "$patch"
    else
        git -C "$SD_DIR" apply -p1 "$patch"
    fi
    commit_patch "$message"
}

# The shared Metal series intentionally has four hunks that do not fit this
# older GGML revision. The original build script applies the matching hunks
# with --reject, then supplies adapted versions in image/0002.
apply_shared_metal_patch() {
    local patch="$1"
    local message="tosh: apply ${patch#$ROOT/}"

    info "Applying shared Metal patch ${patch#$ROOT/}"
    (
        cd "$SD_DIR"
        if git apply --reject \
            --exclude='ggml/src/ggml-metal/ggml-metal-impl.h' \
            --include='ggml/src/ggml-metal/*' \
            -p1 "$patch"; then
            :
        else
            # A non-zero status is expected when one or more hunks are rejected.
            :
        fi
    )

    # Remember the rejected filenames for the exact compatibility check below.
    find "$SD_DIR/ggml/src/ggml-metal" -name '*.rej' -exec basename {} \; \
        >> "$REJECTS_FILE"

    # Reject/orig files are diagnostics, not source. The rejected hunks are
    # supplied by patches/image/0002-image-metal-divergent-hunks.patch.
    find "$SD_DIR/ggml" \( -name '*.rej' -o -name '*.orig' \) -delete

    commit_patch "$message"
}

# ----- Validate inputs and repository state -----

[ -d "$PATCH_ROOT" ] || die "Cannot find ToshLLM patches directory: $PATCH_ROOT"

for patch in \
    "$PATCH_ROOT/image/0002-image-metal-divergent-hunks.patch" \
    "$PATCH_ROOT/shared-metal/0001-7-metal-backend-host.patch" \
    "$PATCH_ROOT/image/0003-image-metal-ncb.patch" \
    "$PATCH_ROOT/image/0004-image-cpu-fallback-sched.patch" \
    "$PATCH_ROOT/image/0008-image-ext-wave64.patch" \
    "$PATCH_ROOT/image/0021-image-metal-im2col-3d.patch" \
    "$PATCH_ROOT/image/0047-image-fa-unet-heads.patch" \
    "$PATCH_ROOT/image/0049-image-free-diffusion-before-video-decode.patch" \
    "$PATCH_ROOT/image/0050-image-vae-tile-yield.patch" \
    "$PATCH_ROOT/image/0051-image-loader-pread.patch" \
    "$PATCH_ROOT/image/0052-image-bf16-promote-without-bfloat.patch" \
    "$PATCH_ROOT/image/0053-image-lora-f16-weight-cast.patch" \
    "$PATCH_ROOT/image/0055-image-metal-live-vram-report.patch" \
    "$PATCH_ROOT/image/0056-image-metal-half-partials.patch" \
    "$PATCH_ROOT/image/0057-image-qwen21-fused-swiglu.patch" \
    "$PATCH_ROOT/image/0058-image-metal-cpy-contiguous.patch" \
    "$PATCH_ROOT/image/0059-image-qwen21-rope-table.patch" \
    "$PATCH_ROOT/image/0060-image-qwen21-prefix-f16.patch" \
    "$PATCH_ROOT/image/0061-image-qwen21-down-f16.patch" \
    "$PATCH_ROOT/image/0062-image-qwen21-f16-inputs.patch" \
    "$PATCH_ROOT/image/0063-image-qwen21-v-view.patch" \
    "$PATCH_ROOT/image/0064-image-metal-im2col.patch" \
    "$PATCH_ROOT/image/0065-image-metal-cpy-transpose.patch" \
    "$PATCH_ROOT/image/0066-image-metal-fa-nomask.patch" \
    "$PATCH_ROOT/image/0067-image-metal-mm-band.patch"
do
    require_file "$patch"
done

shared_patches=("$PATCH_ROOT"/shared-metal/0001-*.patch)
[ -f "${shared_patches[0]}" ] || die "No patches found in patches/shared-metal/0001-*.patch"

if [ ! -d "$SD_DIR/.git" ]; then
    info "Cloning $SD_REPO into $SD_DIR"
    mkdir -p "$(dirname "$SD_DIR")"
    git clone "$SD_REPO" "$SD_DIR"
fi

git -C "$SD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "$SD_DIR is not a Git working tree"

if is_dirty "$SD_DIR"; then
    die "stable-diffusion.cpp has local changes. Commit or stash them before running this script."
fi

SD_ORIGIN="$(git -C "$SD_DIR" remote get-url origin 2>/dev/null || true)"
case "$SD_ORIGIN" in
    *CloverHackyColor/stable-diffusion.cpp*) ;;
    *) die "origin of $SD_DIR is '$SD_ORIGIN', expected CloverHackyColor/stable-diffusion.cpp" ;;
esac

check_git_identity "$SD_DIR"

info "Fetching stable-diffusion.cpp"
git -C "$SD_DIR" fetch origin

git -C "$SD_DIR" cat-file -e "${SD_COMMIT}^{commit}" 2>/dev/null ||
    die "Base commit '$SD_COMMIT' is not available after fetching origin"

# Create the branch directly at the pinned commit. This leaves local master
# exactly where it was; it is never checked out or reset.
info "Creating $SD_BRANCH at stable-diffusion.cpp commit $SD_COMMIT"
if git -C "$SD_DIR" show-ref --verify --quiet "refs/heads/$SD_BRANCH"; then
    echo "==> Using existing stable-diffusion.cpp branch $SD_BRANCH"
    git -C "$SD_DIR" switch "$SD_BRANCH"

    if ! git -C "$SD_DIR" merge-base --is-ancestor "$SD_COMMIT" HEAD; then
        echo "ERROR: Branch $SD_BRANCH is not based on $SD_COMMIT"
        exit 1
    fi
else
    echo "==> Creating $SD_BRANCH at stable-diffusion.cpp commit $SD_COMMIT"
    git -C "$SD_DIR" switch --detach "$SD_COMMIT"
    git -C "$SD_DIR" switch -c "$SD_BRANCH"
fi

# Initialize the GGML gitlink recorded by the selected stable-diffusion.cpp
# commit before changing its remote URL.
info "Initializing the pinned GGML submodule"
git -C "$SD_DIR" submodule sync --recursive
git -C "$SD_DIR" submodule update --init --recursive

[ -d "$SD_DIR/ggml/.git" ] || git -C "$SD_DIR/ggml" rev-parse --git-dir >/dev/null 2>&1 ||
    die "GGML submodule was not initialized correctly"

if is_dirty "$SD_DIR/ggml"; then
    die "GGML submodule has local changes immediately after initialization."
fi

check_git_identity "$SD_DIR/ggml"

# Persist the fork URL in .gitmodules, then configure the already initialized
# submodule to use the same remote.
info "Switching the GGML submodule to CloverHackyColor/ggml"
git -C "$SD_DIR" config -f .gitmodules submodule.ggml.url "$GGML_REPO"
git -C "$SD_DIR" add .gitmodules

if ! git -C "$SD_DIR" diff --cached --quiet; then
    git -C "$SD_DIR" commit -m "Use CloverHackyColor GGML fork"
else
    echo "==> .gitmodules already configured"
fi
git -C "$SD_DIR" submodule sync -- ggml
git -C "$SD_DIR/ggml" remote set-url origin "$GGML_REPO"
git -C "$SD_DIR/ggml" fetch origin

# Branch GGML from the exact submodule commit pinned by stable-diffusion.cpp.
GGML_DIR="$SD_DIR/ggml"
GGML_BASE="$(git -C "$GGML_DIR" rev-parse HEAD)"

info "Preparing GGML branch $SD_BRANCH at $GGML_BASE"

if git -C "$GGML_DIR" show-ref --verify --quiet "refs/heads/$SD_BRANCH"; then
    info "Using existing GGML branch $SD_BRANCH"
    git -C "$GGML_DIR" switch "$SD_BRANCH"

    if ! git -C "$GGML_DIR" merge-base --is-ancestor "$GGML_BASE" HEAD; then
        die "GGML branch $SD_BRANCH is not based on $GGML_BASE"
    fi
else
    info "Creating GGML branch $SD_BRANCH at $GGML_BASE"
    git -C "$GGML_DIR" switch --detach "$GGML_BASE"
    git -C "$GGML_DIR" switch -c "$SD_BRANCH"
fi

REJECTS_FILE="$(mktemp -t tosh-image-rejects)"
trap 'rm -f "$REJECTS_FILE"' EXIT

# ----- Apply shared Metal patches in the same order as build-engines.sh -----

for patch in "${shared_patches[@]}"; do
    apply_shared_metal_patch "$patch"
done

expected_rejects="$(printf '%s\n' \
    ggml-metal-device.cpp.rej \
    ggml-metal-device.m.rej \
    ggml-metal.cpp.rej \
    ggml-metal.metal.rej | sort)"
got_rejects="$(sort -u "$REJECTS_FILE")"

if [ "$got_rejects" != "$expected_rejects" ]; then
    echo "ERROR: shared Metal patch rejects differ from the expected set." >&2
    echo "  expected:" >&2
    printf '%s\n' "$expected_rejects" >&2
    echo "  got:" >&2
    printf '%s\n' "$got_rejects" >&2
    die "Inspect the shared-metal patches and image/0002 before continuing."
fi

# Apply the four adapted hunks that do not fit this older GGML revision.
apply_patch "$PATCH_ROOT/image/0002-image-metal-divergent-hunks.patch" 'ggml/src/ggml-metal/*'

# The impl.h portion was deliberately excluded from the shared series above;
# it applies with reduced context, exactly as in build-engines.sh.
info "Applying the GGML Metal host patch to ggml-metal-impl.h"
(
    cd "$SD_DIR"
    git apply --include='ggml/src/ggml-metal/ggml-metal-impl.h' -C2 -p1 \
        "$PATCH_ROOT/shared-metal/0001-7-metal-backend-host.patch"
)
commit_patch "tosh: apply shared-metal/0001-7-metal-backend-host.patch (impl.h)"

# Remaining patches, in the exact order used by build-engines.sh.
apply_patch "$PATCH_ROOT/image/0003-image-metal-ncb.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0004-image-cpu-fallback-sched.patch"
apply_patch "$PATCH_ROOT/image/0008-image-ext-wave64.patch"
apply_patch "$PATCH_ROOT/image/0021-image-metal-im2col-3d.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0047-image-fa-unet-heads.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0049-image-free-diffusion-before-video-decode.patch"
apply_patch "$PATCH_ROOT/image/0050-image-vae-tile-yield.patch"
apply_patch "$PATCH_ROOT/image/0051-image-loader-pread.patch"
apply_patch "$PATCH_ROOT/image/0052-image-bf16-promote-without-bfloat.patch"
apply_patch "$PATCH_ROOT/image/0053-image-lora-f16-weight-cast.patch"
apply_patch "$PATCH_ROOT/image/0055-image-metal-live-vram-report.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0056-image-metal-half-partials.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0057-image-qwen21-fused-swiglu.patch"
apply_patch "$PATCH_ROOT/image/0058-image-metal-cpy-contiguous.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0059-image-qwen21-rope-table.patch"
apply_patch "$PATCH_ROOT/image/0060-image-qwen21-prefix-f16.patch"
apply_patch "$PATCH_ROOT/image/0061-image-qwen21-down-f16.patch"
apply_patch "$PATCH_ROOT/image/0062-image-qwen21-f16-inputs.patch"
apply_patch "$PATCH_ROOT/image/0063-image-qwen21-v-view.patch"
apply_patch "$PATCH_ROOT/image/0064-image-metal-im2col.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0065-image-metal-cpy-transpose.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0066-image-metal-fa-nomask.patch" 'ggml/src/ggml-metal/*'
apply_patch "$PATCH_ROOT/image/0067-image-metal-mm-band.patch" 'ggml/src/ggml-metal/*'

# Retain the original build script's sanity checks. They catch a patch landing
# in the wrong kernel/function even when git apply itself exits successfully.
info "Checking the resulting Metal source"

metal="$SD_DIR/ggml/src/ggml-metal/ggml-metal.metal"
impl="$SD_DIR/ggml/src/ggml-metal/ggml-metal-impl.h"

awk '/^kernel void kernel_cumsum_blk\(/,/\{$/' "$metal" |
    grep -q 'sgptg\[\[threads_per_simdgroup\]\]' ||
    die "Patch landed incorrectly: kernel_cumsum_blk is missing sgptg."

awk '/ggml_metal_kargs_flash_attn_ext_vec;/{exit} {print}' "$impl" |
    grep -q 'int32_t  has_mask;' ||
    die "Patch landed incorrectly: flash_attn_ext_vec is missing has_mask."

# No reject/orig files should remain in the final source tree.
if find "$SD_DIR/ggml" \( -name '*.rej' -o -name '*.orig' \) | grep -q .; then
    die "Temporary .rej/.orig files remain in the GGML tree."
fi

if is_dirty "$SD_DIR/ggml"; then
    die "GGML has uncommitted changes after patching."
fi
if is_dirty "$SD_DIR"; then
    die "stable-diffusion.cpp has uncommitted changes after patching."
fi

info "Patch series completed"
echo "stable-diffusion.cpp:"
git -C "$SD_DIR" log -1 --oneline
echo "GGML:"
git -C "$SD_DIR/ggml" log -1 --oneline
echo
echo "Branch '$SD_BRANCH' is ready in:"
echo "  $SD_DIR"
echo "  $SD_DIR/ggml"
echo
echo "No push was performed. Review the commits, then push both repositories:"
echo "  git -C \"$SD_DIR/ggml\" push -u origin \"$SD_BRANCH\""
echo "  git -C \"$SD_DIR\" push -u origin \"$SD_BRANCH\""
