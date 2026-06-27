IMPLEMENTATION MODULE BigNum;
(*
 * BigInt / BigRat implementation. The multi-precision "mpn" inner loops are
 * inline AArch64 assembler (carry/borrow flags + UMULH — things M2 can't
 * express); everything else is plain Modula-2. Limbs are 64-bit CARDINALs,
 * little-endian. BigInt / BigRat / Limbs come from the DEFINITION MODULE.
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM STextIO IMPORT WriteChar;

CONST TopBit = 8000000000000000H;

(* ---- AArch64 mpn assembler core ------------------------------------------ *)

PROCEDURE mpAddN (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;  (* r=a+b, ret carry *)
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

PROCEDURE mpSubN (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;  (* r=a-b, ret borrow *)
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

PROCEDURE mpAddMul1 (rp, ap: ADDRESS; n: CARDINAL; b: CARDINAL): CARDINAL; (* r += a*b, ret carry *)
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

PROCEDURE mpDivBy1 (rp, ap: ADDRESS; n: CARDINAL; d: CARDINAL): CARDINAL; (* r=a/d, ret rem *)
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

(* ---- helpers (private) --------------------------------------------------- *)

VAR pow2: ARRAY [0..63] OF CARDINAL;

PROCEDURE InitPow2;
VAR k: CARDINAL;
BEGIN pow2[0] := 1; FOR k := 1 TO 63 DO pow2[k] := pow2[k-1] * 2 END END InitPow2;

PROCEDURE Clear (VAR x: BigInt);
VAR i: CARDINAL;
BEGIN x.neg := FALSE; x.n := 0; FOR i := 0 TO Limbs-1 DO x.d[i] := 0 END END Clear;

PROCEDURE Norm (VAR x: BigInt);
BEGIN
  WHILE (x.n > 0) AND (x.d[x.n-1] = 0) DO DEC(x.n) END;
  IF x.n = 0 THEN x.neg := FALSE END
END Norm;

PROCEDURE UCmp (VAR a, b: BigInt): INTEGER;
VAR i: CARDINAL;
BEGIN
  IF a.n # b.n THEN IF a.n < b.n THEN RETURN -1 ELSE RETURN 1 END END;
  IF a.n = 0 THEN RETURN 0 END;
  i := a.n;
  REPEAT
    DEC(i);
    IF a.d[i] # b.d[i] THEN IF a.d[i] < b.d[i] THEN RETURN -1 ELSE RETURN 1 END END
  UNTIL i = 0;
  RETURN 0
END UCmp;

PROCEDURE UAdd (VAR r, a, b: BigInt);
VAR carry, old, i, hn, ln: CARDINAL; hp: BigInt;
BEGIN
  IF a.n >= b.n THEN hn := a.n; ln := b.n; Copy(hp, a)
  ELSE hn := b.n; ln := a.n; Copy(hp, b) END;
  Clear(r);
  IF hn = 0 THEN RETURN END;
  FOR i := 0 TO hn-1 DO r.d[i] := hp.d[i] END;
  r.n := hn;
  IF ln > 0 THEN
    IF a.n >= b.n THEN carry := mpAddN(ADR(r.d), ADR(r.d), ADR(b.d), ln)
    ELSE carry := mpAddN(ADR(r.d), ADR(r.d), ADR(a.d), ln) END;
    i := ln;
    WHILE (carry # 0) AND (i < hn) DO
      old := r.d[i]; r.d[i] := old + 1;
      IF r.d[i] = 0 THEN carry := 1 ELSE carry := 0 END;
      INC(i)
    END;
    IF carry # 0 THEN r.d[hn] := 1; r.n := hn + 1 END
  END
END UAdd;

PROCEDURE USub (VAR r, a, b: BigInt);   (* requires |a| >= |b| *)
VAR borrow, old, i: CARDINAL;
BEGIN
  Clear(r);
  IF a.n = 0 THEN RETURN END;
  FOR i := 0 TO a.n-1 DO r.d[i] := a.d[i] END;
  r.n := a.n;
  IF b.n > 0 THEN
    borrow := mpSubN(ADR(r.d), ADR(r.d), ADR(b.d), b.n);
    i := b.n;
    WHILE (borrow # 0) AND (i < a.n) DO
      old := r.d[i];
      IF old = 0 THEN r.d[i] := 0FFFFFFFFFFFFFFFFH; borrow := 1
      ELSE r.d[i] := old - 1; borrow := 0 END;
      INC(i)
    END
  END;
  Norm(r)
END USub;

PROCEDURE UMul (VAR r, a, b: BigInt);   (* r distinct from a, b *)
VAR j, carry: CARDINAL;
BEGIN
  Clear(r);
  IF (a.n = 0) OR (b.n = 0) THEN RETURN END;
  FOR j := 0 TO b.n-1 DO
    carry := mpAddMul1(ADR(r.d[j]), ADR(a.d), a.n, b.d[j]);
    r.d[j + a.n] := carry
  END;
  r.n := a.n + b.n;
  Norm(r)
END UMul;

PROCEDURE Shl1 (VAR x: BigInt);   (* x := x * 2 *)
VAR i, carry, out: CARDINAL;
BEGIN
  IF x.n = 0 THEN RETURN END;
  carry := 0;
  FOR i := 0 TO x.n-1 DO
    out := x.d[i] DIV TopBit;
    x.d[i] := (x.d[i] MOD TopBit) * 2 + carry;
    carry := out
  END;
  IF carry # 0 THEN x.d[x.n] := carry; INC(x.n) END
END Shl1;

PROCEDURE Shr1 (VAR x: BigInt);   (* x := x DIV 2 *)
VAR carry, cur, bit, i: CARDINAL;
BEGIN
  IF x.n = 0 THEN RETURN END;
  carry := 0; i := x.n;
  REPEAT
    DEC(i);
    cur := x.d[i]; bit := cur MOD 2;
    x.d[i] := cur DIV 2 + carry * TopBit;
    carry := bit
  UNTIL i = 0;
  Norm(x)
END Shr1;

PROCEDURE Even (VAR x: BigInt): BOOLEAN;
BEGIN RETURN (x.n = 0) OR (x.d[0] MOD 2 = 0) END Even;

(* ---- public BigInt ------------------------------------------------------- *)

PROCEDURE SetCard (VAR x: BigInt; v: CARDINAL);
BEGIN Clear(x); IF v # 0 THEN x.d[0] := v; x.n := 1 END END SetCard;

PROCEDURE Copy (VAR dst: BigInt; VAR src: BigInt);
VAR i: CARDINAL;
BEGIN
  dst.neg := src.neg; dst.n := src.n;
  IF src.n > 0 THEN FOR i := 0 TO src.n-1 DO dst.d[i] := src.d[i] END END
END Copy;

PROCEDURE Cmp (VAR a, b: BigInt): INTEGER;
VAR c: INTEGER;
BEGIN
  IF a.neg # b.neg THEN IF a.neg THEN RETURN -1 ELSE RETURN 1 END END;
  c := UCmp(a, b);
  IF a.neg THEN RETURN -c ELSE RETURN c END
END Cmp;

PROCEDURE Add (VAR r, a, b: BigInt);
VAR t: BigInt; c: INTEGER;
BEGIN
  IF a.neg = b.neg THEN UAdd(t, a, b); t.neg := a.neg
  ELSE
    c := UCmp(a, b);
    IF c >= 0 THEN USub(t, a, b); t.neg := a.neg
    ELSE USub(t, b, a); t.neg := b.neg END
  END;
  Norm(t); Copy(r, t)
END Add;

PROCEDURE Sub (VAR r, a, b: BigInt);
VAR t: BigInt;
BEGIN Copy(t, b); t.neg := NOT t.neg; Add(r, a, t) END Sub;

PROCEDURE Mul (VAR r, a, b: BigInt);
VAR t: BigInt;
BEGIN UMul(t, a, b); t.neg := (a.neg # b.neg); Norm(t); Copy(r, t) END Mul;

PROCEDURE MulCard (VAR x: BigInt; m: CARDINAL);
VAR t: BigInt; carry: CARDINAL;
BEGIN
  Clear(t);
  IF (x.n = 0) OR (m = 0) THEN x.n := 0; x.neg := FALSE; RETURN END;
  carry := mpAddMul1(ADR(t.d), ADR(x.d), x.n, m);
  t.d[x.n] := carry; t.n := x.n + 1; t.neg := x.neg;
  Norm(t); Copy(x, t)
END MulCard;

PROCEDURE DivMod (VAR q, r, a, b: BigInt);   (* magnitudes; q,r distinct from a,b *)
VAR t: BigInt; i, bb, nbit: CARDINAL;
BEGIN
  Clear(q); Clear(r);
  IF (b.n = 0) OR (a.n = 0) THEN RETURN END;
  q.n := a.n;
  i := a.n;
  REPEAT
    DEC(i);
    bb := 64;
    REPEAT
      DEC(bb);
      Shl1(r);
      nbit := (a.d[i] DIV pow2[bb]) MOD 2;
      IF nbit = 1 THEN
        IF r.n = 0 THEN r.d[0] := 1; r.n := 1 ELSE r.d[0] := r.d[0] + 1 END
      END;
      IF UCmp(r, b) >= 0 THEN
        USub(t, r, b); Copy(r, t);
        q.d[i] := q.d[i] + pow2[bb]
      END
    UNTIL bb = 0
  UNTIL i = 0;
  Norm(q); Norm(r)
END DivMod;

PROCEDURE Div (VAR q, a, b: BigInt);
VAR rr, t: BigInt;
BEGIN DivMod(t, rr, a, b); t.neg := (a.neg # b.neg); Norm(t); Copy(q, t) END Div;

PROCEDURE Gcd (VAR g, a, b: BigInt);
VAR x, y, t: BigInt; shift: CARDINAL;
BEGIN
  Copy(x, a); x.neg := FALSE;
  Copy(y, b); y.neg := FALSE;
  IF x.n = 0 THEN Copy(g, y); RETURN END;
  IF y.n = 0 THEN Copy(g, x); RETURN END;
  shift := 0;
  WHILE Even(x) AND Even(y) DO Shr1(x); Shr1(y); INC(shift) END;
  WHILE Even(x) DO Shr1(x) END;
  LOOP
    WHILE Even(y) DO Shr1(y) END;
    IF UCmp(x, y) > 0 THEN Copy(t, x); Copy(x, y); Copy(y, t) END;   (* x <= y *)
    USub(t, y, x); Copy(y, t);                                       (* y := y - x *)
    IF y.n = 0 THEN EXIT END
  END;
  Copy(g, x);
  WHILE shift > 0 DO Shl1(g); DEC(shift) END
END Gcd;

PROCEDURE Print (VAR x: BigInt);
VAR t: BigInt; buf: ARRAY [0..2047] OF CHAR; k, rem: CARDINAL;
BEGIN
  IF x.neg THEN WriteChar('-') END;
  IF x.n = 0 THEN WriteChar('0'); RETURN END;
  Copy(t, x); k := 0;
  WHILE t.n > 0 DO
    rem := mpDivBy1(ADR(t.d), ADR(t.d), t.n, 10);
    buf[k] := CHR(ORD('0') + rem); INC(k);
    WHILE (t.n > 0) AND (t.d[t.n-1] = 0) DO DEC(t.n) END
  END;
  REPEAT DEC(k); WriteChar(buf[k]) UNTIL k = 0
END Print;

(* ---- public BigRat ------------------------------------------------------- *)

PROCEDURE RatNorm (VAR r: BigRat);
VAR g, q, dummy: BigInt;
BEGIN
  IF r.den.n = 0 THEN RETURN END;
  IF r.den.neg THEN r.den.neg := FALSE; r.num.neg := NOT r.num.neg END;
  Norm(r.num); Norm(r.den);
  IF r.num.n = 0 THEN SetCard(r.den, 1); RETURN END;
  Gcd(g, r.num, r.den);
  IF (g.n = 1) AND (g.d[0] = 1) THEN RETURN END;
  DivMod(q, dummy, r.num, g); q.neg := r.num.neg; Norm(q); Copy(r.num, q);
  DivMod(q, dummy, r.den, g); q.neg := FALSE;     Norm(q); Copy(r.den, q)
END RatNorm;

PROCEDURE RatSet (VAR r: BigRat; VAR num, den: BigInt);
BEGIN Copy(r.num, num); Copy(r.den, den); RatNorm(r) END RatSet;

PROCEDURE RatSetCard (VAR r: BigRat; num: INTEGER; den: CARDINAL);
BEGIN
  IF num < 0 THEN SetCard(r.num, VAL(CARDINAL, -num)); r.num.neg := TRUE
  ELSE SetCard(r.num, VAL(CARDINAL, num)) END;
  SetCard(r.den, den); RatNorm(r)
END RatSetCard;

PROCEDURE RatAdd (VAR r, x, y: BigRat);
VAR ad, cb, nn, dd: BigInt;
BEGIN
  Mul(ad, x.num, y.den); Mul(cb, y.num, x.den); Add(nn, ad, cb);
  Mul(dd, x.den, y.den);
  Copy(r.num, nn); Copy(r.den, dd); RatNorm(r)
END RatAdd;

PROCEDURE RatMul (VAR r, x, y: BigRat);
VAR nn, dd: BigInt;
BEGIN
  Mul(nn, x.num, y.num); Mul(dd, x.den, y.den);
  Copy(r.num, nn); Copy(r.den, dd); RatNorm(r)
END RatMul;

PROCEDURE RatPrint (VAR r: BigRat);
BEGIN
  Print(r.num);
  IF NOT ((r.den.n = 1) AND (r.den.d[0] = 1)) THEN WriteChar('/'); Print(r.den) END
END RatPrint;

BEGIN
  InitPow2
END BigNum.
