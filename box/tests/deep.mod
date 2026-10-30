MODULE deep;
FROM STextIO IMPORT WriteString, WriteLn;
PROCEDURE Down(n: INTEGER): INTEGER;
BEGIN RETURN Down(n + 1) + Down(n + 2) END Down;
BEGIN
  WriteString("going down"); WriteLn;
  WriteString("result "); IF Down(0) > 0 THEN WriteString("?") END
END deep.
