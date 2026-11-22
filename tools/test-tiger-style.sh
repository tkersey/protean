#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

scratch=
unchanged=false
finish() {
    local status=$?
    if [[ -n $scratch ]]; then rm -rf "$scratch" || exit 1; fi
    if [[ $status == 77 && $unchanged != true ]]; then
        printf 'TigerStyle integration failed with reserved status 77.\n' >&2
        exit 1
    fi
}
trap finish EXIT

launcher_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
launcher="$launcher_dir/tiger-style.sh"
source "$launcher"
unset_repository_environment
export PROTEAN_ZIG_EXE
PROTEAN_ZIG_EXE=$(selected_zig)
cache=
if [[ $# != 0 ]]; then
    if [[ $# != 2 || "$1" != --if-changed ]]; then
        printf 'Usage: bash tools/test-tiger-style.sh [--if-changed CACHE]\n' >&2
        exit 64
    fi
    if [[ -d "$2" ]]; then cache=$(cd -- "$2" && pwd); fi
fi
cd -- "$launcher_dir/.."

hash_ca_file() {
    local path=$1
    [[ -n $path ]] || return 0
    [[ $path == /* ]] || path="${PROTEAN_QUALIFICATION_GIT_SOURCE:-.}/$path"
    [[ -f "$path" ]] || return 1
    git hash-object --no-filters -- "$path"
}

launcher_environment() (
    uname -smrv || return 1
    git config --list --includes --show-origin -z || return 1
    local record key path
    auditor_transport | while IFS= read -r -d '' record; do
        printf '%s\0' "$record"
        key=${record%%$'\n'*}
        case "$key" in http.*sslcainfo|http.*sslcapath)
            path=$(git -C "${PROTEAN_QUALIFICATION_GIT_SOURCE:-.}" config --includes --type=path --get "$key") || exit 1
            hash_ca_file "$path" || exit 1 ;;
        esac
    done || return 1
    for path in "${GIT_SSL_CAINFO:-}" "${GIT_SSL_CAPATH:-}" "${GIT_PROXY_SSL_CAINFO:-}" "${CURL_CA_BUNDLE:-}" "${SSL_CERT_FILE:-}" "${SSL_CERT_DIR:-}"; do
        if [[ -n $path ]]; then hash_ca_file "$path" || return 1; fi
    done
    env -0 | while IFS= read -r -d '' setting; do
        case "$setting" in
            GIT_*=*|ZIG_*=*|PROTEAN_QUALIFICATION_GIT_SOURCE=*|PROTEAN_ZIG_EXE=*|DYLD_*=*|LD_*=*|XDG_*=*|BASH*=*|SHELLOPTS=*|\
            *PROXY=*|*proxy=*|SSH_*=*|SSL_*=*|CURL_*=*|CPATH=*|*_INCLUDE_PATH=*|LIBRARY_PATH=*|\
            PATH=*|HOME=*|TMPDIR=*|SDKROOT=*|DEVELOPER_DIR=*|MACOSX_DEPLOYMENT_TARGET=*)
                printf '%s\0' "$setting" ;;
        esac
    done | sort -z || return 1
    local command
    for command in git grep mktemp rm ln dirname cat bash env sort tar mv uname; do
        git hash-object --no-filters -- "$(type -P -- "$command")" || return 1
    done
    git hash-object --no-filters -- "$BASH" "$PROTEAN_ZIG_EXE" || return 1
    if [[ $(uname -s) == Darwin ]]; then xcrun --show-sdk-build-version || return 1; fi
    COPYFILE_DISABLE=1 tar -chf - -C "$ZIG_LIB_DIR" .
)

clean_candidate() {
    local status path flags
    [[ "$(git rev-parse --show-toplevel)" == "$PWD" ]] || return 1
    flags=$(git ls-files -v) || return 1
    [[ $'\n'$flags != *$'\n'[a-zS]' '* ]] || return 1
    status=$(git -c core.fsmonitor=false -c core.untrackedCache=false status --porcelain=v1 --untracked-files=all --ignore-submodules=none) || return 1
    [[ -z $status ]] || return 1
    for path in tools/tiger-style.sh tools/test-tiger-style.sh; do
        [[ -f "$path" && ! -L "$path" ]] || return 1
        [[ "$(git hash-object --no-filters -- "$path")" == "$(git rev-parse --verify "HEAD:$path")" ]] || return 1
    done
    git rev-parse --verify HEAD
}

receipt=
if [[ -n $cache && -d ${ZIG_LIB_DIR:-} && -z ${BASH_ENV:-} ]] && candidate=$(clean_candidate) &&
    environment=$(launcher_environment | git hash-object --stdin); then
    receipt="$cache/tigerstyle-launcher-pass"
    if [[ -f "$receipt" ]] && read -r base previous < "$receipt" &&
        [[ $base =~ ^[[:xdigit:]]{40}([[:xdigit:]]{24})?$ && $previous == "$environment" ]] &&
        git merge-base --is-ancestor "$base" "$candidate" &&
        git diff --quiet --no-ext-diff --no-textconv "$base" "$candidate" -- tools/tiger-style.sh tools/test-tiger-style.sh \
            .github/workflows .github/actions .gitattributes .gitmodules .gitignore \
            build.zig build.zig.zon build_native.zig build_protean.zig tools/native/qualify.mjs \
            tools/native/qualification_process.mjs tools/native/qualification_workspace.mjs \
            .zigversion .zig-version .tool-versions mise.toml .mise.toml
    then
        echo "TigerStyle launcher inputs match the successful integration at $base."
        unchanged=true
        exit 77
    fi
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style-test.XXXXXXXX")
fetch_auditor "$scratch/auditor"
(
unset PROTEAN_QUALIFICATION_GIT_SOURCE
for variable in $(compgen -A export GIT_); do unset "$variable"; done
export GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$scratch/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$scratch/auditor/.insteadOf" "$auditor_url"
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
if ! GIT_DIR="$scratch/auditor/.git" GIT_WORK_TREE="$scratch/auditor" GIT_INDEX_FILE="$scratch/foreign-index" \
    bash "$launcher" "$base" HEAD > "$scratch/result" 2>&1; then
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
)
if [[ -n "$receipt" && "$(clean_candidate)" == "$candidate" ]] &&
    current_environment=$(launcher_environment | git hash-object --stdin) && [[ $environment == "$current_environment" ]]; then
    temporary=$(mktemp "$receipt.XXXXXXXX")
    printf '%s %s\n' "$candidate" "$environment" > "$temporary"
    mv -f "$temporary" "$receipt"
fi
