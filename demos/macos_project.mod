MODULE macos_project;
(* A project-oriented IDE: open a folder, list its files in a left pane, and
   open files in tabs on the right. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append;
IMPORT Cocoa; IMPORT Proc;

VAR
  win, content, tabs: Cocoa.Object;
  gDir: ARRAY [0..255] OF CHAR;
  gFiles: ARRAY [0..63] OF ARRAY [0..127] OF CHAR;
  gCount, i, limit: INTEGER;
  fileBtn: Cocoa.Object;
  ok: BOOLEAN;

(* Open the file at row `index` in a new tab (this is the file-list action). *)
PROCEDURE OpenFile(index: INTEGER);
VAR fullpath, content2: ARRAY [0..16383] OF CHAR; ed, ig: Cocoa.Object; n: INTEGER;
BEGIN
  Assign(gDir, fullpath); Append("/", fullpath); Append(gFiles[index], fullpath);
  n := Proc.ReadFile(fullpath, content2);
  IF n >= 0 THEN
    ed := Cocoa.MakeEditor(0.0, 0.0, 686.0, 556.0);
    Cocoa.SetEditorText(ed, content2);
    Cocoa.HighlightEditor(ed);
    ig := Cocoa.AddTab(tabs, gFiles[index], ed)
  END
END OpenFile;

VAR n2: INTEGER;
BEGIN
  Assign("library/pimdef", gDir);          (* the "project" folder *)

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(900.0, 600.0, "MacModula2 IDE - Project");
  content := Cocoa.ContentView(win);

  (* right: tab view for open files *)
  tabs := Cocoa.MakeTabView(200.0, 10.0, 690.0, 580.0);
  Cocoa.AddSubview(content, tabs);

  (* left: a button per project file *)
  Cocoa.SetListAction(OpenFile);
  gCount := Proc.ListDir(gDir);
  limit := gCount; IF limit > 19 THEN limit := 19 END;
  FOR i := 0 TO limit - 1 DO
    n2 := Proc.DirEntry(i, gFiles[i]);
    fileBtn := Cocoa.MakeFileButton(8.0, FLOAT(564 - i*29), 184.0, 26.0, gFiles[i], i);
    Cocoa.AddSubview(content, fileBtn)
  END;

  (* open a couple of files into tabs (what clicking the list does) *)
  IF gCount > 0 THEN OpenFile(0) END;
  IF gCount > 3 THEN OpenFile(3) END;

  ok := Cocoa.Snapshot(content, "/tmp/ide_project.png");
  WriteString("project IDE: "); WriteString(gDir);
  WriteString(" listed "); WriteLn
END macos_project.
