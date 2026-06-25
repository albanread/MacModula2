MODULE macos_cocoa_lib;
(* Using the generated Cocoa class library. `library/macrtdef/CocoaNS.def` is
   produced by newm2-cocoa-gen from the Obj-C runtime: EXTERNAL declarations of
   Foundation/AppKit classes (an INHERIT chain, each class with its own methods
   and pinned selectors). A program just IMPORTs it and uses the classes with
   ordinary typed Modula-2 — NEW, dotted calls, inheritance — while the objects
   are the real Cocoa classes underneath. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
IMPORT ObjC;
IMPORT CocoaNS;

VAR
  items: CocoaNS.NSMutableArray;
  view:  CocoaNS.NSView;
BEGIN
  (* A real Foundation collection, typed. *)
  NEW(items);
  items.AddObject(ObjC.NSString("alpha"));
  items.AddObject(ObjC.NSString("beta"));
  items.AddObject(ObjC.NSString("gamma"));
  WriteString("NSMutableArray count = "); WriteInt(items.Count(), 0); WriteLn;

  (* A real AppKit view, typed; SetHidden/IsHidden are inherited down the chain
     (NSView <- NSResponder <- NSObject) and dispatch to the real NSView. *)
  NEW(view);
  view.SetHidden(TRUE);
  WriteString("NSView isHidden after SetHidden(TRUE) = ");
  IF view.IsHidden() THEN WriteString("TRUE (OK)") ELSE WriteString("FALSE") END;
  WriteLn
END macos_cocoa_lib.
