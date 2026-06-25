MODULE macos_inherit;
(* M2: single inheritance between M2 classes, realized as an Obj-C class chain.
   `Dog` is registered with `Animal` as its Obj-C superclass; it inherits
   Animal's methods and field, and adds its own. Each class contributes one
   `__m2` ivar for its own fields, laid out contiguously by the runtime so
   native field access still lands correctly. Pure M2 above; Cocoa below. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

CLASS Animal;
  VAR legs: INTEGER;
  PROCEDURE SetLegs (n: INTEGER);
  BEGIN legs := n END SetLegs;
  PROCEDURE Legs (): INTEGER;
  BEGIN RETURN legs END Legs;
END Animal;

CLASS Dog;
  INHERIT Animal;
  VAR barks: INTEGER;
  PROCEDURE SetBarks (n: INTEGER);
  BEGIN barks := n END SetBarks;
  PROCEDURE Barks (): INTEGER;
  BEGIN RETURN barks END Barks;
END Dog;

VAR d: Dog;
BEGIN
  NEW(d);
  d.SetLegs(4);                  (* inherited method, base field (Animal.__m2) *)
  d.SetBarks(3);                 (* own method, own field (Dog.__m2)           *)
  WriteString("d.Legs()  = "); WriteInt(d.Legs(), 0); WriteLn;    (* 4 *)
  WriteString("d.Barks() = "); WriteInt(d.Barks(), 0); WriteLn;   (* 3 *)
  DISPOSE(d)
END macos_inherit.
