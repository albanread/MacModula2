//! Module-asm string builder.
//!
//! # Design (revision 2)
//!
//! Earlier revisions of this crate substituted `#name` tokens inside
//! the ASM body for the Win64 ABI register that corresponded to the
//! parameter slot. That syntax was dropped for two reasons:
//!
//! 1. **`#` is reserved by the BASIC family for file-number prefixes**
//!    (`PRINT #1, "x"` etc.). Repurposing it inside ASM bodies asked
//!    the host language's lexer to context-switch — a layering
//!    violation that bled assembler grammar into general parsing.
//! 2. **`#paramname` was novel syntax**. Every other inline-asm
//!    convention in the BASIC lineage (POWER BASIC's `! ASM ...`,
//!    QuickBASIC's `CALL ABSOLUTE`) lets the user write raw
//!    target-architecture mnemonics and refers to ABI registers by
//!    their actual names. The substitution layer hid the calling
//!    convention rather than teaching it.
//!
//! The current convention is **plain Intel-syntax**. Authors of
//! `ASM SUB` / `ASM FUNCTION` blocks reference Win64 ABI registers
//! directly:
//!
//! ```text
//! ASM FUNCTION fast_add(a AS LONG, b AS LONG) AS LONG
//!     mov rax, rcx      ' rcx = a   (Win64 slot 0, integer)
//!     add rax, rdx      ' rdx = b   (Win64 slot 1, integer)
//!     ret
//! END ASM
//! ```
//!
//! ## Win64 ABI cheat-sheet (the table the substitution used to hide)
//!
//! | Slot  | Integer / pointer       | Float (Single/Double)         |
//! |-------|-------------------------|-------------------------------|
//! | 0     | `rcx`                   | `xmm0`                        |
//! | 1     | `rdx`                   | `xmm1`                        |
//! | 2     | `r8`                    | `xmm2`                        |
//! | 3     | `r9`                    | `xmm3`                        |
//! | 4+    | `qword ptr [rsp+40+8N]` | `xmmword ptr [rsp+40+8N]`     |
//!
//! Return values: integer / pointer → `rax`; `Single`/`Double` →
//! `xmm0`; `<4 x f32>` → `xmm0`; `<8 x f32>` → `ymm0`; void → none.
//!
//! ## What this crate emits
//!
//! [`build_module_asm_string`] formats the captured body for
//! [`LLVMAppendModuleInlineAsm`][llvm]:
//!
//! ```text
//! .intel_syntax noprefix
//! .globl <name>
//! <name>:
//!     <indented instruction>
//! inner_label:
//!     <indented instruction>
//! ```
//!
//! Lines ending in `:` are treated as labels and kept at column 0;
//! everything else is indented four spaces. Blank lines are
//! preserved so multi-block bodies stay readable in `dump-asm`.
//! `String::trim()` is applied per line so the user's source-side
//! indentation doesn't survive into the final emission. **No token
//! rewriting happens.**
//!
//! [llvm]: https://llvm.org/doxygen/group__LLVMCCoreModule.html

use crate::types::{Arch, AsmProc, AsmRetType};

/// Build the complete string for `LLVMAppendModuleInlineAsm`.
///
/// `arch` selects the assembler dialect: x86-64 prepends
/// `.intel_syntax noprefix`; AArch64 emits native GAS syntax (no directive).
/// `sym_prefix` is the object-format symbol prefix — `"_"` for Mach-O (macOS),
/// `""` for ELF/COFF — so the exported label matches the mangled symbol that the
/// companion LLVM `declare` resolves to. See the crate-level docstring for the
/// output shape; internal labels in the body are emitted verbatim (no prefix).
///
/// ## AAPCS64 cheat-sheet (AArch64)
///
/// | Slot | Integer / pointer | Float (REAL) |
/// |------|-------------------|--------------|
/// | 0    | `x0` (`w0`)       | `d0` (`s0`)  |
/// | 1    | `x1`              | `d1`         |
/// | …    | … up to `x7`      | … up to `d7` |
/// | 8+   | on the stack      | on the stack |
///
/// Return: integer/pointer → `x0`; REAL → `d0`. End the body with `ret`.
pub fn build_module_asm_string(proc: &AsmProc, arch: Arch, sym_prefix: &str) -> String {
    let mut out = String::new();
    if arch == Arch::X86_64 {
        out.push_str(".intel_syntax noprefix\n");
    }
    let label = format!("{sym_prefix}{}", proc.name);
    out.push_str(&format!(".globl {0}\n{0}:\n", label));
    for line in proc.body.lines() {
        let t = line.trim();
        if t.is_empty() {
            out.push('\n');
        } else if t.ends_with(':') {
            // Label — keep at column 0.
            out.push_str(t);
            out.push('\n');
        } else {
            // Instruction or directive — indent.
            out.push_str("    ");
            out.push_str(t);
            out.push('\n');
        }
    }
    out
}

/// Return type annotation as a hint string for error messages. Kept
/// available for future diagnostics — sema's hard-error channel does
/// not yet narrate return-type mismatches at ASM-procedure call sites,
/// but a future pass will want the standard mapping.
#[allow(dead_code)]
pub fn ret_type_str(rt: AsmRetType) -> &'static str {
    match rt {
        AsmRetType::Word => "i64 (rax)",
        AsmRetType::Float => "f64 (xmm0)",
        AsmRetType::FQuad => "<4 x f32> (xmm0)",
        AsmRetType::FOct => "<8 x f32> (ymm0)",
        AsmRetType::Void => "void",
    }
}

// ─── tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Arch, AsmParam, AsmType};

    fn word(name: &str) -> AsmParam {
        AsmParam { name: name.into(), ty: AsmType::Word }
    }

    #[test]
    fn emits_intel_syntax_header_and_globl_label() {
        let proc = AsmProc {
            name: "fast_add".into(),
            params: vec![word("a"), word("b")],
            return_type: AsmRetType::Word,
            body: "mov rax, rcx\nadd rax, rdx\nret".into(),
        };
        let s = build_module_asm_string(&proc, Arch::X86_64, "");
        assert!(s.contains(".intel_syntax noprefix"));
        assert!(s.contains(".globl fast_add"));
        assert!(s.contains("fast_add:"));
        // Body emitted verbatim — Win64 ABI registers used directly.
        assert!(s.contains("    mov rax, rcx"));
        assert!(s.contains("    add rax, rdx"));
        assert!(s.contains("    ret"));
    }

    #[test]
    fn labels_stay_at_column_zero_instructions_indented() {
        // Inner labels in the body should not be re-indented — the
        // assembler ignores the visual difference, but `dump-asm`
        // readers expect the loop / branch structure to survive.
        let proc = AsmProc {
            name: "looper".into(),
            params: vec![word("n")],
            return_type: AsmRetType::Word,
            body: "mov rax, 0\nmov rdx, rcx\nloop:\n  add rax, rdx\n  dec rdx\n  jnz loop\nret"
                .into(),
        };
        let s = build_module_asm_string(&proc, Arch::X86_64, "");
        assert!(s.contains("looper:\n"));
        // Inner label flush-left, instructions indented.
        assert!(s.contains("\nloop:\n"));
        assert!(s.contains("    add rax, rdx\n"));
        assert!(s.contains("    jnz loop\n"));
    }

    #[test]
    fn blank_lines_are_preserved() {
        // Authors often blank-line separate logical sections inside
        // a longer routine. Verbatim preservation lets `dump-asm`
        // mirror that.
        let proc = AsmProc {
            name: "spaced".into(),
            params: vec![],
            return_type: AsmRetType::Void,
            body: "mov rax, 1\n\nmov rdx, 2\nret".into(),
        };
        let s = build_module_asm_string(&proc, Arch::X86_64, "");
        // Three indented instruction lines + one blank in the body.
        let body_lines: Vec<&str> = s.lines().skip(3).collect();
        assert_eq!(
            body_lines,
            vec!["    mov rax, 1", "", "    mov rdx, 2", "    ret"],
        );
    }

    #[test]
    fn hash_characters_in_body_pass_through_untouched() {
        // `#` is no longer a substitution marker — anything written
        // in the body travels through verbatim. Useful smoke test
        // because earlier revisions of this crate ate `#name`.
        let proc = AsmProc {
            name: "with_hash".into(),
            params: vec![],
            return_type: AsmRetType::Void,
            body: "ret  # legacy comment style".into(),
        };
        let s = build_module_asm_string(&proc, Arch::X86_64, "");
        assert!(s.contains("ret  # legacy comment style"));
    }
}
