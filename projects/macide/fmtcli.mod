MODULE fmtcli;
(* CLI harness for M2Format — re-indent a Modula-2 source file.
     fmtcli <in.mod> [out.mod]      (no out.mod -> writes to stdout)
   Used to verify the formatter (idempotency, content-preservation) over the real
   .mod corpus, and handy on its own. (Named fmtcli, not m2format, because the
   filesystem is case-insensitive and would clash with M2Format.mod.) *)
FROM SYSTEM IMPORT ADR;
IMPORT NM2ProgramArgs;
IMPORT Proc;
IMPORT M2Format;
FROM STextIO IMPORT WriteString, WriteLn;

VAR
  inPath, outPath: ARRAY [0..1023] OF CHAR;
  src, out: ARRAY [0..1048575] OF CHAR;     (* 1 MiB each *)
  n: INTEGER; got, argc: CARDINAL;

BEGIN
  argc := NM2ProgramArgs.Count();
  IF argc < 2 THEN WriteString("usage: fmtcli <in.mod> [out.mod]"); WriteLn; HALT END;
  got := NM2ProgramArgs.Copy(1, ADR(inPath), 1023); inPath[got] := CHR(0);
  IF argc >= 3 THEN got := NM2ProgramArgs.Copy(2, ADR(outPath), 1023); outPath[got] := CHR(0)
  ELSE outPath[0] := CHR(0) END;

  n := Proc.ReadFile(inPath, src);
  IF n < 0 THEN WriteString("fmtcli: cannot read "); WriteString(inPath); WriteLn; HALT END;
  src[n] := CHR(0);

  IF NOT M2Format.Format(src, out) THEN WriteString("fmtcli: output overflow"); WriteLn; HALT END;

  IF outPath[0] = CHR(0) THEN
    WriteString(out)
  ELSE
    n := Proc.WriteFile(outPath, out);
    IF n < 0 THEN WriteString("fmtcli: cannot write "); WriteString(outPath); WriteLn; HALT END
  END
END fmtcli.
