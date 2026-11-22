#!/usr/bin/env bash
set -euo pipefail

auditor_revision=ac19a3fabd0b32fae3f6bf1becf5368c724e96f3
auditor_url=https://github.com/tkersey/skills-zig.git

unset_repository_environment() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE \
        GIT_PREFIX GIT_SHALLOW_FILE GIT_CEILING_DIRECTORIES GIT_NAMESPACE GIT_QUARANTINE_PATH GIT_ATTR_SOURCE
    export GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0
}

selected_zig() {
    local exe
    exe=$(type -P -- "${PROTEAN_ZIG_EXE-zig}") || {
        printf 'TigerStyle cannot find the selected Zig executable: %s\n' "${PROTEAN_ZIG_EXE-zig}" >&2
        return 1
    }
    [[ "$exe" == /* ]] || exe="$PWD/$exe"
    printf '%s\n' "$exe"
}

auditor_transport() {
    local source=${PROTEAN_QUALIFICATION_GIT_SOURCE:-.} result
    if [[ -n ${PROTEAN_QUALIFICATION_GIT_SOURCE:-} ]]; then
        git -C "$source" rev-parse --git-dir > /dev/null || return 1
    fi
    git -C "$source" config --includes -z --get-regexp '^(url|http|https|credential|protocol|transfer)\.|^core\.(sshcommand|gitproxy|askpass)$' || {
        result=$?
        [[ $result == 1 ]] || return "$result"
    }
}

fetch_auditor() (
    local destination=$1 record key value
    local settings="$destination.transport"
    auditor_transport > "$settings"
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
    while IFS= read -r -d '' record; do
        key=${record%%$'\n'*}
        value=true
        if [[ "$record" == *$'\n'* ]]; then value=${record#*$'\n'}; fi
        export "GIT_CONFIG_KEY_$GIT_CONFIG_COUNT=$key" "GIT_CONFIG_VALUE_$GIT_CONFIG_COUNT=$value"
        GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
    done < "$settings"
    git init --quiet --object-format=sha1 --template= "$destination"
    local -a auditor_git=(git -C "${PROTEAN_QUALIFICATION_GIT_SOURCE:-.}" --git-dir="$destination/.git" --work-tree="$destination" -c core.hooksPath=/dev/null)
    "${auditor_git[@]}" fetch --quiet --no-tags --depth=1 "$auditor_url" "$auditor_revision"
    "${auditor_git[@]}" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
    if [[ "$("${auditor_git[@]}" rev-parse HEAD)" != "$auditor_revision" ]]; then
        printf 'TigerStyle auditor revision mismatch.\n' >&2
        return 1
    fi
)

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
unset_repository_environment
zig=$(selected_zig)
if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'Usage: bash tools/tiger-style.sh BASE|--all [HEAD]\n' >&2
    exit 64
fi

repository=$(git rev-parse --show-toplevel)
cd "$repository"

head=$(git rev-parse --verify --end-of-options "${2:-HEAD}^{commit}")
if [[ "$1" == --all ]]; then
    base=$head
else
    base=$(git rev-parse --verify --end-of-options "$1^{commit}")
fi
if [[ "$head" != "$(git rev-parse --verify HEAD)" ]]; then
    printf 'TigerStyle requires HEAD to be the requested candidate.\n' >&2
    exit 1
fi
if ! git diff --quiet --no-ext-diff --no-textconv "$head" -- ||
    ! git diff --cached --quiet --no-ext-diff --no-textconv "$head" --; then
    printf 'TigerStyle requires a clean committed candidate; commit tracked changes first.\n' >&2
    exit 1
fi
base=$(git merge-base "$base" "$head")

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

git diff --no-ext-diff --no-textconv --name-only -z --diff-filter=T \
    "$base" "$head" -- ':(glob)**/*.zig' > "$scratch/type-changes"
if [[ -s "$scratch/type-changes" ]]; then
    printf 'TigerStyle cannot audit changed Zig file types; preserve regular source files.\n' >&2
    exit 1
fi

git diff --no-ext-diff --no-textconv --no-renames --numstat -z \
    --diff-filter=ACMR "$base" "$head" -- ':(glob)**/*.zig' > "$scratch/changes"
while IFS= read -r -d '' change; do
    if [[ "$change" == $'-\t-\t'* ]]; then
        printf 'TigerStyle cannot audit a binary-classified Zig change: %s\n' "$change" >&2
        exit 1
    fi
done < "$scratch/changes"

fetch_auditor "$scratch/auditor"

printf 'TigerStyle: base=%s head=%s auditor=%s\n' "$base" "$head" "$auditor_revision"
"$zig" test "$scratch/auditor/tools/tiger_style/main.zig"
if [[ "$1" == --all ]]; then
    paths=()
    git ls-files --stage -z -- '*.zig' > "$scratch/sources"
    while IFS= read -r -d '' entry; do
        metadata=${entry%%$'\t'*}
        path=${entry#*$'\t'}
        mode=${metadata%% *}
        if [[ "$mode" != 100644 && "$mode" != 100755 ]] ||
            [[ ! -f "$path" || -L "$path" ]]; then
            printf 'TigerStyle requires regular tracked Zig files: %s\n' "$path" >&2
            exit 1
        fi
        paths+=("$path")
    done < "$scratch/sources"
    if [[ ${#paths[@]} -eq 0 ]]; then
        printf 'TigerStyle requires at least one tracked Zig file.\n' >&2
        exit 1
    fi
    "$zig" run "$scratch/auditor/tools/tiger_style/main.zig" -- audit-files "${paths[@]}"
    exit
fi
"$zig" run "$scratch/auditor/tools/tiger_style/main.zig" -- \
    audit-diff --base "$base" --head "$head"
