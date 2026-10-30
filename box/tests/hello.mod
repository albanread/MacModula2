MODULE hello;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
VAR i: INTEGER;
BEGIN
  WriteString("Hello from Modula-2"); WriteLn;
  FOR i := 1 TO 3 DO WriteInt(i * i, 4) END;
  WriteLn
END hello.
