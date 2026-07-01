MODULE t91042acharaggregatecopy;
(* lower_aggregate_constructor's string-into-fixed-char-array hazard check
   only recognized the WIDE Char/Uchar array-element type (array_char_count);
   a slot of type `ARRAY [..] OF ACHAR` (narrow/8-bit) fell to the plain Store
   path, writing the string literal's raw pointer bits into the record as if
   it were an 8-byte value, instead of copying its characters. Same bug class
   as the already-fixed Assign-statement path, just in the aggregate
   constructor.
 *
 * EXPECTED:
 * 49
 *)
FROM SWholeIO IMPORT WriteInt;
FROM STextIO IMPORT WriteLn;

TYPE rec = RECORD i: ARRAY [0..15] OF ACHAR END;
VAR a: rec;
BEGIN
  a := rec{"12"A};
  WriteInt(ORD(a.i[0]), 0); WriteLn
END t91042acharaggregatecopy.
