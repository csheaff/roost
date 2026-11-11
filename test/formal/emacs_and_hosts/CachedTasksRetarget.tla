------------------------ MODULE CachedTasksRetarget ------------------------
(* CachedTasks.tla again, at other bounds: the runner takes one passing   *)
(* config per model, and B beside a task being made takes too long.  B    *)
(* changes the branch one task merges into, so this has the one task,     *)
(* with more done to it.                                                   *)
EXTENDS CachedTasks
=============================================================================
