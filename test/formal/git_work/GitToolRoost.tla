----------------------------- MODULE GitToolRoost -----------------------------
(* GitTool.tla as Roost's `retire` is: it counts what `git status` shows and *)
(* commits on the branch's tip, and keeps what removing would delete besides *)
(* (`keep_before_removing`).  GitTool.roost-before.cfg is Roost before that. *)
EXTENDS GitTool
=============================================================================
