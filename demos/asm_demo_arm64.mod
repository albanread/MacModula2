MODULE AsmDemoArm64;
(*
 * Inline assembler on Apple Silicon — a Modula-2 procedure whose body is
 * `ASM <aarch64> END name;`. The body is native AArch64 (GAS syntax), emitted as
 * module-level inline asm and assembled by LLVM-MC, then called like any other
 * procedure. AAPCS64: integer args arrive in x0, x1, x2, x3, … (then the stack);
 * the integer result goes back in x0. (REALs use d0..d7 / d0.) You write the
 * real ABI — no register-substitution magic.
 *
 *   run:   newm2 run   demos/asm_demo_arm64.mod
 *   build: newm2 build demos/asm_demo_arm64.mod
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

(* a = x0, b = x1  ->  x0 = a + b *)
PROCEDURE Add (a, b: INTEGER): INTEGER;
ASM
  add x0, x0, x1
  ret
END Add;

(* a = x0, b = x1  ->  x0 = a * b *)
PROCEDURE Mul (a, b: INTEGER): INTEGER;
ASM
  mul x0, x0, x1
  ret
END Mul;

(* a = x0, b = x1, c = x2, d = x3  ->  x0 = a + b + c + d *)
PROCEDURE Sum4 (a, b, c, d: INTEGER): INTEGER;
ASM
  add x0, x0, x1
  add x0, x0, x2
  add x0, x0, x3
  ret
END Sum4;

(* n = x0  ->  x0 = n*(n+1)/2  via a loop (shows labels + branches) *)
PROCEDURE TriSum (n: INTEGER): INTEGER;
ASM
  mov x9, x0
  mov x0, #0
Ltri_loop:
  cmp x9, #0
  ble Ltri_done
  add x0, x0, x9
  sub x9, x9, #1
  b Ltri_loop
Ltri_done:
  ret
END TriSum;

PROCEDURE Show (label: ARRAY OF CHAR; v: INTEGER);
BEGIN WriteString(label); WriteInt(v, 1); WriteLn END Show;

BEGIN
  Show("Add(40, 2)        = ", Add(40, 2));        (* 42 *)
  Show("Mul(6, 7)         = ", Mul(6, 7));         (* 42 *)
  Show("Sum4(10,20,8,4)   = ", Sum4(10, 20, 8, 4)); (* 42 *)
  Show("TriSum(8)         = ", TriSum(8))           (* 36 *)
END AsmDemoArm64.
