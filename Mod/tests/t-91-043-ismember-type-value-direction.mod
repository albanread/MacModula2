MODULE t91043ismembertypevaluedirection;
(* ISMEMBER(p1,p2) tests class(p1) <= class(p2) ("p1 is-a p2"). For the (TYPE
   p1, VALUE p2) combination, macOS previously called nm2_objc_is_kind_of
   with (p2's instance, p1's name) — i.e. isKindOfClass(p2, p1) — computing
   class(p2) <= p1, the REVERSE of the documented p1 <= class(p2). Since p1
   has no live instance, isKindOfClass: cannot be sent with p1 as the
   receiver; the fix asks p1's CLASS OBJECT whether IT is a subclass of p2's
   *dynamic* class (isSubclassOfClass:) instead.
 *
 * EXPECTED:
 * NY
 *)
IMPORT STextIO;

CLASS Animal;
  PROCEDURE Speak(): INTEGER;
  BEGIN RETURN 0 END Speak;
END Animal;

CLASS Dog;
  INHERIT Animal;
  OVERRIDE PROCEDURE Speak(): INTEGER;
  BEGIN RETURN 1 END Speak;
END Dog;

CLASS Puppy;
  INHERIT Dog;
  OVERRIDE PROCEDURE Speak(): INTEGER;
  BEGIN RETURN 2 END Speak;
END Puppy;

VAR a: Animal; p: Puppy;

PROCEDURE YN(b: BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("Y") ELSE STextIO.WriteString("N") END
END YN;

BEGIN
  NEW(p);
  a := p;                    (* static Animal, dynamic Puppy *)
  YN(ISMEMBER(Dog, a));      (* Dog is Puppy's SUPERCLASS, not subclass -> N *)
  YN(ISMEMBER(Puppy, a));    (* exact dynamic match -> Y *)
  STextIO.WriteLn
END t91043ismembertypevaluedirection.
