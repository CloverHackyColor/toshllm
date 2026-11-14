#!/bin/bash
#
# Create a persistent ToshLLM branch in CloverHackyColor/llama.cpp
# and apply every patch from patches/llama as an individual Git commit.
#
# Run from anywhere:
#   ./scripts/apply-llama-patches-to-fork.sh
#
# Optional:
#   LLAMA_DIR=/path/to/llama.cpp
#   LLAMA_COMMIT=d81235049384534c167caea52b85a694f6103d14
#   LLAMA_BRANCH=tosh
#   LLAMA_REPO=https://github.com/CloverHackyColor/llama.cpp.git
#
# The script does not modify master.
# It refuses dirty worktrees and refuses to reuse a branch that has
# already diverged from the requested base commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LLAMA_REPO="${LLAMA_REPO:-https://github.com/CloverHackyColor/llama.cpp.git}"
LLAMA_DIR="${LLAMA_DIR:-$ROOT/../llama.cpp}"
LLAMA_COMMIT="${LLAMA_COMMIT:-d81235049384534c167caea52b85a694f6103d14}"
LLAMA_BRANCH="${LLAMA_BRANCH:-tosh}"

PATCH_DIR="$ROOT/patches/llama"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

is_dirty() {
    [ -n "$(git -C "$1" status --porcelain --untracked-files=all)" ]
}

check_git_identity() {
    git -C "$1" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
        die "Git author identity is not configured. Set user.name and user.email first."
}

# Use exactly the same patch ordering as build-engines.sh:
# sort by patch filename, independently of directory traversal order.
patch_series() {
    find "$PATCH_DIR" -type f -name '*.patch' -print |
        awk -F/ '{print $NF "\t" $0}' |
        sort |
        cut -f2-
}

# Commit all changes introduced by the current patch.
commit_patch() {
    local message="$1"

    git -C "$LLAMA_DIR" add -A

    if git -C "$LLAMA_DIR" diff --cached --quiet; then
        die "Patch produced no staged changes: $message"
    fi

    git -C "$LLAMA_DIR" commit -m "$message"
}

apply_patch() {
    local patch="$1"
    local relative_path="${patch#"$ROOT"/}"
    local message="tosh: apply $relative_path"
    local commit

    commit="$(git -C "$LLAMA_DIR" log -1 \
        --format='%H' \
        --grep="^${message}$" \
        HEAD)"

    if [ -n "$commit" ]; then
        info "Already committed, skipping $relative_path ($commit)"
        return 0
    fi

    info "Applying $relative_path"

    # Check first, so a failed patch does not leave a partially modified tree.
#    git -C "$LLAMA_DIR" apply --check -p1 "$patch"
    git -C "$LLAMA_DIR" apply -p1 "$patch"



    commit_patch "$message"
}

# Collect patches before changing anything.
[ -d "$PATCH_DIR" ] ||
    die "Patch directory not found: $PATCH_DIR"

patches=()
while IFS= read -r patch; do
    [ -n "$patch" ] && patches+=("$patch")
done < <(patch_series)

[ "${#patches[@]}" -gt 0 ] ||
    die "No .patch files found in $PATCH_DIR"

info "Found ${#patches[@]} llama.cpp patches"

# Clone the user's fork if the local repository does not exist.
if [ ! -d "$LLAMA_DIR/.git" ]; then
    info "Cloning $LLAMA_REPO into $LLAMA_DIR"
    mkdir -p "$(dirname "$LLAMA_DIR")"
    git clone "$LLAMA_REPO" "$LLAMA_DIR"
fi

git -C "$LLAMA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "$LLAMA_DIR is not a Git working tree"

# Never overwrite local changes.
if is_dirty "$LLAMA_DIR"; then
    die "llama.cpp has local changes. Commit or stash them before running this script."
fi

# Verify that origin points to the intended fork.
LLAMA_ORIGIN="$(git -C "$LLAMA_DIR" remote get-url origin 2>/dev/null || true)"

case "$LLAMA_ORIGIN" in
    *CloverHackyColor/llama.cpp*)
        ;;
    *)
        die "origin is '$LLAMA_ORIGIN', expected CloverHackyColor/llama.cpp"
        ;;
esac

check_git_identity "$LLAMA_DIR"

info "Fetching llama.cpp fork"
git -C "$LLAMA_DIR" fetch origin

# Verify that the selected base commit is available locally.
git -C "$LLAMA_DIR" cat-file -e "${LLAMA_COMMIT}^{commit}" 2>/dev/null ||
    die "Base commit '$LLAMA_COMMIT' is not available. Check LLAMA_COMMIT and fetch."

# Create the target branch, or reuse it only if it is exactly at the base.
if git -C "$LLAMA_DIR" show-ref --verify --quiet "refs/heads/$LLAMA_BRANCH"; then
    info "Checking existing branch $LLAMA_BRANCH"

    git -C "$LLAMA_DIR" switch "$LLAMA_BRANCH"

    CURRENT_HEAD="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
    BASE_HEAD="$(git -C "$LLAMA_DIR" rev-parse "$LLAMA_COMMIT")"

    [ "$CURRENT_HEAD" = "$BASE_HEAD" ] ||
        die "Branch '$LLAMA_BRANCH' is not at the requested base commit.
It was not reset or modified.
Current: $CURRENT_HEAD
Expected: $BASE_HEAD"
else
    info "Creating branch $LLAMA_BRANCH from $LLAMA_COMMIT"
    git -C "$LLAMA_DIR" switch -c "$LLAMA_BRANCH" "$LLAMA_COMMIT"
fi

# Verify that the selected base contains the embedded GGML tree.
GGML_ENTRY="$(git -C "$LLAMA_DIR" ls-tree "$LLAMA_COMMIT" ggml)"

case "$GGML_ENTRY" in
    "040000 tree "*)
        echo "Embedded GGML tree found in llama.cpp."
        ;;
    *)
        die "Expected ggml/ to be a directory in the selected llama.cpp commit."
        ;;
esac

# Apply and commit every patch separately.
for patch in "${patches[@]}"; do
    apply_patch "$patch"
done

info "Patch series completed"

echo
echo "llama.cpp:"
git -C "$LLAMA_DIR" log -n "${#patches[@]}" --oneline

echo
echo "Branch:"
git -C "$LLAMA_DIR" branch --show-current

echo
echo "Working tree:"
git -C "$LLAMA_DIR" status --short

echo
echo "All patches have been applied and committed."
echo "The master branch was not changed."
echo
echo "To push the branch:"
echo "  git -C \"$LLAMA_DIR\" push -u origin \"$LLAMA_BRANCH\""
