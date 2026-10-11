#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
observed=$(mktemp "${TMPDIR:-/tmp}/protean-zig-paths.XXXXXX")
expected=$(mktemp "${TMPDIR:-/tmp}/protean-zig-paths-expected.XXXXXX")
trap 'rm -f "$observed" "$expected"' EXIT

cd "$repo_root"
rg --files -g '*.zig' -g '!zig-cache/**' -g '!zig-out/**' -g '!zig-pkg/**' | sort >"$observed"
if [ -e .git ]; then
    cp repo_zig_paths.txt "$expected"
else
    while IFS= read -r path; do
        if [ -f "$path" ]; then
            printf '%s\n' "$path"
        fi
    done <repo_zig_paths.txt >"$expected"
fi
cmp -s "$expected" "$observed" || {
    diff -u "$expected" "$observed" >&2 || true
    printf '%s\n' 'repo_zig_paths.txt does not cover the current Zig source graph' >&2
    exit 1
}
