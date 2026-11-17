/^    return zig_make_i128\(zig_shr_i64\(arg, 63\), \(uint(8|16|32)_t\)arg\);$/ {
    if (++seen[$0] != 1) exit 1
    sub(/uint(8|16|32)_t/, "uint64_t")
    ++fixed
}
{ print }
END {
    if (fixed != 3) {
        print "expected three signed-widening helpers in Zig 0.17.1 zig.h" > "/dev/stderr"
        exit 1
    }
}
