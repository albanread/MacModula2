#!/bin/sh
# hostcheck.sh -- the Intel box's code, checked on an Arm Mac (no x86 box
# may run here): box/tests/*.mod compiled by the box's own front end and
# code generator (newm2-box's m2-hostcheck, with LLVM's X86 backend) for
# x86_64-unknown-linux-musl, as the box's MCJIT makes code (the large code
# model), then checked:
#   - each object is ELF x86-64;
#   - no call or reference reaches outside the object by a 32-bit
#     PC-relative relocation (the JIT's code may be anywhere: the large
#     model's 64-bit absolute R_X86_64_64 only, or the GOT);
#   - every name an object needs is one the box's JIT binds (newm2-llvm's
#     bind(...) list, static_dl's C routines) or LLVM's own.
#
#   sh box/hostcheck.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
box_root=$(cd "$here/../.." && pwd)
HB=/opt/homebrew/opt/llvm@22/bin
out=${M2_OUT:-$box_root/caches/modula2/hostcheck}
mkdir -p "$out"
cd "$here"
CARGO_TARGET_DIR=$box_root/caches/modula2/target-host cargo build -q --release -p newm2-box --features x86-check --bin m2-hostcheck
"$box_root/caches/modula2/target-host/release/m2-hostcheck" x86_64-unknown-linux-musl "$here/library" "$out" "$here"/box/tests/*.mod
# the names the JIT binds, and static_dl's
grep -oE 'bind\("[^"]+"' src/newm2-llvm/src/lib.rs | sed 's/bind("//;s/"$//' > "$out/bound.txt"
grep -oE '"[A-Za-z0-9_.]+"\.to_string\(\), *"[a-z0-9_]+"' src/newm2-llvm/src/lib.rs | sed 's/^"\([^"]*\)".*/\1/' >> "$out/bound.txt"
sed -n '/table!(/,/);/p' src/newm2-llvm/src/static_dl.rs | tr ',' '\n' | tr -d ' ();' | grep -E '^[a-z_]' >> "$out/bound.txt"
# names bound as EXTERNAL procedures' addresses (win32_compat::resolve)
grep -oE '^ *"[A-Za-z]+" => Some' src/newm2-runtime/src/win32_compat.rs | grep -oE '[A-Za-z]+' | grep -v Some >> "$out/bound.txt"
bad=0
for o in "$out"/*.o; do
    f=$("$HB/llvm-objdump" -f "$o" | grep -o 'file format .*')
    case $f in *elf64-x86-64*) ;; *) echo "FAIL $o: $f"; bad=1 ;; esac
    pc=$("$HB/llvm-objdump" -r "$o" | grep -E 'R_X86_64_(PC32|PLT32|GOTPCREL)' | awk '{print $3}' | grep -v '^\.' || true)
    for s in $pc; do
        # a PC-relative reference to a name defined in the object is fine
        if ! "$HB/llvm-nm" --defined-only "$o" | awk '{print $3}' | grep -qxF "${s%%[-+]*}"; then
            echo "FAIL $o: a 32-bit PC-relative reference to $s, outside the object"; bad=1
        fi
    done
    for u in $("$HB/llvm-nm" -u "$o" | awk '{print $2}'); do
        grep -qxF "$u" "$out/bound.txt" && continue
        case $u in __*|llvm.*|_GLOBAL_OFFSET_TABLE_) continue ;; esac
        echo "FAIL $o: $u is not bound by the JIT"; bad=1
    done
    printf '%s: %s relocations, %s undefined names\n' "$(basename "$o")" \
        "$("$HB/llvm-objdump" -r "$o" | grep -c R_X86_64 || true)" "$("$HB/llvm-nm" -u "$o" | wc -l | tr -d ' ')"
done
[ $bad = 0 ] && echo "hostcheck: all objects pass"
exit $bad
