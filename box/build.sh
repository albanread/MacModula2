#!/bin/sh
# build.sh -- Modula-2 for the BOX: libm2-box.a, which rosgd's
# modules/modula2 links into /init.  See design/BOX_PORT.md.
#
#   sh box/build.sh [aarch64|x86_64] [check]
#
# Rust for <arch>-unknown-linux-musl (cargo, the crate box/: newm2-box, a
# staticlib), against the box's own LLVM 22: the NCL set that A7232ToolChain's
# deps/build-llvm-libs-box.sh makes with LLVM_FOR_NCL=1 (MCJIT), in
# BOX/caches (LLVM_PREFIX names another).  C, where a crate has any, is
# compiled by zig 0.15 (ZIG, default ~/zig015/zig).
#
# Then a partial link of the Rust archive with LLVM's archives, and
# llvm-objcopy makes every symbol but box/exports.txt local, so that nothing
# of Rust's, the compiler's or LLVM's meets one of /init's.  libc++ and
# libunwind are left to /init's link (zig's, -lc++), which has them already.
#
# Output: $M2_OUT (default BOX/caches/modula2/out-<arch>): libm2-box.a and
# m2_box.h.  The standard library goes to $M2_OUT/lib (the ROM's
# /usr/lib/modula2).
set -eu
arch=${1:-aarch64}
mode=${2:-build}
here=$(cd "$(dirname "$0")/.." && pwd)            # the checkout
box_root=$(cd "$here/../.." && pwd)               # BOX (BOX/src/<checkout>)
case $arch in
    aarch64) triple=aarch64-linux-musl; rust_target=aarch64-unknown-linux-musl
             cargo_env=AARCH64_UNKNOWN_LINUX_MUSL; cc_env=aarch64_unknown_linux_musl
             llvm_def=$box_root/caches/arm-mac/llvm-libs-box-ncl ;;
    x86_64)  triple=x86_64-linux-musl; rust_target=x86_64-unknown-linux-musl
             cargo_env=X86_64_UNKNOWN_LINUX_MUSL; cc_env=x86_64_unknown_linux_musl
             llvm_def=$box_root/caches/intel-mac/llvm-libs-box-x86_64-ncl ;;
    *) echo "build.sh: aarch64 or x86_64" >&2; exit 2 ;;
esac
ZIG=${ZIG:-$HOME/zig015/zig}
case "$("$ZIG" version)" in 0.15.*) ;; *) echo "build.sh: $ZIG is not zig 0.15" >&2; exit 2 ;; esac
LLVM_PREFIX=${LLVM_PREFIX:-$llvm_def}
[ -f "$LLVM_PREFIX/lib/libLLVMMCJIT.a" ] || {
    echo "build.sh: no MCJIT in $LLVM_PREFIX (A7232ToolChain: LLVM_FOR_NCL=1 sh deps/build-llvm-libs-box.sh)" >&2; exit 2; }
HB=/opt/homebrew/opt/llvm@22/bin
OBJCOPY=${OBJCOPY:-$(ls $HB/llvm-objcopy 2>/dev/null || command -v llvm-objcopy)}
AR=${AR:-$(ls $HB/llvm-ar 2>/dev/null || command -v llvm-ar)}
LLD=${LLD:-$(command -v ld.lld)}
out=${M2_OUT:-$box_root/caches/modula2/out-$arch}
tgt=${M2_TARGET_DIR:-$box_root/caches/modula2/target}
w=$tgt/zig-$arch
mkdir -p "$out/obj" "$w"

# cc and ar for the crates' C: zig, for the box's triple
cat > "$w/cc" <<EOW
#!/bin/sh
n=\$#
skip=0
while [ \$n -gt 0 ]; do
    a=\$1; shift; n=\$((n - 1))
    if [ \$skip = 1 ]; then skip=0; continue; fi
    case \$a in
        --target=*|-Wl,--fix-cortex-a53-843419) ;;
        -target) skip=1 ;;
        -lstdc++) set -- "\$@" -lc++ ;;
        *) set -- "\$@" "\$a" ;;
    esac
done
exec "$ZIG" cc -target $triple "\$@"
EOW
printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$w/ar"
chmod +x "$w/cc" "$w/ar"
export ZIG_GLOBAL_CACHE_DIR=$tgt/zig-cache

cd "$here"
cmd=build
[ "$mode" = check ] && cmd=check
env LLVM_SYS_221_PREFIX="$LLVM_PREFIX" \
    "CC_$cc_env=$w/cc" "CXX_$cc_env=$w/cc" "AR_$cc_env=$w/ar" \
    "CARGO_TARGET_${cargo_env}_LINKER=$w/cc" \
    CARGO_TARGET_DIR="$tgt" \
    cargo $cmd --release --target $rust_target -p newm2-box
[ "$mode" = check ] && exit 0

rlib=$tgt/$rust_target/release/libnewm2_box.a
echo "link: the Rust archive with LLVM's ($(du -k "$rlib" | cut -f1) KB)"
llvm_libs=$(ls "$LLVM_PREFIX"/lib/libLLVM*.a)
"$LLD" -r -o "$out/obj/m2_all.o" --whole-archive "$rlib" --no-whole-archive \
    --start-group $llvm_libs --end-group
"$OBJCOPY" --keep-global-symbols=box/exports.txt "$out/obj/m2_all.o" "$out/obj/m2_box.o"
rm -f "$out/libm2-box.a"
"$AR" rcs "$out/libm2-box.a" "$out/obj/m2_box.o"
cp box/m2_box.h "$out/"

# The standard library, as the ROM carries it (/usr/lib/modula2)
rm -rf "$out/lib"
mkdir -p "$out/lib"
for d in isodef isomod pimdef pimmod rtdef utildef utilmod ulibdef ulibmod shareddef sharedmod boxdef boxmod; do
    [ -d "library/$d" ] && cp -R "library/$d" "$out/lib/"
done
echo "== $out/libm2-box.a: $(du -k "$out/libm2-box.a" | cut -f1) KB; library $(find "$out/lib" -type f | wc -l | tr -d ' ') files"
