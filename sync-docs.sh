#!/usr/bin/env bash
# sync-docs.sh — Pull latest documentation from upstream MystenLabs repos
#
# Usage: ./sync-docs.sh [--dry-run]
#
# Requires: gh (GitHub CLI), tar, find
#
# Upstream sources:
#   Sui          -> MystenLabs/sui              docs/content/                    -> .sui-docs/
#   Walrus       -> MystenLabs/walrus           docs/content/                    -> .walrus-docs/
#   Seal         -> MystenLabs/seal             docs/content/                    -> .seal-docs/
#   TS SDK       -> MystenLabs/ts-sdks          packages/docs/content/           -> .ts-sdk-docs/
#   Move Book    -> MystenLabs/move-book        book/, reference/, packages/     -> .move-book-docs/
#   Sui Prover   -> asymptotic-code/sui-prover  .claude/skills/sui-prover/       -> .sui-prover-docs/guide/
#                -> asymptotic-code/sui-prover  packages/prover/sources/         -> .sui-prover-docs/sources/
#                -> asymptotic-code/sui-kit     examples/                        -> .sui-prover-docs/examples/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Binary extensions to strip (useless for AI text consumption)
BINARY_EXTENSIONS=(png jpg jpeg gif svg excalidraw webp ico bmp tiff)

strip_binaries() {
    local dir="$1"
    for ext in "${BINARY_EXTENSIONS[@]}"; do
        find "$dir" -name "*.$ext" -delete 2>/dev/null || true
    done
    # Remove empty directories left behind
    find "$dir" -type d -empty -delete 2>/dev/null || true
}

# Resolve a GitHub tarball's dynamic top-level directory (e.g.
# "mystenlabs-sui-9a3f1c2/"). Used to extract a wanted subtree by *exact
# member path* rather than a glob.
#
# Why exact paths instead of `--include=GLOB`: `--include` is a bsdtar
# (macOS) option. GNU tar — which the Ubuntu CI runner ships — does not
# recognize it, so the old `tar ... --include=... 2>/dev/null || true`
# errored, the error was swallowed, 0 files extracted, and the data-loss
# guard aborted the whole sync. That is why the weekly "Refresh upstream
# docs" job never once succeeded in CI while local macOS syncs worked.
# Both GNU tar and bsdtar extract a named directory member recursively and
# honor --strip-components, so the exact-path approach is portable with no
# flavor detection.
tarball_top() {
    tar tzf "$1" 2>/dev/null | head -1 | cut -d/ -f1
}

sync_repo() {
    local owner="$1"
    local repo="$2"
    local upstream_path="$3"   # e.g. "docs/content"
    local local_dir="$4"       # e.g. ".sui-docs"
    local label="$5"           # e.g. "Sui"

    echo "[$label] Downloading tarball from $owner/$repo..."
    local tarball="$TMPDIR_BASE/${repo}.tar.gz"
    gh api "repos/$owner/$repo/tarball/main" > "$tarball"

    echo "[$label] Extracting $upstream_path/..."
    local extract_dir="$TMPDIR_BASE/${repo}-extract"
    mkdir -p "$extract_dir"

    # Tarball has a top-level dir like "owner-repo-hash/"
    # Extract only the docs/content subtree, stripping the top-level + upstream path components
    local strip_count
    strip_count=$(echo "$upstream_path" | tr '/' '\n' | wc -l | tr -d ' ')
    strip_count=$((strip_count + 1))  # +1 for the top-level "owner-repo-hash" dir

    local top
    top=$(tarball_top "$tarball") || true
    if [[ -z "$top" ]]; then
        echo "[$label] WARNING: could not read tarball top-level dir! Skipping."
        return 1
    fi

    # stderr left visible on purpose — extracting an exact member is silent on
    # success, so anything printed here is a real failure worth seeing (the
    # old 2>/dev/null is what hid the --include break). The count guard below
    # still decides whether to abort.
    tar xzf "$tarball" -C "$extract_dir" --strip-components="$strip_count" \
        "$top/$upstream_path" || true

    # Count extracted files. `.move` is accepted because the prover corpus
    # syncs construct-source subtrees (packages/prover/sources/) that contain
    # only .move files — the gate must not refuse them as "empty content".
    local count
    count=$(find "$extract_dir" -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.move' \) | wc -l | tr -d ' ')
    echo "[$label] Extracted $count MDX/MD/move files"

    if [[ "$count" -eq 0 ]]; then
        echo "[$label] WARNING: No files extracted! Skipping to avoid data loss."
        return 1
    fi

    if $DRY_RUN; then
        echo "[$label] DRY RUN — would replace $local_dir/ with $count files"
        return 0
    fi

    # Strip binaries from extracted content
    strip_binaries "$extract_dir"

    local md_count
    md_count=$(find "$extract_dir" -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.pdf' -o -name '*.move' \) | wc -l | tr -d ' ')
    echo "[$label] After stripping binaries: $md_count text files"

    # Replace local directory (mkdir parent so nested layouts like
    # `.sui-prover-docs/guide` work even when the parent doesn't exist yet)
    mkdir -p "$(dirname "$local_dir")"
    rm -rf "$local_dir"
    mv "$extract_dir" "$local_dir"
    echo "[$label] Updated $local_dir/"
}

# Like sync_repo, but extracts multiple upstream subdirectories from one
# tarball into a single local_dir, preserving each upstream subdir's name.
# Useful for repos with multiple top-level prose roots (e.g. move-book has
# both book/ and reference/, plus packages/ source examples referenced from
# the prose). Pass upstream_paths as a comma-separated list.
sync_repo_multi() {
    local owner="$1"
    local repo="$2"
    local upstream_paths="$3"  # e.g. "book,reference,packages"
    local local_dir="$4"
    local label="$5"

    echo "[$label] Downloading tarball from $owner/$repo..."
    local tarball="$TMPDIR_BASE/${repo}.tar.gz"
    gh api "repos/$owner/$repo/tarball/main" > "$tarball"

    local extract_dir="$TMPDIR_BASE/${repo}-extract"
    mkdir -p "$extract_dir"

    local top
    top=$(tarball_top "$tarball") || true
    if [[ -z "$top" ]]; then
        echo "[$label] WARNING: could not read tarball top-level dir! Skipping."
        return 1
    fi

    # Strip only the top-level "owner-repo-hash/" dir so each upstream path
    # lands as $extract_dir/<path>/... Members are passed as exact paths
    # ("$top/<path>") rather than `--include` globs — see tarball_top() for
    # why (GNU tar on the CI runner has no --include).
    local IFS_SAVE="$IFS"
    IFS=','
    local members=()
    for p in $upstream_paths; do
        echo "[$label] Extracting $p/..."
        members+=("$top/${p}")
    done
    IFS="$IFS_SAVE"

    # stderr is intentionally NOT suppressed: extracting exact named members
    # produces no output on success, so any message here is a real failure
    # (missing member, tar quirk) we want surfaced rather than hidden behind
    # the downstream "0 files extracted" guard — that opacity is what let the
    # original --include break go unnoticed for the life of the CI job.
    tar xzf "$tarball" -C "$extract_dir" --strip-components=1 \
        "${members[@]}" || true

    local md_count
    md_count=$(find "$extract_dir" -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.move' \) | wc -l | tr -d ' ')
    echo "[$label] Extracted $md_count MDX/MD/move files (plus any other content from the included paths)"

    if [[ "$md_count" -eq 0 ]]; then
        echo "[$label] WARNING: No MDX/MD/move files extracted! Skipping to avoid data loss."
        return 1
    fi

    if $DRY_RUN; then
        echo "[$label] DRY RUN — would replace $local_dir/ with extracted content"
        return 0
    fi

    strip_binaries "$extract_dir"

    mkdir -p "$(dirname "$local_dir")"
    rm -rf "$local_dir"
    mv "$extract_dir" "$local_dir"
    echo "[$label] Updated $local_dir/"
}

echo "=== sui-pilot doc sync ==="
echo ""

sync_repo       "MystenLabs"      "sui"        "docs/content"             ".sui-docs"               "Sui"
sync_repo       "MystenLabs"      "walrus"     "docs/content"             ".walrus-docs"            "Walrus"
sync_repo       "MystenLabs"      "seal"       "docs/content"             ".seal-docs"              "Seal"
sync_repo       "MystenLabs"      "ts-sdks"    "packages/docs/content"    ".ts-sdk-docs"            "TS SDK"

# Hashi (@mysten/hashi — Bitcoin collateralization SDK) ships in
# packages/hashi but has no pages under packages/docs/content yet, so the
# TS SDK sync above misses it. Pull its README as the corpus entry until
# upstream adds real docs pages. Runs after the TS SDK sync because that
# step replaces .ts-sdk-docs/ wholesale.
if $DRY_RUN; then
    echo "[TS SDK] DRY RUN — would add .ts-sdk-docs/hashi/README.md"
else
    mkdir -p .ts-sdk-docs/hashi
    gh api -H "Accept: application/vnd.github.raw+json" \
        "repos/MystenLabs/ts-sdks/contents/packages/hashi/README.md" \
        > "$TMPDIR_BASE/hashi-readme.md"
    [ -s "$TMPDIR_BASE/hashi-readme.md" ] || { echo "[TS SDK] ERROR: fetched hashi README is empty" >&2; exit 1; }
    mv "$TMPDIR_BASE/hashi-readme.md" .ts-sdk-docs/hashi/README.md
    echo "[TS SDK] Added hashi README -> .ts-sdk-docs/hashi/README.md"
fi
sync_repo_multi "MystenLabs"      "move-book"  "book,reference,packages"  ".move-book-docs"         "Move Book"
sync_repo       "asymptotic-code" "sui-prover" ".claude/skills/sui-prover" ".sui-prover-docs/guide"   "Sui Prover Guide"
sync_repo       "asymptotic-code" "sui-prover" "packages/prover/sources"   ".sui-prover-docs/sources" "Sui Prover Sources"
sync_repo       "asymptotic-code" "sui-kit"    "examples"                  ".sui-prover-docs/examples" "Sui Prover Examples"

echo ""
echo "=== Sync complete ==="
echo ""
echo "File counts:"
for dir in .sui-docs .walrus-docs .seal-docs .ts-sdk-docs .move-book-docs .sui-prover-docs; do
    if [[ -d "$dir" ]]; then
        count=$(find "$dir" -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.move' \) 2>/dev/null | wc -l | tr -d ' ')
        echo "  $dir: $count MDX/MD/move files"
    else
        echo "  $dir: (not present — skipped)"
    fi
done
if [[ -d .move-book-docs ]]; then
    move_book_indexed=$(find .move-book-docs -type f \( -name '*.mdx' -o -name '*.md' \) -not -path '.move-book-docs/packages/*' 2>/dev/null | wc -l | tr -d ' ')
    echo "    (.move-book-docs indexed subset, excluding packages/: $move_book_indexed)"
fi

# Record sync timestamp
if ! $DRY_RUN; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > .last-sync << EOF
{
  "syncTimestamp": "$TIMESTAMP",
  "sources": {
    "sui": "MystenLabs/sui@main",
    "walrus": "MystenLabs/walrus@main",
    "seal": "MystenLabs/seal@main",
    "ts-sdks": "MystenLabs/ts-sdks@main",
    "move-book": "MystenLabs/move-book@main",
    "ts-sdks-hashi": "MystenLabs/ts-sdks@main:packages/hashi/README.md",
    "sui-prover-guide": "asymptotic-code/sui-prover@main:.claude/skills/sui-prover",
    "sui-prover-sources": "asymptotic-code/sui-prover@main:packages/prover/sources",
    "sui-prover-examples": "asymptotic-code/sui-kit@main:examples"
  },
  "fileCounts": {
    "sui": $(find .sui-docs -type f \( -name '*.mdx' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' '),
    "walrus": $(find .walrus-docs -type f \( -name '*.mdx' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' '),
    "seal": $(find .seal-docs -type f \( -name '*.mdx' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' '),
    "ts-sdks": $(find .ts-sdk-docs -type f \( -name '*.mdx' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' '),
    "move-book": $(find .move-book-docs -type f \( -name '*.mdx' -o -name '*.md' \) -not -path '.move-book-docs/packages/*' 2>/dev/null | wc -l | tr -d ' '),
    "sui-prover": $(find .sui-prover-docs -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.move' \) 2>/dev/null | wc -l | tr -d ' ')
  }
}
EOF
    echo ""
    echo "Recorded sync timestamp to .last-sync"
fi

