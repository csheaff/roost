------------------------- MODULE CachedTasksOffer --------------------------
(* CachedTasks.tla again, at other bounds: the runner takes one passing   *)
(* config per model, and a task made from an offer beside all that        *)
(* CachedTasks.cfg has takes too long.  The draft of an offer leaves the  *)
(* offer waiting under its task until the draft's task is made: its host  *)
(* takes it then, and the draft asks for the host to be listed, so that   *)
(* the offer's row goes.                                                   *)
EXTENDS CachedTasks
=============================================================================
