--------------------------- MODULE NewTaskAttempts ---------------------------
(***************************************************************************)
(* A new task draft that makes several attempts at its prompt (C-c C-x).   *)
(* The steps and rules are NewTaskDraft's, which take the number of        *)
(* attempts as a constant: this module is there for configs of its own,    *)
(* which check two attempts within smaller bounds than NewTaskDraft.cfg    *)
(* checks one.                                                             *)
(***************************************************************************)
EXTENDS NewTaskDraft

=============================================================================
