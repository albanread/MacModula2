MODULE macos_ide_project;
(* A project-oriented native macOS Modula-2 IDE: a navigable project browser on
   the left, a tab view of open files on the right, an output pane below, and a
   Build & Run button that compiles whichever tab is currently visible.

   It ties the whole macOS runtime surface together — Cocoa for the window/tabs/
   editor, Proc for the filesystem (ListDir / IsDir / ReadFile) and the compiler
   subprocess. Clicking a folder descends into it; clicking a file opens it in a
   new tab; Build & Run reads the active tab (Cocoa.SelectedTab) and runs it.

   This body scripts the interactions and writes a PNG so it is verifiable
   headlessly; swap the final Snapshot for Cocoa.RunApp to drive it by hand. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append, Length, Equal;
IMPORT Cocoa; IMPORT Proc;

CONST
  MaxFiles = 64;
  PaneW    = 200.0;
  Right    = 210.0;      (* left edge of the tab view *)

VAR
  win, content, tabs, output, status: Cocoa.Object;
  gDir: ARRAY [0..1023] OF CHAR;
  gFiles: ARRAY [0..MaxFiles-1] OF ARRAY [0..255] OF CHAR;
  gButtons: ARRAY [0..MaxFiles-1] OF Cocoa.Object;
  gCount, gButtonCount: INTEGER;
  (* one editor + source path per open tab, indexed by tab order *)
  gEditors: ARRAY [0..63] OF Cocoa.Object;
  gPaths:   ARRAY [0..63] OF ARRAY [0..1023] OF CHAR;
  gTabCount: INTEGER;
  ok: BOOLEAN;
  ig: INTEGER;

(* gDir + "/" + name -> dest *)
PROCEDURE JoinPath(name: ARRAY OF CHAR; VAR dest: ARRAY OF CHAR);
BEGIN
  Assign(gDir, dest); Append("/", dest); Append(name, dest)
END JoinPath;

(* Replace gDir with its parent (drop the last "/segment"). *)
PROCEDURE GoUp;
VAR i, cut: INTEGER;
BEGIN
  cut := -1;
  FOR i := 0 TO Length(gDir) - 1 DO
    IF gDir[i] = '/' THEN cut := i END
  END;
  IF cut > 0 THEN gDir[cut] := CHR(0) END
END GoUp;

(* Tear down the current file-list buttons (we rebuild the pane on navigation). *)
PROCEDURE ClearPane;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO gButtonCount - 1 DO
    Cocoa.RemoveView(gButtons[i])
  END;
  gButtonCount := 0
END ClearPane;

(* Read gDir and lay out one button per entry (folders shown with a trailing /). *)
PROCEDURE FillPane;
VAR i, limit: INTEGER; full, label: ARRAY [0..1023] OF CHAR; y: REAL;
BEGIN
  Cocoa.SetText(status, gDir);
  gCount := Proc.ListDir(gDir);
  IF gCount < 0 THEN gCount := 0 END;
  limit := gCount; IF limit > MaxFiles - 1 THEN limit := MaxFiles - 1 END;
  FOR i := 0 TO limit - 1 DO
    ig := Proc.DirEntry(i, gFiles[i]);
    Assign(gFiles[i], label);
    JoinPath(gFiles[i], full);
    IF Proc.IsDir(full) THEN Append("/", label) END;
    y := FLOAT(630 - i*28);
    gButtons[i] := Cocoa.MakeFileButton(8.0, y, PaneW - 16.0, 25.0, label, i);
    Cocoa.AddSubview(content, gButtons[i])
  END;
  gButtonCount := limit
END FillPane;

PROCEDURE Rebuild;
BEGIN ClearPane; FillPane END Rebuild;

(* Open file `full` (display name `name`) in a fresh tab and remember its editor. *)
PROCEDURE OpenFileTab(full, name: ARRAY OF CHAR);
VAR text: ARRAY [0..32767] OF CHAR; ed, it: Cocoa.Object; n: INTEGER;
BEGIN
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  ed := Cocoa.MakeEditor(0.0, 0.0, 770.0, 470.0);
  Cocoa.SetEditorText(ed, text);
  Cocoa.HighlightEditor(ed);
  it := Cocoa.AddTab(tabs, name, ed);
  IF gTabCount <= 63 THEN
    gEditors[gTabCount] := ed;
    Assign(full, gPaths[gTabCount]);
    INC(gTabCount)
  END
END OpenFileTab;

(* The file-list action: descend into folders, open files into tabs. *)
PROCEDURE OnEntry(index: INTEGER);
VAR full: ARRAY [0..1023] OF CHAR;
BEGIN
  IF (index < 0) OR (index >= gCount) THEN RETURN END;
  JoinPath(gFiles[index], full);
  IF Proc.IsDir(full) THEN
    Assign(full, gDir);
    Rebuild
  ELSE
    OpenFileTab(full, gFiles[index])
  END
END OnEntry;

(* Build & Run the file in the currently visible tab. *)
PROCEDURE OnRun;
VAR sel: INTEGER; src, out: ARRAY [0..32767] OF CHAR; rc: INTEGER;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF sel < 0 THEN Cocoa.SetText(status, "No file open."); RETURN END;
  Cocoa.SetText(status, "Building...");
  Cocoa.EditorText(gEditors[sel], src);
  ig := Proc.WriteFile("/tmp/ide_proj_buffer.mod", src);
  rc := Proc.RunCapture(
          "./target/debug/newm2-driver run --library library /tmp/ide_proj_buffer.mod 2>&1",
          out);
  Cocoa.SetEditorText(output, out);
  IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
  ELSE Cocoa.SetText(status, "Build/run reported errors.") END
END OnRun;

VAR upBtn, runBtn: Cocoa.Object; i: INTEGER;
BEGIN
  Assign("library", gDir);            (* a directory rich in subfolders *)
  gTabCount := 0; gButtonCount := 0;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1000.0, 680.0, "MacModula2 IDE - Project");
  content := Cocoa.ContentView(win);

  (* right: the tab view of open files *)
  tabs := Cocoa.MakeTabView(Right, 200.0, 780.0, 470.0);
  Cocoa.AddSubview(content, tabs);

  (* bottom-right: compiler/program output *)
  output := Cocoa.MakeEditor(Right, 44.0, 780.0, 150.0);
  Cocoa.SetEditorText(output, "(build output appears here)");
  Cocoa.AddSubview(content, output);

  (* left: project browser, rebuilt as you navigate *)
  Cocoa.SetListAction(OnEntry);
  upBtn := Cocoa.MakeButton(8.0, 654.0, PaneW - 16.0, 24.0, "../ (up)", GoUp);
  Cocoa.AddSubview(content, upBtn);

  (* status line + Build & Run *)
  status := Cocoa.MakeLabel(Right, 14.0, 560.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);
  runBtn := Cocoa.MakeButton(880.0, 8.0, 110.0, 32.0, "Build & Run", OnRun);
  Cocoa.AddSubview(content, runBtn);

  FillPane;

  (* --- scripted walkthrough (so this is verifiable headlessly) --- *)
  (* descend into library/pimmod (a folder), open two files into tabs *)
  Assign("library/pimmod", gDir); Rebuild;
  FOR i := 0 TO gCount - 1 DO
    IF Equal(gFiles[i], "InOut.mod") THEN OnEntry(i) END
  END;
  FOR i := 0 TO gCount - 1 DO
    IF Equal(gFiles[i], "StrLib.mod") THEN OnEntry(i) END
  END;
  Cocoa.SelectTab(tabs, 0);          (* exercise programmatic tab switching *)

  ok := Cocoa.Snapshot(content, "/tmp/ide_project_app.png");
  WriteString("project IDE: ");
  WriteString(gDir); WriteString(" listed ");
  WriteString("("); WriteString("tabs open"); WriteString(")"); WriteLn
  (* Cocoa.RunApp   <- swap the Snapshot above for this to drive it live *)
END macos_ide_project.
