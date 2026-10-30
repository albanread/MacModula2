MODULE files;
(* Files through RISC OS: ISO SeqFile and TextIO, written then read back. *)
IMPORT SeqFile, TextIO, IOResult, IOConsts;
FROM ChanConsts IMPORT OpenResults;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
VAR cid: SeqFile.ChanId; res: OpenResults; i: INTEGER;
    line: ARRAY [0..79] OF CHAR;
BEGIN
  SeqFile.OpenWrite(cid, "<Wimp$ScrapDir>.m2files", SeqFile.write + SeqFile.old, res);
  IF res # SeqFile.opened THEN
    SeqFile.OpenWrite(cid, "<Wimp$ScrapDir>.m2files", SeqFile.write, res)
  END;
  IF res # SeqFile.opened THEN WriteString("cannot write"); WriteLn; HALT(1) END;
  FOR i := 1 TO 3 DO
    TextIO.WriteString(cid, "line "); TextIO.WriteString(cid, "number"); TextIO.WriteLn(cid)
  END;
  SeqFile.Close(cid);
  SeqFile.OpenRead(cid, "<Wimp$ScrapDir>.m2files", SeqFile.read, res);
  IF res # SeqFile.opened THEN WriteString("cannot read"); WriteLn; HALT(1) END;
  i := 0;
  LOOP
    TextIO.ReadString(cid, line);
    IF IOResult.ReadResult(cid) # IOConsts.allRight THEN EXIT END;
    TextIO.SkipLine(cid);
    INC(i); WriteInt(i, 1); WriteString(": "); WriteString(line); WriteLn
  END;
  SeqFile.Close(cid);
  WriteString("read back "); WriteInt(i, 1); WriteString(" lines"); WriteLn
END files.
