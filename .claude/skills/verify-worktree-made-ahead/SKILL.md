---
name: verify-worktree-made-ahead
description: >
  Model-check the worktree Roost keeps made ahead for a project's next task
  (`roost-ready-worktrees`): a creation taking one, the wish each creation
  leaves and the run that carries it out, a listing's run that removes what
  no task will take, and any of them killed between two steps. Use before
  committing a change to take_ready_for, take_ready, begin_head_log,
  tend_one, tend_wanted, tend_ready, tend_ready_later, want_ready,
  sweep_ready, unwanted_ready, drop_ready, prune_ready_later, the TAKING
  branch of undo_creation, or where make_task and main call them, in
  scripts/roost_remote.py; when "Worktree made ahead" in
  docs/state-machines.md changes; or for /verify-worktree-made-ahead. Not
  for the worktree a task's runner makes in its terminal, nor for finishing
  a task (that is verify-task-on-host).
---

# Verify the worktree made ahead

`test/formal/worktree_made_ahead/WorktreeMadeAhead.tla` is a TLA+ model of
the state directory's `ready/` folder for one repository: its marks and
folders, its one wish, and its two locks. TLC tries every order of the
steps of two or three creations, the run each leaves behind, and a
listing's run, with any of them killed between two steps, a file someone
wrote in a folder under `ready/`, Git failing where it may, and a week
passing. `make crash`'s `CreateFromReady` kills one creation at each step;
this reaches the orders of several processes at once.

## The rules

Numbered as the section's invariants in `docs/state-machines.md`.

- **TakenOnce** (I1). A worktree made ahead is one request's at a time: no
  two creations take it, and none takes one a run is moving to another
  commit or removing. Harm: two tasks at work in one folder, or a task
  starting in one Git is still checking out.
- **TakenClean** (I2). A task takes only one holding nothing but Git's
  checkout. Harm: a task starts with a file someone else wrote, which its
  agent commits, or which keeps it from retiring.
- **StartsAsAdded** (I3). A task taken from one starts as `git worktree
  add` would make it: at its path, on its branch, made in the primary
  checkout, at its start, its HEAD's reflog begun anew, unlocked, with
  `post-checkout` run once as for a new worktree. Harm: commits the task
  never made counted as its own, a hook that ran as for a switch, or
  reference-transaction hooks run in the wrong place.
- **NoWishLost** (I4). Once nothing is under way and no run was killed, no
  wish waits, and what is there is what the last wish asked for. Harm: the
  next task finds none made ahead, or one stays after you turned it off.
- **NothingLeft** (I5). Once nothing is under way and a sweep begun since
  the last crash has ended, every mark says ready, of a worktree that is
  there, one at most, and none once a wish to keep none was carried out;
  and a creation cut short, once settled, leaves its worktree only if
  something was written there, and never its branch. Harm: folders and
  branches nobody's, kept for ever.
- **ReadyIsThere** (the table's Ready). What a mark calls ready is there
  under `ready/`, detached at the mark's commit, unlocked, with no take
  and no run at it. Harm: every task tries to take what isn't there.

## Does the change touch it?

```
python3 test/formal/worktree_made_ahead/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the model (below) before you trust a
pass. `make_task`, `main`, `abandon` and `initializing` are other sections'
too: a change to them that touches no `ready`, `take_ready_for`,
`tend_ready_later`, `prune_ready_later` or TAKING is theirs.

## Run it

```
python3 test/formal/check.py worktree_made_ahead
```

Under a minute, fourteen runs. Every line must say `ok`.
`WorktreeMadeAhead.cfg` and `WorktreeMadeAheadThree.cfg` must pass; each
`WorktreeMadeAhead.<variant>.cfg` breaks one guard, through the `Break`
constant, and must fail on the rule its first line names, which proves the
rule can still fail. `make formal` runs every model. TLC and Java come
from mise.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the model says

One repository. Each worktree made ahead has a mark (`none`, not ready,
ready, and the commit it names), a folder (none, under `ready/`, at a
task's path, in the trash), what it has checked out, whether its HEAD's
reflog still names where it was ahead, whether someone wrote in it, Git's
TAKING lock, and how `post-checkout` ran in it. The wish is a commit,
whether to keep one, and the `at` that tells two wishes apart.

| Model | Code in scripts/roost_remote.py |
| --- | --- |
| `Ask`, `GitMakes` | `make_task`: asked with `ready` or not; the worktree Git makes when none is taken |
| `TakeBegins` | `take_ready_for`: no mark of the repository's, or its branch made in the primary checkout |
| `TakeMarks`, `TakeMoves`, `TakeUnmarks` | `take_ready`, under `ready_locked`: the mark written not ready, `git worktree move`, the mark removed |
| `TakeLocks`, `TakeChecks`, `SetAside` | `take_ready_for`: the TAKING lock, `changed_in`, and what it sets aside into the trash as nobody's (`trash_worktree`), its branch deleted |
| `TakeChecksOut`, `TakeBeginsLog`, `TakeUnlocks`, `TakeHooks` | `take_ready_for`: the checkout with no hook, `begin_head_log`, the unlock, `git hook run post-checkout`, and `abandon` when it fails |
| `Replies` | `main` once a creation has replied: `tend_ready_later`, `want_ready` |
| `RunTries`, `RunReads`, `RunLetsGo`, `RunLooks`, `RunUnwishes` | `tend_wanted`: `ready/.tending`, the wishes read, the look after letting go, the wish removed if unchanged |
| `RunSweeps`, `PruneSweeps`, `RunDrops` | `sweep_ready`, `unwanted_ready`, `unmarked_ready`, `drop_ready` |
| `RunMoves`, `RunBegins`, `RunAdds`, `RunMarksReady` | `tend_one`: the one kept moved to the wish's commit, or one made, then marked ready |
| `Lists`, `PruneLooks` | `main` once a listing has replied: `prune_ready_later` |
| `Settles` | `settle_creation`, `undo_creation`: its TAKING branch, else `abandon` |
| `CreationDies`, `RunDies` | a reboot or a dropped connection: the kernel lets go of its locks, and marks, folders, branch and Git's lock stay |
| `SomeoneWrites`, `WeekPasses` | a file written in a folder under `ready/`; `READY_DAYS` |

A take's steps from the mark to the mark's removal hold `ready/.lock`, so
no other step that needs it comes between them; a crash may. A run holds
it only for a sweep's marking and for a wish, each one step. Git's own
steps on a folder (`git worktree add`, `checkout --detach`, `remove`) are
one step each, and may fail.

## Bounds, and what is left out

`WorktreeMadeAhead.cfg`: two creations, with or without one made ahead as
they begin, three made in all, a listing, two processes killed, one file
written in, and a week passing. `WorktreeMadeAheadThree.cfg`: three
creations, so that two race for one the first's run made and a run meets
three wishes, with a file written in and nothing killed.

Checked once and in no config, for its five minutes: three creations with
one process killed and a listing (125 million states) passes.

Left out, by design or as covered elsewhere:

- A second repository. `tend_wanted` carries out each repository's wish in
  turn and looks again, as for one; `sweep_ready` for one repository
  removes another's only when `unwanted_ready` says so, as a listing's
  does.
- Git older than 2.36 (`runs_hooks_alone`), where nothing is made or
  taken, and a repository gone, which reads as old does.
- What the task's own `post-checkout` hook writes at the take, which is
  the task's: `test_what_the_tasks_own_hook_writes_is_kept_and_its_failure_said`
  and `test_a_take_cut_short_keeps_what_the_hook_wrote_and_nothing_else`
  hold it. A hook that fails here removes a worktree that holds nothing.
- The branch tracking nothing (`branch.autoSetupMerge=false`), which is no
  matter of order: `test_a_task_starts_from_a_worktree_made_ahead_on_its_own_branch`.
- That reading a folder runs no program its config names (`read_git`):
  `test_reading_one_made_ahead_runs_no_program_its_config_names`.
- A file written at the task's path between `changed_in` and the checkout,
  as by a process whose working directory was the folder under `ready/`:
  milliseconds, as with every check before an act in these models.
- The trash, once something is set aside there: `empty_trash` deletes what
  no record names (`verify-task-on-host` says how).
- The worktree Git makes when none is taken, and all of creation but the
  take: `make crash`'s `Create`, `CreateFromReady` and `CreateInTerminal`.

`TakenOnce` is about who is at a worktree, not where its folder ends up:
Git's rename lets only one `git worktree move` of a folder succeed, and
the model has the second fail as Git would. The rule fails before that,
when two requests have chosen the same one. Roost's own lock and mark are
what it checks.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it, at that point, with
that lock held or not. If it can, it is a bug: keep the rule, add a
`WorktreeMadeAhead.finding-<what>.cfg` that shows it (`\* expect: Rule`),
replay it on real Git (`test/test_remote.py`'s `tend` and `create(ready=True)`,
or `test/crash_harness.py`'s `Box`), and report it with those steps. Do not
weaken a rule or a bound until it passes, and do not fix product code
unless asked. If a step can't happen in the code, the model is wrong: fix
the action and point its comment at the code that rules the step out.

### Findings

None open: the model found nothing in the code at `c1616b6`.

Each variant undoes one guard. Those of `TakenClean`, `StartsAsAdded` and
`NoWishLost` each undo a fix made in review of #316 or #319, before the
model:

- `taken-twice` (`TakenOnce`): a take with no hold of `ready/.lock` and no
  mark written first.
- `taken-while-moved` (`TakenOnce`): a run leaves the one it keeps marked
  ready while it moves it.
- `ready-while-moved` (`ReadyIsThere`): a take leaves the mark saying
  ready until Git has moved the folder, and is killed then.
- `written-in-taken` (`TakenClean`): a take doesn't read the folder before
  its branch is checked out there.
- `reflog-kept`, `hook-at-checkout`, `branch-in-worktree`
  (`StartsAsAdded`): the HEAD reflog left as it was, `post-checkout` run
  by the checkout, and the branch made in the worktree taken.
- `wish-not-looked-for`, `wish-removed-unread`, `listing-leaves-wish`
  (`NoWishLost`): a run that doesn't look again once it lets go, one that
  removes whatever wish is there, and a listing's run that carries out no
  wish made while it swept.
- `cut-short-kept`, `locked-take-left` (`NothingLeft`): a sweep that keeps
  one whatever its mark says, and `undo_creation` with no branch for a
  worktree locked as TAKING.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new step of a take goes between the steps it comes
between in `take_ready_for`; a new way to remove one goes in `RunSweeps`
or `PruneSweeps`. To prove a new rule can fail, add a `Break` value that
breaks the code it guards the way a bug would, a
`WorktreeMadeAhead.<variant>.cfg` with `\* expect: Rule` at the smallest
bounds that show it, and keep it. To fix a finding, follow
`.claude/skills/fix-a-finding`.

Once the model describes the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `c1616b6`.
