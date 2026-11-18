---------------------------- MODULE TerminalSeam ----------------------------
(***************************************************************************)
(* A terminal through ghostel-tmux: the Emacs side of showing a task's     *)
(* tmux session.  docs/state-machines.md: "A terminal through              *)
(* ghostel-tmux".  Code: roost-ghostel-tmux.el; ghostel-tmux.el for what   *)
(* the package does (its sentinel, `ghostel-tmux--closing`, `--detaching`, *)
(* when it runs each hook, and its holding of calls while a minibuffer is  *)
(* open).                                                                  *)
(*                                                                         *)
(* One task, whose session is at place "A".  "B" is another session of the *)
(* same tmux server, which ghostel-tmux's own command, or tmux, can switch *)
(* a controller to.  Windows are a task's window in a frame: with          *)
(* workspaces, the task's tab or perspective there, which is on screen     *)
(* (`live`) or not.  Each step is one Emacs function run to its end; what  *)
(* Emacs runs from a timer at 0 (a hook ghostel-tmux held for the          *)
(* minibuffer, `roost--when-out-of-minibuffer`'s call) goes before any     *)
(* command, process output or later timer, in either order among itself.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Remote,        \* the task's host is another machine (`nth 0 place`)
  Workspaces,    \* `roost--workspace-backend` is tab-bar or perspective
  Frames,        \* frames the task is opened in: 1, or 2
  MaxOpens,      \* `roost-ghostel-tmux-connect-or-switch`, as Roost opens the task
  MaxOthers,     \* you show another buffer in the task's window
  MaxDrops,      \* a host's connection drops
  MaxDetaches,   \* Roost releases the terminal (`roost-ghostel-tmux-disconnect`)
  MaxMini,       \* a minibuffer you open
  MaxSwitches,   \* the controller is switched to session B
  MaxErrors,     \* `ghostel-tmux-attach` signals, as TRAMP can
  MaxTries,      \* tries of a row, 8 in `roost-ghostel-tmux--attach-again`
  SessionCanEnd, \* the task's session ends, as when its agent exits
  MaxCtl,        \* controllers, over the whole run
  MaxSi,         \* stand-ins, over the whole run
  \* Scope a finding needed, on in the base once fixed:
  HeldEnds,      \* a client ends while ghostel-tmux holds its attach hook
  Closes,        \* you close a workspace that is not on screen: a finding, VIEWS-23
  FailsInARow,   \* your open's attach signals while a row of tries is under way
  \* The code as it is: each TRUE.  FALSE is a broken variant.
  OwnSession,    \* `--stand-in-gives-way`: the controller is still the stand-in's place and session
  LookFirst,     \* `--attach-again`: a controller attaching is looked for before the tries are counted
  KeepCount,     \* `--attach-again`: the count stays while an attach is under way
  DetachedIfAttached, \* `--detached`: "Detached" for a closing client only if it had attached
  SwitchForgets, \* `--attached`: the tries of the session left are forgotten
  ReopenKeeps,   \* connect-or-switch: an attach that fails, opened from the stand-in, keeps it
  Deferred,      \* `--stand-in-shown`: the handoff waits for a timer and the minibuffer
  ProbeRechecks, \* `--try-again`'s probe looks again before it attaches
  SweepKeeps,    \* `--sweep-stand-ins` keeps one, with workspaces, whose pane has come
  GiveWayKeeps,  \* `--give-way` keeps one, with workspaces, that no window shows
  PanesSay,      \* `--pane-made`: a pane made marks its controller `--was-attached`
  AttachSays,    \* `--attach`: every stand-in of the place says it connects, and waits for it
  HiddenOnly,    \* `--give-way` and the sweep keep only one a workspace not on screen shows (`--kept-p`)
  OpenKeepsHidden, \* connect-or-switch, the pane there: keeps the stand-in a workspace not on screen shows
  ByStandIn      \* `--stand-in-gives-way` takes the stand-in its window showed, shown there still or not

Places == {"A", "B"}
Wins == 1..Frames
Ctls == 1..MaxCtl
Sis == 1..MaxSi

Other == [k |-> "other", i |-> 0, p |-> "-", s |-> "-"]
SiW(i) == [k |-> "si", i |-> i, p |-> "-", s |-> "-"]
Pane(c, s) == [k |-> "pane", i |-> c, p |-> "-", s |-> s]
Snap(p, s) == [k |-> "snap", i |-> 0, p |-> p, s |-> s]

NoCtl == [st |-> "unused", p |-> "A", s |-> "A", sid |-> FALSE, rows |-> FALSE,
          ever |-> FALSE, closing |-> FALSE, was |-> FALSE, sin |-> 0, row |-> FALSE]

VARIABLES
  ctl,     \* controllers.  p: Roost's `--place`; s: ghostel-tmux's session name;
           \* sid: `%session-changed` came; rows: the session's panes are there;
           \* ever: they came once on this client; closing: `ghostel-tmux--closing`;
           \* was: `--was-attached`; sin: `--stand-in`; row: started in a row of tries
  si,      \* stand-ins: place, `--stands-in-for` (f), what it says (t)
  win,     \* what each window shows
  live,    \* the windows on screen: in the workspace that is current
  closed,  \* windows of a workspace you closed
  snaps,   \* pane buffers a client left: [p |-> `--place`, s |-> session]
  alive,   \* each session tmux has
  lost,    \* `roost-ghostel-tmux--lost`
  timers,  \* `--try-again` timers pending, by place
  probes,  \* ssh probes of `--try-again` under way, by place
  mini,    \* a minibuffer is open
  gHeld,   \* controllers whose attach hook ghostel-tmux holds for the minibuffer
  gDue,    \* controllers whose attach hook is due now
  rHeld,   \* handoffs `roost--when-out-of-minibuffer` holds: [w |-> window, i |-> its stand-in then]
  rDue,    \* handoffs due now
  owed,    \* no try is owed the place: you detached it, it ended, or its client left it
  n,       \* how many of each bounded step
  bad      \* what a rule watches for as it happens

vars == <<ctl, si, win, live, closed, snaps, alive, lost, timers, probes,
          mini, gHeld, gDue, rHeld, rDue, owed, n, bad>>

Init ==
  /\ ctl = [c \in Ctls |-> NoCtl]
  /\ si = [i \in Sis |-> [st |-> "unused", p |-> "A", f |-> 0, t |-> "connecting"]]
  /\ win = [w \in Wins |-> Other]
  /\ live = {1}
  /\ closed = {}
  /\ snaps = {}
  /\ alive = [p \in Places |-> TRUE]
  /\ lost = [p \in Places |-> 0]
  /\ timers = [p \in Places |-> 0]
  /\ probes = [p \in Places |-> 0]
  /\ mini = FALSE
  /\ gHeld = {} /\ gDue = {} /\ rHeld = {} /\ rDue = {}
  /\ owed = [p \in Places |-> FALSE]
  /\ n = [opens |-> 0, others |-> 0, drops |-> 0, detaches |-> 0, minis |-> 0,
          switches |-> 0, errors |-> 0]
  /\ bad = [pane |-> FALSE, word |-> FALSE, handoff |-> FALSE, kept |-> FALSE,
            window |-> FALSE, try |-> FALSE, untried |-> FALSE]

-----------------------------------------------------------------------------
\* Reading the state

Live(c) == ctl[c].st = "live"
\* `roost-ghostel-tmux--find-controller`: `ghostel-tmux-controllers` lists a
\* controller while its process lives, closing or not.  X is one whose
\* process has just ended, which it no longer lists.
Found(p, x) == {c \in Ctls : Live(c) /\ c # x /\ ctl[c].p = p}
SisOf(S, p) == {i \in Sis : S[i].st = "live" /\ S[i].p = p}
Shows(W, w, i) == W[w].k = "si" /\ W[w].i = i
Away == Wins \ (live \cup closed)  \* windows of a workspace kept, not on screen
SnapsOf(p) == {x \in snaps : x.p = p}
Urgent == gDue # {} \/ rDue # {}
Calm == ~Urgent
FreeOf(f, D) == IF \E x \in D : f[x].st = "unused"
                THEN CHOOSE x \in D : f[x].st = "unused" /\ \A y \in D : f[y].st = "unused" => x <= y
                ELSE 0
Dead(S, w) == win[w].k = "si" /\ S[win[w].i].st = "dead"

\* `roost-ghostel-tmux--not-attached`: what stands in for P says so.
NA(S, p, word) == [i \in Sis |-> IF S[i].st = "live" /\ S[i].p = p
                                 THEN [S[i] EXCEPT !.t = word] ELSE S[i]]

\* `roost-ghostel-tmux--attach-again` on P, with X a controller just ended.
AttachAgain(p, x, L, T, S) ==
  LET busy == Found(p, x) # {}
      done == L[p] >= MaxTries
      wait == [l |-> IF KeepCount THEN L ELSE [L EXCEPT ![p] = 0], t |-> T, s |-> S]
      stop == [l |-> [L EXCEPT ![p] = 0], t |-> T, s |-> NA(S, p, "couldnot")]
      try == [l |-> [L EXCEPT ![p] = @ + 1], t |-> [T EXCEPT ![p] = @ + 1], s |-> S]
  IN IF LookFirst THEN (IF busy THEN wait ELSE IF done THEN stop ELSE try)
     ELSE (IF done THEN stop ELSE IF busy THEN wait ELSE try)

\* A pane of a session of P has come, to a live controller.
Arrived(p) == \E c \in Ctls : Live(c) /\ ctl[c].p = p /\ ctl[c].rows

\* `roost-ghostel-tmux--attach`: what stands in for P anywhere says it
\* connects, and waits for K.
Waits(S, p, k) == IF ~AttachSays THEN S
                  ELSE [i \in Sis |-> IF S[i].st = "live" /\ S[i].p = p
                                      THEN [S[i] EXCEPT !.t = "connecting", !.f = k] ELSE S[i]]

\* `--follow-session`: what stood in for P0, a session the controller left,
\* says "Detached" and waits for nothing.
Left(S, p0) == [i \in Sis |-> IF S[i].st = "live" /\ S[i].p = p0
                              THEN [S[i] EXCEPT !.f = 0, !.t = "detached"] ELSE S[i]]

\* `--attach`: the controller's `--stand-in`, one of those of P, if any.
FirstSi(S, p) == IF ~AttachSays \/ SisOf(S, p) = {} THEN 0 ELSE CHOOSE i \in SisOf(S, p) : TRUE

\* `roost-ghostel-tmux--kept-p`: a workspace not on screen shows stand-in I,
\* the windows on screen being L.
Hidden(W, L, i) == Workspaces /\ \E w \in Wins \ (L \cup closed) : Shows(W, w, i)

NewCtl(p, sin) == [NoCtl EXCEPT !.st = "live", !.p = p, !.s = p, !.sin = sin, !.row = lost[p] > 0]

-----------------------------------------------------------------------------
\* Roost opens the task: `roost--display-task` activates its workspace in
\* frame F, then `roost-ghostel-tmux-connect-or-switch`.  Not while a
\* minibuffer is open: `roost--open` asks its host again once it closes.

Open(f) ==
  /\ Calm /\ ~mini /\ n.opens < MaxOpens /\ f \in Wins \ closed
  /\ LET W0 == IF f \notin live /\ Dead(si, f) THEN [win EXCEPT ![f] = Other] ELSE win
         L0 == live \cup {f}
         shown == W0[f]
         \* `roost-ghostel-tmux--sweep-stand-ins`
         keeps(i) == LET c == si[i].f IN
                       c # 0 /\ Live(c) /\ ctl[c].p = si[i].p
                       /\ (~ctl[c].rows \/ (Workspaces /\ SweepKeeps
                                             /\ (~HiddenOnly \/ Hidden(W0, L0, i))))
         swept == {i \in Sis : si[i].st = "live" /\ ~(\E w \in L0 : Shows(W0, w, i)) /\ ~keeps(i)}
         S0 == [i \in Sis |-> IF i \in swept THEN [si[i] EXCEPT !.st = "dead"] ELSE si[i]]
         sweptKept == \E w \in Wins \ (L0 \cup closed) :
                        W0[w].k = "si" /\ W0[w].i \in swept /\ Arrived(si[W0[w].i].p)
         C == Found("A", 0)
         reuse == shown.k = "si" /\ S0[shown.i].st = "live" /\ S0[shown.i].p = "A"
         fresh == FreeOf(S0, Sis)
         \* `roost-ghostel-tmux--stand-in-for`
         standIn == IF reuse THEN shown.i ELSE fresh
         S1 == [S0 EXCEPT ![standIn] = [st |-> "live", p |-> "A", f |-> @.f, t |-> "connecting"]]
         k == FreeOf(ctl, Ctls)
         opened == [n EXCEPT !.opens = @ + 1]
         failed == [n EXCEPT !.opens = @ + 1, !.errors = @ + 1]
     IN /\ live' = L0
        /\ UNCHANGED <<closed, alive, timers, probes, mini, gHeld, gDue, rHeld, rDue>>
        /\ \/ \* The pane is there: shown, and what stood in for it here goes.
              \E c \in C :
                /\ ctl[c].rows
                /\ LET gone == /\ reuse /\ ~(\E w \in L0 \ {f} : Shows(W0, w, shown.i))
                               /\ (~OpenKeepsHidden \/ ~Hidden(W0, L0, shown.i))
                   IN /\ win' = [W0 EXCEPT ![f] = Pane(c, ctl[c].s)]
                      /\ si' = IF gone THEN [S0 EXCEPT ![shown.i].st = "dead"] ELSE S0
                      /\ bad' = [bad EXCEPT
                                   !.pane = @ \/ ctl[c].s # "A",
                                   !.kept = @ \/ sweptKept
                                             \/ (gone /\ \E w \in Wins \ (L0 \cup closed) :
                                                           Shows(W0, w, shown.i))]
                /\ n' = opened
                /\ UNCHANGED <<ctl, snaps, lost, owed>>
           \/ \* Its first pane is yet to come: this window waits for it too.
              \E c \in C :
                /\ ~ctl[c].rows
                /\ LET own == ctl[c].sin # 0 /\ S0[ctl[c].sin].st = "live"
                       i == IF own THEN ctl[c].sin ELSE standIn
                       S2 == IF own THEN S0 ELSE S1
                   IN /\ i # 0
                      /\ si' = [S2 EXCEPT ![i].f = c]
                      /\ ctl' = [ctl EXCEPT ![c].sin = i]
                      /\ win' = [W0 EXCEPT ![f] = SiW(i)]
                      /\ bad' = [bad EXCEPT !.kept = @ \/ sweptKept]
                /\ n' = opened
                /\ UNCHANGED <<snaps, lost, owed>>
           \/ \* A pane the session's last connection left: attached where it is.
              /\ C = {}
              /\ shown.k = "snap" /\ shown.p = "A"
              /\ \/ /\ k # 0
                    /\ ctl' = [ctl EXCEPT ![k] = NewCtl("A", FirstSi(S0, "A"))]
                    /\ owed' = [owed EXCEPT !["A"] = FALSE]
                    /\ n' = opened
                    /\ si' = Waits(S0, "A", k)
                 \/ /\ n.errors < MaxErrors  \* the error is yours to read
                    /\ n' = failed
                    /\ UNCHANGED <<ctl, owed>>
                    /\ si' = S0
              /\ win' = W0
              /\ bad' = [bad EXCEPT !.kept = @ \/ sweptKept]
              /\ UNCHANGED <<snaps, lost>>
           \/ \* Nothing of it: a stand-in, then the attach.
              /\ C = {}
              /\ ~(shown.k = "snap" /\ shown.p = "A")
              /\ standIn # 0
              /\ \/ /\ k # 0
                    /\ ctl' = [ctl EXCEPT ![k] = NewCtl("A", standIn)]
                    /\ si' = Waits([S1 EXCEPT ![standIn].f = k], "A", k)
                    /\ win' = [W0 EXCEPT ![f] = SiW(standIn)]
                    /\ owed' = [owed EXCEPT !["A"] = FALSE]
                    /\ n' = opened
                    /\ bad' = [bad EXCEPT !.kept = @ \/ sweptKept]
                 \/ /\ n.errors < MaxErrors
                    /\ FailsInARow \/ lost["A"] = 0
                    /\ n' = failed
                    /\ UNCHANGED <<ctl, owed>>
                    /\ IF reuse /\ ReopenKeeps
                       THEN \* opened again from it: it says so of this try
                            /\ si' = NA(S1, "A", "couldnot")
                            /\ win' = [W0 EXCEPT ![f] = SiW(standIn)]
                            /\ bad' = [bad EXCEPT !.kept = @ \/ sweptKept]
                       ELSE \* the window is put back, and the stand-in goes
                            LET back == IF shown.k = "si" /\ shown.i = standIn THEN Other ELSE shown
                            IN /\ si' = [S1 EXCEPT ![standIn].st = "dead"]
                               /\ win' = [W0 EXCEPT ![f] = back]
                               /\ bad' = [bad EXCEPT !.kept = @ \/ sweptKept,
                                                     !.window = @ \/ (back = Other /\ shown # Other)]
              /\ UNCHANGED <<snaps, lost>>

\* Roost opens another task, in another window or workspace: of this task,
\* only `roost-ghostel-tmux--sweep-stand-ins` is run.
OpenOther ==
  /\ Calm /\ ~mini /\ n.opens < MaxOpens
  /\ LET keeps(i) == LET c == si[i].f IN
                       c # 0 /\ Live(c) /\ ctl[c].p = si[i].p
                       /\ (~ctl[c].rows \/ (Workspaces /\ SweepKeeps
                                             /\ (~HiddenOnly \/ Hidden(win, live, i))))
         swept == {i \in Sis : si[i].st = "live" /\ ~(\E w \in live : Shows(win, w, i)) /\ ~keeps(i)}
     IN /\ si' = [i \in Sis |-> IF i \in swept THEN [si[i] EXCEPT !.st = "dead"] ELSE si[i]]
        /\ bad' = [bad EXCEPT !.kept = @ \/ \E w \in Away :
                                 win[w].k = "si" /\ win[w].i \in swept /\ Arrived(si[win[w].i].p)]
  /\ n' = [n EXCEPT !.opens = @ + 1]
  /\ UNCHANGED <<ctl, win, live, closed, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed>>

-----------------------------------------------------------------------------
\* ghostel-tmux: a controller's tmux client

\* `%session-changed`, or tmux's "can't find session" and `%exit`
\* (`%error` then `%exit`, as tmux 3.6a answers `attach -t =gone:`).
Hello(c) ==
  /\ Calm /\ Live(c) /\ ~ctl[c].sid /\ ~ctl[c].closing
  /\ ctl' = IF alive[ctl[c].s] THEN [ctl EXCEPT ![c].sid = TRUE]
            ELSE [ctl EXCEPT ![c].closing = TRUE]
  /\ UNCHANGED <<si, win, live, closed, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, n, bad>>

\* `ghostel-tmux--receive-window-rows` with SEED: the panes are made, the
\* panes a client left come alive where they are, and the attach hook runs,
\* or waits while a minibuffer is open (`ghostel-tmux--hold`).
Rows(c) ==
  /\ Calm /\ Live(c) /\ ctl[c].sid /\ ~ctl[c].rows /\ ~ctl[c].closing /\ alive[ctl[c].s]
  /\ LET s == ctl[c].s
         p0 == ctl[c].p
         \* `--pane-made`, on `ghostel-tmux-pane-mode-hook`, which is not held:
         \* `--follow-session`, then the controller is marked attached.
         sw == PanesSay /\ s # p0
     IN /\ ctl' = [ctl EXCEPT ![c].rows = TRUE, ![c].ever = TRUE, ![c].was = (@ \/ PanesSay),
                               ![c].p = IF sw THEN s ELSE @]
        /\ si' = IF sw THEN Left(si, p0) ELSE si
        /\ lost' = IF sw THEN [lost EXCEPT ![p0] = 0] ELSE lost
        /\ owed' = IF sw THEN [owed EXCEPT ![p0] = TRUE] ELSE owed
        /\ win' = [w \in Wins |-> IF (win[w].k = "snap" /\ win[w].s = s)
                                     \/ (win[w].k = "pane" /\ win[w].i = c)
                                  THEN Pane(c, s) ELSE win[w]]
        /\ snaps' = {x \in snaps : x.s # s}
  /\ IF mini THEN gHeld' = gHeld \cup {c} /\ gDue' = gDue
     ELSE gDue' = gDue \cup {c} /\ gHeld' = gHeld
  /\ UNCHANGED <<live, closed, alive, timers, probes, mini, rHeld, rDue, n, bad>>

\* `ghostel-tmux-switch-session`, or tmux itself, moves the client to B:
\* `--on-session-changed` names it at once and wipes the panes.
Switch(c) ==
  /\ Calm /\ Live(c) /\ ctl[c].sid /\ ~ctl[c].closing /\ ctl[c].s = "A"
  /\ n.switches < MaxSwitches
  /\ ctl' = [ctl EXCEPT ![c].s = "B", ![c].rows = FALSE]
  /\ win' = [w \in Wins |-> IF win[w].k = "pane" /\ win[w].i = c THEN Pane(c, "B") ELSE win[w]]
  /\ n' = [n EXCEPT !.switches = @ + 1]
  /\ UNCHANGED <<si, live, closed, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, bad>>

\* The task's session ends: tmux sends `%exit` to each client attached.
SessionEnds ==
  /\ Calm /\ SessionCanEnd /\ alive["A"]
  /\ alive' = [alive EXCEPT !["A"] = FALSE]
  /\ ctl' = [c \in Ctls |-> IF Live(c) /\ ctl[c].s = "A" /\ ctl[c].sid
                            THEN [ctl[c] EXCEPT !.closing = TRUE] ELSE ctl[c]]
  /\ UNCHANGED <<si, win, live, closed, snaps, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, n, bad>>

\* The client ends.  HOW is "drop" (an ssh that ends: no `%exit` reaches
\* Emacs), "exit" (after `%exit`: `ghostel-tmux--closing`) or "detach"
\* (`roost-ghostel-tmux-disconnect`: `ghostel-tmux-detach` with KEEP,
\* whose `delete-process` runs the sentinel at once).  `ghostel-tmux--sentinel`
\* runs `ghostel-tmux-detach-hook` (`roost-ghostel-tmux--detached`), seals
\* or kills the panes, and kills the controller: a hook it held is dropped
\* (`ghostel-tmux--run-held-calls` skips a dead buffer).
End(c, how) ==
  /\ Calm /\ Live(c)
  /\ HeldEnds \/ c \notin gHeld
  /\ CASE how = "drop" -> Remote /\ ~ctl[c].closing /\ n.drops < MaxDrops
       [] how = "exit" -> ctl[c].closing
       [] how = "detach" -> ctl[c].p = "A" /\ n.detaches < MaxDetaches
  /\ LET det == how = "detach"
         clo == how # "drop"
         p == ctl[c].p
         s == ctl[c].s
         retry == Remote /\ ~det /\ ~clo /\ (ctl[c].was \/ lost[p] > 0)
         again == AttachAgain(p, c, lost, timers, si)
         detachedWord == det \/ (IF DetachedIfAttached THEN ctl[c].was /\ clo ELSE clo)
         word == IF detachedWord THEN "detached" ELSE "couldnot"
         L1 == IF retry THEN again.l ELSE IF clo THEN [lost EXCEPT ![p] = 0] ELSE lost
         T1 == IF retry THEN again.t ELSE timers
         S1 == IF retry THEN again.s ELSE NA(si, p, word)
         wrong == /\ ~retry /\ SisOf(si, p) # {}
                  /\ IF word = "couldnot" THEN ctl[c].ever ELSE ~ctl[c].ever /\ ~det
         untried == /\ how = "drop" /\ (ctl[c].ever \/ ctl[c].row)
                    /\ lost[p] < MaxTries /\ Found(p, c) = {}
                    /\ ~(T1[p] > timers[p])
         \* `ghostel-tmux--keep-panes-p`, `ghostel-tmux-keep-detached-panes` as it comes
         keep == det \/ ~(clo /\ ~Remote /\ alive[s])
     IN /\ ctl' = [ctl EXCEPT ![c].st = "dead", ![c].closing = clo]
        /\ si' = S1
        /\ lost' = L1
        /\ timers' = T1
        /\ win' = [w \in Wins |-> IF win[w].k = "pane" /\ win[w].i = c
                                  THEN (IF keep THEN Snap(p, s) ELSE Other) ELSE win[w]]
        /\ snaps' = IF keep /\ ctl[c].rows THEN snaps \cup {[p |-> p, s |-> s]} ELSE snaps
        /\ owed' = IF clo THEN [owed EXCEPT ![p] = TRUE] ELSE owed
        /\ gHeld' = gHeld \ {c}
        /\ n' = CASE how = "drop" -> [n EXCEPT !.drops = @ + 1]
                  [] how = "detach" -> [n EXCEPT !.detaches = @ + 1]
                  [] OTHER -> n
        /\ bad' = [bad EXCEPT !.word = @ \/ wrong, !.untried = @ \/ untried]
  /\ UNCHANGED <<live, closed, alive, probes, mini, gDue, rHeld, rDue>>

-----------------------------------------------------------------------------
\* `roost-ghostel-tmux--attached`, on `ghostel-tmux-attach-hook`, in C.

Attached(c) ==
  LET p0 == ctl[c].p
      s == ctl[c].s
      sw == s # p0   \* ghostel-tmux's own command switched it
      S1 == IF sw THEN Left(si, p0) ELSE si
      L1 == IF sw /\ SwitchForgets THEN [lost EXCEPT ![p0] = 0] ELSE lost
      GW == IF ctl[c].rows THEN {i \in Sis : S1[i].st = "live" /\ S1[i].p = s} ELSE {}
      ws == {w \in live : win[w].k = "si" /\ win[w].i \in GW}
      \* `roost-ghostel-tmux--give-way`
      K == {i \in GW : ~Workspaces \/ ~GiveWayKeeps
                       \/ IF HiddenOnly THEN ~Hidden(win, live, i) ELSE \E w \in ws : win[w].i = i}
  IN /\ si' = [i \in Sis |-> IF i \in K THEN [S1[i] EXCEPT !.st = "dead", !.f = c]
                             ELSE IF i \in GW THEN [S1[i] EXCEPT !.f = c]
                             ELSE S1[i]]
     /\ win' = [w \in Wins |-> IF w \in ws THEN Pane(c, s)
                               ELSE IF w \in live /\ win[w].k = "snap" /\ win[w].p = s THEN Other
                               ELSE win[w]]
     /\ snaps' = {x \in snaps : x.p # s}
     /\ lost' = [L1 EXCEPT ![s] = 0]
     /\ ctl' = [ctl EXCEPT ![c].p = s, ![c].was = TRUE,
                           ![c].sin = IF ctl[c].rows THEN 0 ELSE @]
     /\ owed' = IF sw THEN [owed EXCEPT ![p0] = TRUE] ELSE owed
     /\ bad' = [bad EXCEPT !.kept = @ \/ \E w \in Away : win[w].k = "si" /\ win[w].i \in K]

\* `roost-ghostel-tmux--stand-in-gives-way` for stand-in I, which window W
\* showed as `--stand-in-shown` ran, as a result record.  IN_HOOK: run from
\* `window-buffer-change-functions` itself.
GivesWay(w, i, L, inHook) ==
  LET c == si[i].f
      ok == /\ (ByStandIn \/ (w \in L /\ Shows(win, w, i)))
            /\ si[i].st = "live"
            /\ c # 0 /\ Live(c)
            /\ (~OwnSession \/ (ctl[c].p = si[i].p /\ (~ctl[c].sid \/ ctl[c].s = si[i].p)))
            /\ ctl[c].rows
      ws == {v \in L : Shows(win, v, i)}
      \* `--give-way`: kept for a workspace not on screen that shows it
      keep == HiddenOnly /\ Hidden(win, L, i)
  IN IF ok
     THEN [si |-> IF keep THEN si ELSE [si EXCEPT ![i].st = "dead"],
           win |-> [v \in Wins |-> IF v \in ws THEN Pane(c, ctl[c].s) ELSE win[v]],
           pane |-> ctl[c].s # si[i].p,
           handoff |-> inHook \/ mini,
           kept |-> ~keep /\ \E v \in Wins \ (L \cup closed) : Shows(win, v, i)]
     ELSE [si |-> si, win |-> win, pane |-> FALSE, handoff |-> FALSE, kept |-> FALSE]

-----------------------------------------------------------------------------
\* What runs from a timer at 0

RunHook(c) ==
  /\ c \in gDue
  /\ gDue' = gDue \ {c}
  /\ IF Live(c) THEN Attached(c) ELSE UNCHANGED <<si, win, snaps, lost, ctl, owed, bad>>
  /\ UNCHANGED <<live, closed, alive, timers, probes, mini, gHeld, rHeld, rDue, n>>

RunHandoff(x) ==
  /\ x \in rDue
  /\ rDue' = rDue \ {x}
  /\ IF mini
     THEN rHeld' = rHeld \cup {x} /\ UNCHANGED <<si, win, bad>>
     ELSE LET g == GivesWay(x.w, x.i, live, FALSE) IN
          /\ rHeld' = rHeld
          /\ si' = g.si /\ win' = g.win
          /\ bad' = [bad EXCEPT !.pane = @ \/ g.pane, !.handoff = @ \/ g.handoff,
                                !.kept = @ \/ g.kept]
  /\ UNCHANGED <<ctl, live, closed, snaps, alive, lost, timers, probes, mini, gHeld, gDue, owed, n>>

-----------------------------------------------------------------------------
\* Tries of a host whose connection dropped

\* `roost-ghostel-tmux--try-again` from its timer.
Fire(p) ==
  /\ Calm /\ timers[p] > 0
  /\ timers' = [timers EXCEPT ![p] = @ - 1]
  /\ CASE lost[p] = 0 \/ Found(p, 0) # {} -> UNCHANGED <<lost, si, probes>>
       [] SnapsOf(p) = {} -> /\ lost' = [lost EXCEPT ![p] = 0]
                             /\ si' = NA(si, p, "couldnot")
                             /\ UNCHANGED probes
       [] OTHER -> /\ probes' = [probes EXCEPT ![p] = @ + 1]
                   /\ UNCHANGED <<lost, si>>
  /\ UNCHANGED <<ctl, win, live, closed, snaps, alive, mini, gHeld, gDue, rHeld, rDue, owed, n, bad>>

\* The probe's sentinel: OK, the host answered.
Probe(p, ok) ==
  /\ Calm /\ probes[p] > 0
  /\ probes' = [probes EXCEPT ![p] = @ - 1]
  /\ LET want == lost[p] > 0 /\ Found(p, 0) = {} /\ SnapsOf(p) # {}
         k == FreeOf(ctl, Ctls)
         again == AttachAgain(p, 0, lost, timers, si)
     IN IF ok /\ (want \/ (~ProbeRechecks /\ Found(p, 0) = {}))
        THEN \/ /\ k # 0
                /\ ctl' = [ctl EXCEPT ![k] = NewCtl(p, FirstSi(si, p))]
                /\ si' = Waits(si, p, k)
                /\ bad' = [bad EXCEPT !.try = @ \/ owed[p]]
                /\ UNCHANGED <<lost, timers, n>>
             \/ /\ n.errors < MaxErrors
                /\ n' = [n EXCEPT !.errors = @ + 1]
                /\ lost' = again.l /\ timers' = again.t /\ si' = again.s
                /\ UNCHANGED <<ctl, bad>>
        ELSE /\ IF lost[p] > 0
                THEN lost' = again.l /\ timers' = again.t /\ si' = again.s
                ELSE UNCHANGED <<lost, timers, si>>
             /\ UNCHANGED <<ctl, n, bad>>
  /\ UNCHANGED <<win, live, closed, snaps, alive, mini, gHeld, gDue, rHeld, rDue, owed>>

-----------------------------------------------------------------------------
\* You

MiniOpen ==
  /\ Calm /\ ~mini /\ n.minis < MaxMini
  /\ mini' = TRUE
  /\ n' = [n EXCEPT !.minis = @ + 1]
  /\ UNCHANGED <<ctl, si, win, live, closed, snaps, alive, lost, timers, probes,
                 gHeld, gDue, rHeld, rDue, owed, bad>>

\* The minibuffer closes: what both packages held is due.
MiniClose ==
  /\ Calm /\ mini
  /\ mini' = FALSE
  /\ gDue' = gHeld /\ gHeld' = {}
  /\ rDue' = rHeld /\ rHeld' = {}
  /\ UNCHANGED <<ctl, si, win, live, closed, snaps, alive, lost, timers, probes, owed, n, bad>>

\* You go back to the task's workspace in frame W, by its tab, not by Roost:
\* `window-buffer-change-functions` runs `--stand-in-shown` for a stand-in.
Enter(w) ==
  /\ Calm /\ Workspaces /\ w \notin live /\ w \notin closed
  /\ live' = live \cup {w}
  /\ IF Dead(si, w)
     THEN win' = [win EXCEPT ![w] = Other] /\ UNCHANGED <<si, rDue, bad>>
     ELSE IF win[w].k = "si"
     THEN IF Deferred
          THEN rDue' = rDue \cup {[w |-> w, i |-> win[w].i]} /\ UNCHANGED <<si, win, bad>>
          ELSE LET g == GivesWay(w, win[w].i, live \cup {w}, TRUE) IN
               /\ si' = g.si /\ win' = g.win /\ rDue' = rDue
               /\ bad' = [bad EXCEPT !.pane = @ \/ g.pane, !.handoff = @ \/ g.handoff,
                                     !.kept = @ \/ g.kept]
     ELSE UNCHANGED <<si, win, rDue, bad>>
  /\ UNCHANGED <<ctl, closed, snaps, alive, lost, timers, probes, mini, gHeld, gDue, rHeld, owed, n>>

Leave(w) ==
  /\ Calm /\ Workspaces /\ w \in live
  /\ live' = live \ {w}
  /\ UNCHANGED <<ctl, si, win, closed, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, n, bad>>

\* You close the task's workspace in frame W, which is not on screen.
Close(w) ==
  /\ Calm /\ Closes /\ Workspaces /\ w \in Away
  /\ closed' = closed \cup {w}
  /\ UNCHANGED <<ctl, si, win, live, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, n, bad>>

\* You show another buffer in the task's window: `q`, or `C-x b`.
ShowOther(w) ==
  /\ Calm /\ w \in live /\ win[w] # Other /\ n.others < MaxOthers
  /\ win' = [win EXCEPT ![w] = Other]
  /\ n' = [n EXCEPT !.others = @ + 1]
  /\ UNCHANGED <<ctl, si, live, closed, snaps, alive, lost, timers, probes, mini,
                 gHeld, gDue, rHeld, rDue, owed, bad>>

-----------------------------------------------------------------------------

Next ==
  \/ \E f \in Wins : Open(f)
  \/ OpenOther
  \/ \E c \in Ctls : Hello(c) \/ Rows(c) \/ Switch(c) \/ RunHook(c)
                     \/ \E how \in {"drop", "exit", "detach"} : End(c, how)
  \/ SessionEnds
  \/ \E p \in Places : Fire(p) \/ \E ok \in BOOLEAN : Probe(p, ok)
  \/ MiniOpen \/ MiniClose
  \/ \E x \in rDue : RunHandoff(x)
  \/ \E w \in Wins : Enter(w) \/ Leave(w) \/ Close(w) \/ ShowOther(w)
  \/ UNCHANGED vars  \* bounded runs end; that is no deadlock

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Rules, numbered as the section's invariants

TypeOK ==
  /\ \A c \in Ctls : ctl[c].st \in {"unused", "live", "dead"} /\ ctl[c].p \in Places
  /\ \A i \in Sis : si[i].t \in {"connecting", "couldnot", "detached"}
  /\ live \subseteq Wins /\ closed \subseteq Wins

\* I1: a window never shows another session's pane in place of a stand-in,
\* or as its task opens.
OwnPane == ~bad.pane

\* I2: no stand-in says "Connecting to" once no client for its place is
\* attaching and no try is due.
ConnectingIsTrue ==
  \A i \in Sis : si[i].st = "live" /\ si[i].t = "connecting" =>
    \/ \E c \in Ctls : Live(c) /\ ctl[c].p = si[i].p
    \/ lost[si[i].p] > 0 /\ timers[si[i].p] + probes[si[i].p] > 0

\* I2, the other way: none says no pane is coming while a client for its
\* place attaches.
EndIsTrue ==
  \A i \in Sis : si[i].st = "live" /\ si[i].t # "connecting" =>
    ~\E c \in Ctls : Live(c) /\ ~ctl[c].closing /\ ctl[c].p = si[i].p /\ ~ctl[c].rows

\* I3: a stand-in says "Could not attach" only of a client whose panes never
\* came, and "Detached" only of one whose had, or that you detached.
WordIsTrue == ~bad.word

\* I4: a retry is never owed to a place you detached, whose session ended,
\* or that its client left; and no try attaches one.
RetryOnlyDropped == (\A p \in Places : owed[p] => lost[p] = 0) /\ ~bad.try

\* I4: a host's connection that drops after its panes came, or in a row of
\* tries, is tried again.
DropIsTried == ~bad.untried

\* I5: tries end.
TriesEnd == \A p \in Places : lost[p] <= MaxTries

\* I7: one controller attaching or attached for a place.
OneController ==
  \A p \in Places : Cardinality({c \in Ctls : Live(c) /\ ~ctl[c].closing /\ ctl[c].p = p}) <= 1

\* I6: the pane takes the stand-in's window only when no question is open,
\* and not from the window-change hook itself.
HandoffOutside == ~bad.handoff

\* I1: an open leaves its window showing the task, or what it showed before.
OpenKeepsWindow == ~bad.window

\* I6: a stand-in a workspace you left shows is not killed once its pane has
\* come: the workspace would show some other buffer when you are back.
KeptForItsWorkspace == ~bad.kept

\* I6: no stand-in is kept that no window, in any workspace, shows, once its
\* pane has come and the attach hook has run, and no handoff of it waits for
\* a question to end.
NoStrayStandIn ==
  \A i \in Sis :
    (si[i].st = "live" /\ si[i].f # 0 /\ Live(si[i].f) /\ ctl[si[i].f].rows
     /\ ctl[si[i].f].p = si[i].p /\ si[i].f \notin gHeld \cup gDue
     /\ ~\E x \in rHeld \cup rDue : x.i = i)
    => \E w \in Wins \ closed : Shows(win, w, i)

=============================================================================
