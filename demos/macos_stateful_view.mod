MODULE macos_stateful_view;
(* A STATEFUL Cocoa subclass: FancyView is a real NSView with its own M2 fields.
   Under a Cocoa superclass the M2 fields live in an `__m2` ivar placed after
   NSView's own ivars, so field access is base-adjusted at runtime
   (nm2_objc_field_base). Pure M2 above; Cocoa below. (Build AOT.) *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

CLASS FancyView;
  <* cocoa "NSView" *>
  VAR hue, count: INTEGER;             (* real per-instance state in __m2 *)
  PROCEDURE SetHue (h: INTEGER);
  BEGIN hue := h END SetHue;
  PROCEDURE Tick;
  BEGIN count := count + 1 END Tick;
  PROCEDURE Hue (): INTEGER;
  BEGIN RETURN hue END Hue;
  PROCEDURE Count (): INTEGER;
  BEGIN RETURN count END Count;
END FancyView;

VAR v, w: FancyView;
BEGIN
  NEW(v); NEW(w);                      (* two real NSView instances *)
  v.SetHue(200); v.Tick(); v.Tick(); v.Tick();
  w.SetHue(40);  w.Tick();
  WriteString("v: hue="); WriteInt(v.Hue(), 0);
  WriteString(" count="); WriteInt(v.Count(), 0); WriteLn;    (* hue=200 count=3 *)
  WriteString("w: hue="); WriteInt(w.Hue(), 0);
  WriteString(" count="); WriteInt(w.Count(), 0); WriteLn;    (* hue=40  count=1 *)
  DISPOSE(v); DISPOSE(w)
END macos_stateful_view.
