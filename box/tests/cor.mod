MODULE cor;
FROM SYSTEM IMPORT NEWPROCESS, TRANSFER, ADDRESS, PROCESS;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
VAR main, gen: PROCESS; value: INTEGER; wsp: ARRAY [0..16383] OF CARDINAL8;
PROCEDURE Generator;
VAR i: INTEGER;
BEGIN
  FOR i := 1 TO 5 DO value := i * 10; TRANSFER(gen, main) END;
  value := -1; TRANSFER(gen, main)
END Generator;
BEGIN
  NEWPROCESS(Generator, ADR(wsp), SIZE(wsp), gen);
  LOOP
    TRANSFER(main, gen);
    IF value < 0 THEN EXIT END;
    WriteInt(value, 4)
  END;
  WriteLn; WriteString("coroutines done"); WriteLn
END cor.
