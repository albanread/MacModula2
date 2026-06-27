MODULE BignumCoreTest;
(* Validate the AArch64 multi-precision "mpn" asm core: limb-vector add/sub with
   carry/borrow, addmul-by-1 (64x64->128 via mul/umulh), and divide-by-1
   (128/64 long division). Limbs are 64-bit CARDINALs, little-endian. *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;

CONST MaxU = 0FFFFFFFFFFFFFFFFH;   (* 2^64 - 1 *)

(* r[0..n) = a + b ; returns the carry out (0/1). rp=x0 ap=x1 bp=x2 n=x3 *)
PROCEDURE mpAddN (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;
ASM
  cbz x3, LaddN_zero
  adds xzr, xzr, xzr
LaddN_loop:
  ldr x9, [x1], #8
  ldr x10, [x2], #8
  adcs x9, x9, x10
  str x9, [x0], #8
  sub x3, x3, #1
  cbnz x3, LaddN_loop
  cset x0, cs
  ret
LaddN_zero:
  mov x0, #0
  ret
END mpAddN;

(* r[0..n) = a - b ; returns the borrow out (1 if a<b). rp=x0 ap=x1 bp=x2 n=x3 *)
PROCEDURE mpSubN (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;
ASM
  cbz x3, LsubN_zero
  subs xzr, xzr, xzr
LsubN_loop:
  ldr x9, [x1], #8
  ldr x10, [x2], #8
  sbcs x9, x9, x10
  str x9, [x0], #8
  sub x3, x3, #1
  cbnz x3, LsubN_loop
  cset x0, cc
  ret
LsubN_zero:
  mov x0, #0
  ret
END mpSubN;

(* r[0..n) += a[0..n) * b ; returns the carry-out limb. rp=x0 ap=x1 n=x2 b=x3 *)
PROCEDURE mpAddMul1 (rp, ap: ADDRESS; n: CARDINAL; b: CARDINAL): CARDINAL;
ASM
  mov x4, #0
  cbz x2, LaddMul1_done
LaddMul1_loop:
  ldr x9, [x1], #8
  ldr x10, [x0]
  mul x11, x9, x3
  umulh x12, x9, x3
  adds x11, x11, x10
  adc x12, x12, xzr
  adds x11, x11, x4
  adc x12, x12, xzr
  str x11, [x0], #8
  mov x4, x12
  sub x2, x2, #1
  cbnz x2, LaddMul1_loop
LaddMul1_done:
  mov x0, x4
  ret
END mpAddMul1;

(* r[0..n) = a[0..n) / d ; returns the remainder. rp=x0 ap=x1 n=x2 d=x3.
   Long division, most-significant limb first; rem<d carried down. *)
PROCEDURE mpDivBy1 (rp, ap: ADDRESS; n: CARDINAL; d: CARDINAL): CARDINAL;
ASM
  mov x4, #0
  cbz x2, LdivBy1_zero
  sub x5, x2, #1
  lsl x6, x5, #3
LdivBy1_limb:
  ldr x9, [x1, x6]
  mov x10, #0
  mov x11, #64
LdivBy1_bit:
  lsl x4, x4, #1
  lsr x12, x9, #63
  orr x4, x4, x12
  lsl x9, x9, #1
  lsl x10, x10, #1
  cmp x4, x3
  blo LdivBy1_skip
  sub x4, x4, x3
  orr x10, x10, #1
LdivBy1_skip:
  sub x11, x11, #1
  cbnz x11, LdivBy1_bit
  str x10, [x0, x6]
  cbz x6, LdivBy1_done
  sub x6, x6, #8
  b LdivBy1_limb
LdivBy1_done:
  mov x0, x4
  ret
LdivBy1_zero:
  mov x0, #0
  ret
END mpDivBy1;

PROCEDURE Pair (lbl: ARRAY OF CHAR; lo, hi, extra: CARDINAL);
BEGIN
  WriteString(lbl); WriteString("lo="); WriteCard(lo, 1);
  WriteString(" hi="); WriteCard(hi, 1);
  WriteString(" extra="); WriteCard(extra, 1); WriteLn
END Pair;

VAR a, b, r: ARRAY [0..3] OF CARDINAL; c: CARDINAL;
BEGIN
  (* add: {MaxU,1} + {1,0} = {0,2} carry 0 *)
  a[0] := MaxU; a[1] := 1; b[0] := 1; b[1] := 0;
  c := mpAddN(ADR(r), ADR(a), ADR(b), 2);
  Pair("add  {MAX,1}+{1,0}: ", r[0], r[1], c);   (* expect lo=0 hi=2 extra=0 *)

  (* sub: {0,2} - {1,0} = {MAX,1} borrow 0 *)
  a[0] := 0; a[1] := 2; b[0] := 1; b[1] := 0;
  c := mpSubN(ADR(r), ADR(a), ADR(b), 2);
  Pair("sub  {0,2}-{1,0}:   ", r[0], r[1], c);    (* expect lo=MAX hi=1 extra=0 *)

  (* addmul: r={0,0} += {MaxU,1}*3 -> MaxU*3 = 0x2_FFFFFFFFFFFFFFFD ... over 2 limbs:
     a = 1*2^64 + MaxU = 2^65-1; *3 = 3*2^65-3 = 0x5_FFFFFFFFFFFFFFFD.
     low limb = 0xFFFFFFFFFFFFFFFD, hi limb = 5, carry 0 *)
  r[0] := 0; r[1] := 0; a[0] := MaxU; a[1] := 1;
  c := mpAddMul1(ADR(r), ADR(a), 2, 3);
  Pair("amul {MAX,1}*3:     ", r[0], r[1], c);    (* expect lo=MAX-2 hi=5 extra=0 *)

  (* div: {100,0}/7 = {14,0} rem 2 *)
  a[0] := 100; a[1] := 0;
  c := mpDivBy1(ADR(r), ADR(a), 2, 7);
  Pair("div  {100,0}/7:     ", r[0], r[1], c);    (* expect lo=14 hi=0 extra(rem)=2 *)

  (* div across limbs: {0,1}/2 = (2^64)/2 = 2^63 = {0x8000000000000000,0} rem 0 *)
  a[0] := 0; a[1] := 1;
  c := mpDivBy1(ADR(r), ADR(a), 2, 2);
  Pair("div  2^64/2:        ", r[0], r[1], c)     (* expect lo=2^63 hi=0 rem=0 *)
END BignumCoreTest.
