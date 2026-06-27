MODULE Bignum;
(*
 * Demo of the BigNum library — arbitrary-precision integers and exact rationals
 * with an AArch64 assembler core (library/shareddef/BigNum.def +
 * library/sharedmod/BigNum.mod). The hot multi-precision loops are inline
 * AArch64 asm; this program just uses the library.
 *
 *   run: newm2 run demos/bignum.mod
 *)
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT BigNum;

VAR acc, lo, hi, q: BigNum.BigInt; i: CARDINAL;
    ra, rb, rsum, term: BigNum.BigRat;
BEGIN
  (* 100! *)
  BigNum.SetCard(acc, 1);
  FOR i := 2 TO 100 DO BigNum.MulCard(acc, i) END;
  WriteString("100! = "); BigNum.Print(acc); WriteLn;

  (* 2^256 *)
  BigNum.SetCard(acc, 1);
  FOR i := 1 TO 256 DO BigNum.MulCard(acc, 2) END;
  WriteString("2^256 = "); BigNum.Print(acc); WriteLn;

  (* division: 100! / 98! = 9900 *)
  BigNum.SetCard(acc, 1); FOR i := 2 TO 100 DO BigNum.MulCard(acc, i) END;
  BigNum.SetCard(lo, 1);  FOR i := 2 TO 98  DO BigNum.MulCard(lo, i)  END;
  BigNum.Div(q, acc, lo);
  WriteString("100! / 98! = "); BigNum.Print(q); WriteLn;

  (* signed: 5 - 8 = -3 *)
  BigNum.SetCard(lo, 5); BigNum.SetCard(hi, 8); BigNum.Sub(acc, lo, hi);
  WriteString("5 - 8 = "); BigNum.Print(acc); WriteLn;

  (* rationals: 1/2 + 1/3 + 1/6 = 1 *)
  BigNum.RatSetCard(ra, 1, 2); BigNum.RatSetCard(rb, 1, 3); BigNum.RatAdd(rsum, ra, rb);
  BigNum.RatSetCard(rb, 1, 6); BigNum.RatAdd(rsum, rsum, rb);
  WriteString("1/2 + 1/3 + 1/6 = "); BigNum.RatPrint(rsum); WriteLn;

  (* (2/3) * (3/4) = 1/2 *)
  BigNum.RatSetCard(ra, 2, 3); BigNum.RatSetCard(rb, 3, 4); BigNum.RatMul(rsum, ra, rb);
  WriteString("(2/3) * (3/4) = "); BigNum.RatPrint(rsum); WriteLn;

  (* harmonic number H(20) in exact lowest terms *)
  BigNum.RatSetCard(rsum, 0, 1);
  FOR i := 1 TO 20 DO
    BigNum.RatSetCard(term, 1, i); BigNum.RatAdd(rsum, rsum, term)
  END;
  WriteString("H(20) = "); BigNum.RatPrint(rsum); WriteLn
END Bignum.
