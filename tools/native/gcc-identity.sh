#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
driver=$1
target=$2
macros=$("$driver" -dM -E -x c - </dev/null)
has_macro() { grep -Eq "^#define $1 " <<<"$macros"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
if ! has_macro __GNUC__ || has_macro __clang__; then fail "native-gcc requires GNU GCC"; fi
case "$target" in
  x86_64-linux*-musl)
    if ! has_macro __linux__ || ! has_macro __x86_64__; then fail "expected x86_64-linux-musl GCC"; fi
    headers=$("$driver" -include features.h -dM -E -x c - </dev/null)
    if grep -Eq '^#define (__GLIBC__|__UCLIBC__|__BIONIC__) ' <<<"$headers"; then
      fail "native-gcc must use musl headers"
    fi
    link=$("$driver" -### -x c - -o /dev/null </dev/null 2>&1)
    grep -Fq '/ld-musl-x86_64.so.1' <<<"$link" || fail "native-gcc must target musl"
    ;;
  *) fail "unsupported native-gcc target $target" ;;
esac
version=$("$driver" -dumpfullversion)
machine=$("$driver" -dumpmachine)
[[ $version =~ ^[0-9.]+$ && $machine =~ ^[a-zA-Z0-9._-]+$ ]] || fail "invalid GCC identity"
configuration=$("$driver" -v -E -x c - -o /dev/null </dev/null 2>&1)
digest=$({
  set -e
  printf '%s\n' "$configuration" "$macros"
  "$driver" -dumpspecs
  shasum -a 256 "$driver"
  while IFS= read -r spec; do
    [[ -r $spec ]] || fail "cannot read GCC specs file: $spec"
    shasum -a 256 "$spec"
  done < <(sed -n 's/^Reading specs from //p' <<<"$configuration")
  for tool in "$(sed -n 's/^COLLECT_GCC=//p' <<<"$configuration")" \
      "$("$driver" -print-prog-name=cc1)" "$("$driver" -print-prog-name=as)"; do
    component=$(command -v "$tool") || fail "cannot locate GCC component: $tool"
    shasum -a 256 "$component"
  done
} | shasum -a 256)
printf '{"family":"gcc","version":"%s","driver_machine":"%s","toolchain_sha256":"%s"}\n' \
  "$version" "$machine" "${digest%% *}"
