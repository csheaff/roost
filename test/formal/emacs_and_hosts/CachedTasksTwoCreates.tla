----------------------- MODULE CachedTasksTwoCreates -----------------------
(* CachedTasks.tla again, at other bounds: the runner takes one passing   *)
(* config per model, and two creations in flight beside all the rest take *)
(* too long.  A draft that makes several attempts at its prompt asks for  *)
(* each in one command, and a second conversation can start before the    *)
(* first has replied.                                                      *)
EXTENDS CachedTasks
=============================================================================
