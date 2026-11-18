set -euo pipefail
mode=$1
driver=$2
shift 2

if [[ $mode == link ]]; then
    out=$1
    deps=$2
    shift 2
    info=$deps.ld
    trap 'rm -f "$info"' EXIT
    args=()
    while (($#)); do
        if [[ $1 == --native-library ]]; then
            shift
            for input in "${args[@]}"; do
                if [[ $input == "$1" ]]; then shift; continue 2; fi
            done
        fi
        args+=("$1")
        shift
    done
    "$driver" "${args[@]}" -Xlinker -dependency_info -Xlinker "$info" -o "$out"
    {
        printf 'linked:'
        while IFS= read -r -d '' record; do
            [[ $record == $'\x10'* ]] || continue
            path=${record:1}
            path=${path//\\/\\\\}
            path=${path// /\\ }
            path=${path//#/\\#}
            path=${path//:/\\:}
            printf ' %s' "${path//\$/\$\$}"
        done
        printf '\n'
    } < "$info" > "$deps"
    exit
fi

dirs=()
frameworks=()
for arg in "$@"; do
    case $arg in
        -L?*) dirs+=("${arg#-L}") ;;
        -F?*) frameworks+=("${arg#-F}") ;;
    esac
done
sdk=$("$driver" -print-sysroot)
dirs+=("$sdk/usr/lib")
if [[ -n ${HOMEBREW_PREFIX:-} ]]; then dirs+=("$HOMEBREW_PREFIX/lib"); fi
frameworks+=("$sdk/System/Library/Frameworks" "$sdk/Library/Frameworks")

emit() {
    local arg
    for arg in "$@"; do
        arg=${arg//\\/\\\\}
        printf '"%s"\n' "${arg//\"/\\\"}"
    done
}
selected() {
    case $1 in
        needed) emit -Xlinker -needed_library -Xlinker "$2" ;;
        weak) emit -Xlinker -weak_library -Xlinker "$2" ;;
        normal) emit "$2" ;;
    esac
}
library_in_dir() {
    local dir=$1 name=$2 mode=$3 strength=$4 file
    local candidates=("$dir/lib$name.a")
    if [[ $mode == dynamic ]]; then
        candidates=("$dir/lib$name.tbd" "$dir/lib$name.dylib" "$dir/lib$name.so")
    fi
    for file in "${candidates[@]}"; do
        if [[ -f $file ]]; then
            if [[ $mode == static ]]; then emit "$file"; else selected "$strength" "$file"; fi
            return
        fi
    done
    return 1
}
library() {
    local name=$1 mode=$2 strategy=$3 strength=$4 dir candidate_mode
    local modes=("$mode")
    if [[ $strategy != no_fallback ]]; then
        if [[ $mode == static ]]; then modes+=(dynamic); else modes+=(static); fi
    fi
    if [[ $strategy == paths_first ]]; then
        for dir in "${dirs[@]}"; do
            for candidate_mode in "${modes[@]}"; do
                if library_in_dir "$dir" "$name" "$candidate_mode" "$strength"; then return; fi
            done
        done
    else
        for candidate_mode in "${modes[@]}"; do
            for dir in "${dirs[@]}"; do
                if library_in_dir "$dir" "$name" "$candidate_mode" "$strength"; then return; fi
            done
        done
    fi
    echo "Darwin $mode library not found: $name" >&2
    return 1
}
framework() {
    local name=$1 strength=$2 dir file
    for dir in "${frameworks[@]}"; do
        for file in "$dir/$name.framework/$name.tbd" "$dir/$name.framework/$name"; do
            if [[ -f $file ]]; then selected "$strength" "$file"; return; fi
        done
    done
    echo "Darwin framework not found: $name" >&2
    return 1
}
while (($#)); do
    case $1 in
        --system-library) library "$2" "$3" "$4" "$5"; shift 5 ;;
        --framework) framework "$2" "$3"; shift 3 ;;
        *) emit "$1"; shift ;;
    esac
done
