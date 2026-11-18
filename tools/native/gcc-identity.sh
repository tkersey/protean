#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
fail() { printf '%s\n' "$*" >&2; exit 1; }
if [[ $# -ge 3 && $1 == capture ]]; then
  output=$2
  shift 2
  candidate=$(mktemp "${output}.XXXXXXXX")
  trap 'rm -f "$candidate"' EXIT
  "$@" > "$candidate"
  if [[ ! -f $output ]] || ! cmp -s "$candidate" "$output"; then mv -f "$candidate" "$output"; fi
  exit 0
fi

if command -v sha256sum >/dev/null; then sha=(sha256sum)
elif command -v shasum >/dev/null; then sha=(shasum -a 256)
else fail 'native-gcc requires sha256sum or shasum'; fi
digest() { "${sha[@]}" | cut -d' ' -f1; }

if [[ $# == 6 && $1 == record ]]; then
  compiler=$(<"$2")
  [[ $compiler == *'}' ]] || fail 'invalid GCC probe result'
  printf '%s,"translation_units":{' "${compiler%\}}"
  shift 2
  for role in sqlite posix_shim; do
    body=$(sed -E '/^# [0-9]+ "/d' "$1" | digest)
    object=$(digest < "$2")
    printf '"%s":{"preprocessed_body_sha256":"%s","object_sha256":"%s"}' "$role" "$body" "$object"
    [[ $role == posix_shim ]] || printf ','
    shift 2
  done
  printf '}}\n'
  exit 0
fi

[[ $# == 2 ]] || fail 'expected GCC driver and target'
driver=$1
target=$2
macros=$("$driver" -dM -E -x c - </dev/null)
has_macro() { grep -Eq "^#define $1 " <<<"$macros"; }
if ! has_macro __GNUC__ || has_macro __clang__; then fail "native-gcc requires GNU GCC"; fi
case "$target" in
  x86_64-linux*-musl)
    if ! has_macro __linux__ || ! has_macro __x86_64__ || has_macro __ILP32__; then
      fail "expected x86_64-linux-musl GCC"
    fi
    "$driver" -E -x c - -o /dev/null <<'C' || fail "native-gcc must use x86-64 musl headers"
#include <features.h>
#if defined(__GLIBC__) || defined(__UCLIBC__) || defined(__BIONIC__)
#error expected musl headers
#endif
#define __NEED_size_t
#include <bits/alltypes.h>
#ifndef __DEFINED_size_t
#error expected musl alltypes
#endif
C
    ;;
  *) fail "unsupported native-gcc target $target" ;;
esac

version=$("$driver" -dumpfullversion)
machine=$("$driver" -dumpmachine)
[[ $version =~ ^[0-9.]+$ && $machine =~ ^[a-zA-Z0-9._-]+$ ]] || fail "invalid GCC identity"
configuration=$("$driver" -v -E -x c - -o /dev/null </dev/null 2>&1)
component() {
  local file hash
  if [[ $1 == specs ]]; then file=$2
  else file=$(command -v -- "$2") || fail "cannot locate GCC component: $2"; fi
  hash=$(digest < "$file") || fail "cannot hash GCC component: $file"
  printf '%s %s\n' "$1" "$hash"
}
toolchain_inputs() {
  local line cc1 assembler
  set -e
  printf '%s\n' "$version" "$machine" "$macros"
  "$driver" -dumpspecs
  component launcher "$driver"
  while IFS= read -r line; do
    case "$line" in
      'Reading specs from '*) component specs "${line#Reading specs from }" ;;
      COLLECT_GCC=*) component driver "${line#COLLECT_GCC=}" ;;
    esac
  done <<<"$configuration"
  cc1=$("$driver" -print-prog-name=cc1)
  assembler=$("$driver" -print-prog-name=as)
  component cc1 "$cc1"
  component assembler "$assembler"
}
toolchain=$(toolchain_inputs | digest)
printf '{"family":"gcc","version":"%s","driver_machine":"%s","toolchain_sha256":"%s"}\n' \
  "$version" "$machine" "$toolchain"
