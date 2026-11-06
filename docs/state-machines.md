# State machines

Every state machine in Roost, explicit or implicit: its states, what must always
hold, and each transition. Then the invalid states the code could actually reach,
ranked, and what became of each. The [manual](manual.md#how-it-works) says how Roost
fits together; this says what can happen to it, in what order.

Change one of these machines and you change its table here. A new way into a state,
or out of one, goes in the same commit as the code.

- [How to read this](#how-to-read-this)
- [The map](#the-map)
- [What could go wrong](#what-could-go-wrong), ranked
- Machines: [a task on its host](#a-task-on-its-host),
  [what an agent is doing](#what-an-agent-is-doing),
  [Emacs and its hosts](#emacs-and-its-hosts),
  [Git and the forge](#git-and-the-forge),
  [what you are doing in Emacs](#what-you-are-doing-in-emacs)
- [Across machines](#across-machines): what each action does in each state, who
  writes each field, what was checked and found sound, and what is known and not fixed

## How to read this

A machine is **explicit** when a field or variable names its states, as a task's
`status` does. It is **implicit** when fields, files, locks, timers, buffer locals or
process liveness together act as a state, though nothing names it. Most of Roost's
are implicit, and those are where the bugs were.

Each machine has:

- A table of states, with how you can tell which one you are in.
- Invariants, numbered within the machine: what must always hold, and where the code
  or docs promise it. **Broken** marks one the code could break. "Assumed" marks one
  the code relies on and nothing states, which is where most went wrong.
- A table of transitions, naming functions rather than lines, so that it outlasts
  edits.
- What is illegal or refused, and which findings touch it.

Finding IDs say which area of the audit found them: `LC` for a task's lifecycle,
`STATUS`, `REQUESTS`, `FORGE` and `VIEWS`.

## The map

Five things can change a task, and they run in separate processes. The registry lock
is what puts them in order, and the task's record is where they meet.

```
 agent's hooks ──────┐
 agent's reports ────┤                                  ┌─ Cached task ─┬─ Task measurement
 (relay, recorder)   ├─ Registry lock ─ Task record ─── │               ├─ Attention notice
 runner's end ───────┤    (update_hook, rpc)  │  list   │  Host refresh ├─ Verdict and turn
 poll (list_tasks) ──┤                        │ reply   └───────────────┴─ The word
 your actions (rpc) ─┘                        │
                                              ├─ Git: The merge, Worktree lock, Agent worktrees
                                              └─ tmux: A run and its pane
```

What a request does after Emacs stops waiting for it is in
[Request lifetime](#request-lifetime), and most of what goes wrong in a retry comes
from there. Which source wins when two disagree is in
[Who wins](#who-wins-hooks-reports-poll-runner). The word a row shows is derived from
all the rest, in [The word](#the-word).

## What could go wrong

An audit on 2026-11-06, at `c36517d`, found these invalid states and transitions, each
reached from a valid state through real entry points. Each had a test that failed
there, with a control that passed, so that a test can't pass for the wrong reason.
The linked issue says how to reach each. Those tests aren't in this repository until
a finding is fixed: its fix brings the test into the suite, and its row then names it.

- **S1**: work lost, wrong code merged or deleted, the wrong process steered or killed.
- **S2**: a task or view stuck with no way back from Roost short of hand edits, or
  success reported for what didn't happen.
- **S3**: a false status, a wrong notification, or advice that makes things worse.
- **S4**: cosmetic, or heals by the next poll.

Within a severity, they are ranked by what they cost and how often they happen.

| # | Finding | Sev | What goes wrong | Machine | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | LC-1 | S1 | Asking again after a cut-short removal deletes the primary checkout's branch | [Agent worktrees](#agent-worktrees) | Open, [#221](https://github.com/csheaff/roost/issues/221) |
| 2 | LC-2 | S1 | Finishing a task takes a branch or worktree its agent only used | [Agent worktrees](#agent-worktrees) | Open, [#221](https://github.com/csheaff/roost/issues/221) |
| 3 | VIEWS-1 | S1 | "Nothing would be lost" doesn't hold for what is written before you answer | [Asking before acting](#asking-before-acting) | Fixed, [#222](https://github.com/csheaff/roost/issues/222), `test_a_file_written_since_you_were_told_stops_a_discard` |
| 4 | REQUESTS-8 | S2 | On this machine, a merge that outlasts the timeout is killed with its Git and hooks, leaving your checkout half-merged | [Host request](#host-request) | Open, [#223](https://github.com/csheaff/roost/issues/223) |
| 5 | LC-3 | S2 | What a push or a checkout leaves running holds a task's lock, and refuses every way of finishing it | [Worktree lock](#worktree-lock) | Open, [#223](https://github.com/csheaff/roost/issues/223) |
| 6 | REQUESTS-1 | S2 | A refresh that can't start leaves its host unasked until Emacs restarts | [Host refresh](#host-refresh) | Open, [#225](https://github.com/csheaff/roost/issues/225) |
| 7 | REQUESTS-2 | S2 | An install cut short leaves a broken helper under its real name | [Helper copy](#helper-copy) | Open, [#225](https://github.com/csheaff/roost/issues/225) |
| 8 | STATUS-1 | S2 | A Claude task stopped before anything was said in it can never resume | [The runner's stages](#the-runners-stages) | Open, [#224](https://github.com/csheaff/roost/issues/224) |
| 9 | VIEWS-2 | S2 | A retry with an edited draft says it created a task it didn't, and drops the edit | [The creation ID](#the-creation-id) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `roost-sweep-late-a-retry-with-another-prompt-keeps-the-draft` |
| 10 | VIEWS-9, FORGE-3 | S2 | A pull request draft says it opened one it only pushed to, and `P` can't open one after a closed one | [Pushing and opening](#pushing-and-opening) | Open, [#227](https://github.com/csheaff/roost/issues/227) |
| 11 | REQUESTS-3, VIEWS-8 | S2 | Two Emacs sessions overwrite each other's review notes | [Remembered files](#remembered-files) | Open, [#225](https://github.com/csheaff/roost/issues/225) |
| 12 | STATUS-2 | S2 | Roost takes a pane changed by hand for its agent, or for gone | [A run and its pane](#a-run-and-its-pane) | Open, [#224](https://github.com/csheaff/roost/issues/224) |
| 13 | LC-4, STATUS-3 | S3 | A merge's hooks hold the registry lock, so other agents' events are lost and they stay `running` | [Registry lock](#registry-lock) | Open, [#223](https://github.com/csheaff/roost/issues/223) |
| 14 | FORGE-1 | S3 | A pull request merged with a commit made on the forge reads as not merged, and `m` forks `main` from `origin` | [Landed](#landed) | Open, [#227](https://github.com/csheaff/roost/issues/227) |
| 15 | STATUS-4 | S3 | Another tool's event ends a request that still waits, so `send` could answer a menu | [Agent status](#agent-status) | Open, [#224](https://github.com/csheaff/roost/issues/224) |
| 16 | VIEWS-5, LC-5 | S3 | A prompt goes twice when its reply was lost | [The prompt draft](#the-prompt-draft) | Open, [#226](https://github.com/csheaff/roost/issues/226) |
| 17 | VIEWS-7 | S3 | Merging takes commits made after it asked | [Asking before acting](#asking-before-acting) | Fixed, [#222](https://github.com/csheaff/roost/issues/222), `test_a_commit_made_since_you_were_asked_stops_a_merge` |
