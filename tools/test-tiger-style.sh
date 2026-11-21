#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

launcher_environment() (
    set -euo pipefail
    uname -smrv || return 1
    git config --list --includes --show-origin -z || return 1
    env | grep -E '^(GIT_|ZIG_|DYLD_|LD_|XDG_|BASH_FUNC_|SHELLOPTS=|BASHOPTS=|CPATH=|C_INCLUDE_PATH=|LIBRARY_PATH=|PATH=|HOME=|TMPDIR=|SDKROOT=|DEVELOPER_DIR=|MACOSX_DEPLOYMENT_TARGET=)' | sort || return 1
    git hash-object --no-filters -- "$BASH" "$(type -P git)" "$(type -P zig)" \
        "$(type -P grep)" "$(type -P mktemp)" "$(type -P rm)" "$(type -P ln)" "$(type -P dirname)" \
        "$(type -P cat)" "$(type -P bash)" || return 1
    if [[ $(uname -s) == Darwin ]]; then xcrun --show-sdk-build-version || return 1; fi
    COPYFILE_DISABLE=1 tar -cf - -C "$ZIG_LIB_DIR" .
)

receipt=
if [[ $# == 1 && -d "$1" && -d ${ZIG_LIB_DIR:-} && -z ${BASH_ENV:-} ]]; then
    candidate=$(git rev-parse --verify HEAD)
    if environment=$(launcher_environment | git hash-object --stdin); then
        receipt="$(cd -- "$1" && pwd)/tigerstyle-launcher-pass"
        if [[ -f "$receipt" ]] && read -r base previous < "$receipt" &&
            [[ $base =~ ^[[:xdigit:]]{40}([[:xdigit:]]{24})?$ && $previous == "$environment" ]] &&
            git merge-base --is-ancestor "$base" "$candidate" &&
            git diff --quiet --no-ext-diff --no-textconv "$base" "$candidate" -- tools/tiger-style.sh tools/test-tiger-style.sh \
                .github/workflows .github/actions .gitattributes .gitmodules .gitignore \
                build.zig build.zig.zon build_native.zig build_protean.zig tools/native/qualify.mjs \
                .zigversion .zig-version .tool-versions mise.toml .mise.toml
        then
            echo "TigerStyle launcher inputs match the successful integration at $base."
            exit 0
        fi
    fi
fi

launcher=$(cd -- "$(dirname -- "$0")" && pwd)/tiger-style.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export GIT_ATTR_NOSYSTEM=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TEMPLATE_DIR=
git init --quiet --template= "$scratch/repository"
cd "$scratch/repository"
git config user.name TigerStyle
git config user.email tiger-style@example.invalid
git config commit.gpgsign false
git config core.hooksPath /dev/null
git config core.attributesFile /dev/null
git config core.excludesFile /dev/null

commit_fixture() {
    git add --all
    git commit --quiet -m "$1"
}

expect_failure() {
    local expected=$1
    shift
    if bash "$launcher" "$@" > "$scratch/result" 2>&1; then
        printf 'Expected TigerStyle failure: %s\n' "$expected" >&2
        cat "$scratch/result" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$scratch/result"; then
        cat "$scratch/result" >&2
        exit 1
    fi
}

printf 'fn legacy() void { while (true) {} }\n' > legacy.zig
printf 'const value = true;\n' > existing.zig
printf 'fn hidden() void { while (true) {} }\n' > source.txt
printf '/.zig-cache/\n' > .gitignore
commit_fixture baseline
base=$(git rev-parse HEAD)

printf 'const value = false;\n' > existing.zig
commit_fixture valid
if ! bash "$launcher" "$base" HEAD > "$scratch/result" 2>&1; then
    cat "$scratch/result" >&2
    exit 1
fi
grep -Fq 'TigerStyle passed:' "$scratch/result"
valid=$(git rev-parse HEAD)
expect_failure 'tiger-style/loop-bound' --all HEAD

printf 'fn legacy() void {}\n' > legacy.zig
commit_fixture whole-file-valid
if ! bash "$launcher" --all HEAD > "$scratch/result" 2>&1; then
    cat "$scratch/result" >&2
    exit 1
fi
grep -Fq 'TigerStyle passed:' "$scratch/result"
git reset --quiet --hard "$valid"

expect_failure 'requires HEAD to be the requested candidate' "$base" "$base"
expect_failure 'Needed a single revision' tiger-style-missing-revision HEAD

printf 'const edited = true;\n' >> existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git add existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git show "$valid:existing.zig" > existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'fn bad() void { fail() catch unreachable; }\n' >> existing.zig
commit_fixture added-line
expect_failure 'tiger-style/error-handling' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'fn recurse() void {\n    recurse();\n}\n' > new.zig
commit_fixture new-file
expect_failure 'tiger-style/recursion' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'existing.zig -diff\n' > .gitattributes
printf 'const value = 1;\n' > existing.zig
commit_fixture binary-zig
expect_failure 'cannot audit a binary-classified Zig change' "$base" HEAD
git reset --quiet --hard "$valid"

rm existing.zig
ln -s source.txt existing.zig
commit_fixture source-type
expect_failure 'cannot audit changed Zig file types' "$base" HEAD
expect_failure 'requires regular tracked Zig files' --all HEAD

printf 'TigerStyle integration passed: full-source and diff audits, revisions, index/worktree, binary/type changes.\n'
if [[ -n "$receipt" ]]; then
    temporary=$(mktemp "$receipt.XXXXXXXX")
    printf '%s %s\n' "$candidate" "$environment" > "$temporary"
    mv -f "$temporary" "$receipt"
fi
