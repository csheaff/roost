---
name: verify-task-on-host
description: >
  Model-check how the host helper finishes a task (retire, merge, discard,
  forget) against what Roost promises about your work: it deletes work only
  when you discard a task, takes only what is the task's own, and loses no
  more than a discard told you. Use when a change touches retire, discard,
  forget, retarget, remove_worktrees, remove_agent_worktrees, agent_work,
  delete_branch, safe_to_delete, branches_going, discard_losses,
  put_back_removed, require_not_removing, holding_worktree, integrating,
  conversation_to_fork, propose_task, require_offers_named, make_worktree,
  cut_short, unlock_unmade, what `stop` or `resume` is refused for or
  leaves, the registry lock, or the order of their steps in
  scripts/roost_remote.py;
  when "A task on its host" or "The runner's stages" in
  docs/state-machines.md changes; or when asked to verify finishing a task,
  or a task whose worktree its runner makes. Not for the rest of creation
  (the worktree made ahead is verify-worktree-made-ahead), the agent's
  status or Emacs's views.
---

# Verify a task on its host

`test/formal/task_on_host/TaskOnHost.tla` is a TLA+ model of how the helper
finishes a task. TLC tries every order of its steps, within small bounds:
two requests for the same task at once (a retry beside the original, which
goes on once Emacs stops waiting), a request killed between any two steps,
the agent working until `stop` closes its pane while its record says it's
idle, others working in the repository's `.claude/worktrees`, in the
worktree its agent made too, another worktree made at its path as
Roost removes it, and you stopping the task and resuming it, each a request
of its own, as Emacs stops one before it retires an agent with work in the
background or forgets one still running. Where a config says so, also: you change the branch the
task merges into (`B`), the task is a fork that began at a commit only its
source's branch has, a fork is made of it, its agent offers a task,
before you are asked or while you read the question, and the task begins
with no worktree, which its runner makes in its terminal, where Git may be
cut short making it and someone may write in what that left.
`make crash` kills one request at each step; this model reaches what that
doesn't: interleavings, and the moments between a read and the act on it.

## The rules

- **KeptButByDiscard.** Retire, merge, forget, a retry or a crash never
  take a file or a commit from every folder and branch. Harm: the agent's
  work is gone and nothing says so.
- **OnlyItsOwn.** Finishing never removes your branch or a worktree at the
  agent's path that its agent didn't make (one it only went to, or one made
  there since). Harm: Roost deletes someone else's work.
- **DiscardTold.** A discard takes no more commits, files or agent
  worktrees than its dry run told you. Harm: you typed the name for less
  than you lost.
- **ForkWhole.** A fork starts from its source's worktree as it stood,
  never from one Git was removing. Harm: the fork begins with half its
  source's files deleted, as changes of its own.
- **OffersTold.** The offers that go with a task are those its question
  named. Harm: a task its agent offered is gone before you saw it.
- **StartsWhole.** A task's record says its worktree is made only of one
  Git finished. Harm: an agent starts in half a checkout, takes the files
  Git hadn't written for deleted, and commits that.
- **MadeAlone.** Nothing finishes a task while its run makes its worktree.
  Harm: a discard counts, or removes, a folder Git is still writing.
- **StopLeavesNone.** A task stopped as its run made its worktree has
  none, and resumes. Harm: a task you only stopped can't be resumed, and
  its discard counts Git's own files as yours. Broken now: see Known
  findings.

## Run it

```
python3 test/formal/check.py task_on_host
```

About two minutes, thirty-three runs. Five must pass: `TaskOnHost.cfg`, and the
model again at other bounds, as the runner takes one passing config per
model and all of it at once takes too long. `TaskOnHostRetarget.cfg` has a
retarget and a fork's start, `TaskOnHostRetargetWork.cfg` those with work
done meanwhile, `TaskOnHostForkOffer.cfg` a fork made of the task and an
offer, and `TaskOnHostUnmade.cfg` a task whose worktree its runner has yet
to make. Each `TaskOnHost.<variant>.cfg` breaks one guard, through the `Break`
constant, and must fail on the rule its first line names: that proves each
rule can still fail. A `TaskOnHost.finding-<what>.cfg` is the code as it
is, with a timing the passing configs leave out, and fails until its
finding is fixed; there is one now, under Known findings. `make formal`
runs every model. TLC and Java come from mise.

The last line says `all models as expected`, or names each run that
wasn't, with TLC's output. Read every result with the pstack `/statechart`
skill: a violation as its shortest path in plain words, a pass as a chart
of how a task moves between states.

## Does your change touch it?

```
python3 test/formal/task_on_host/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Each step of the model names the code it stands
for. Compare your diff with this table. A change to a function listed, or
to the order in which `retire` or `discard` calls them, needs the model
checked against it. `rpc`, `answer`, `make_task`, `runner`, `list_tasks`
and `update_hook` are other sections' too: a change to them that touches
none of what this table names is theirs.

| Model | Code in scripts/roost_remote.py |
| --- | --- |
| `Ask` | what Emacs read before it asked, and the request carries: `expect`, `told`, and `offers`, the offers its question named (`roost--offers-named` in roost.el), which `TASK_ACTIONS` hands each action |
| `Start` | `rpc`, `answer` (lock, `read_to_act_on`), `require_not_removing`, `forget` (with `untrash`), `retire` up to `merging_in`, its `cut_short` refusal, `integration_branch`, `discard` up to `stop`, `discard_losses`, `put_back_removed`, `require_offers_named` in each |
| `GitMerge`, `AfterMerge`, `MergeFailed` | `integrating`, `merge_task`, `retire` after the merge, `require_offers_named` again among its checks |
| `Checkpoint` | `safe_to_delete`, `branches_going`, `retiringCommit` in `retire` |
| `Stop` | `stop`, the list of agent worktrees `retire` passes to `remove_worktrees`, with `seen` |
| none: `test/formal/git_work` | `keep_before_removing`, `reflog_only`, `ignored_to_keep`, `prune_kept`, `drop_kept` (also in `discard`), `gone_head_log`, `kept_target`, `submodules_in`, `kept_locked`, `keep_found`, and `safe_to_delete` passing over `refs/roost/`, called in `retire` after `stop` for a missing worktree, else by `remove_worktrees` after the teardown command, without the registry lock |
| `RemoveBegin` … `RemoveEnd` | `remove_worktrees`, `holding_worktree`, `remove_agent_worktrees`, `agent_worktree_seen`, `run_teardown`, `trash_worktree`, `finish_trashed` (in `put_back_removed`), and `unlock_unmade` in `discard` just before |
| `DeleteBranch`, `RemoveRecord` | `delete_branch`, `Store.remove` |
| `AsMade`, `Ahead`, `Losses`, `Going` | `is_as_made`, `made_since`, `agent_work`, `discard_losses`, `branches_going` |
| `Hook`, `AgentMakesX`, `AgentEntersX` | `update_hook`, `agent_worktree`, `ClaudeAgent.made_worktree`, `worktree.baseRef` in `claude_hook_settings` |
| `YouRetarget` | `retarget`, and `rpc`'s `require_not_removing` before it |
| `SourceBegins`, `SourceEnds` | `discard` of the task this one was forked from: its count, its `removing` mark while its worktree goes, its `delete_branch` |
| `ForkBegins`, `ForkReads` | `conversation_to_fork` and the `snapshot` after it in `make_task` |
| `AgentOffers` | `propose_task`; what goes with the record is `task_offers` |
| `YouStop`, `YouResume` | `stop` and `resume` as requests of their own, and `rpc`'s `require_not_removing` before each; `roost-retire` and `roost-forget` in roost.el, which send `stop` first, after the question. `stop` ends a run making the worktree, and what the pane left running (`end_left_running`); `resume` takes a task whose record says its worktree is yet to be made (`unmade`), whatever is there |
| `RunHolds`, `RunLooks`, `RunGitDone`, `RunSaves` | `runner` up to its agent, and `make_worktree`: its shared hold (`holding_worktree`), the record read again, `initializing`, `git worktree add`, what it takes as made, `worktreeComplete` saved |
| `RunCutShort`, `Poll` | the host restarting as Git makes the worktree; `list_tasks` reading a task whose pane is gone as `crashed` |
| `SomeoneWrites` | a file written in what Git left, or in a worktree whose run ended before its record said it was made |
| `Crash` | what a reboot leaves: locks freed, `removing` mark kept |

The record's `status` is "active", "ready" or "stopped". "ready" stands for
whatever `require_finished` takes for an agent at rest, so also `permission`
at Codex's plan menu (`asks_about_plan`): the agent may work on while its
record says so, as after any turn, and retire checks its worktree again.
"active" is any status in `ACTIVE`, so also `background`, for which `x`
sends `stop` before `retire`. An agent that ended by itself, whose dead
pane `owned_pane` takes for the task's, stands as one stopped: it writes
and offers no more, and `forget` takes it. A run that ends before its
agent starts is told apart: its record reads "ready", for `failed`, or
stays "active" until a listing finds its pane gone (`Poll`).

Other requests write the record and take nothing from it or from Git:
`leave`, `tell`, `take-offer`, and the agent's `show_image` and
`show_widget` (`keep_shown`), each under the registry lock on the record
read then, so none brings back a record that has gone. `tell` pastes a
prompt, which is `YouPrompt`. They have no step here.

A conversation is a task in a repository Roost keeps (`conversation_repository`),
with a worktree and a branch there, and finishes as any task. `retarget`
refuses one, so the model's runs with no retarget are its runs.

Since then, the task's worktree goes into the state directory's trash by
a rename (`trash_worktree`) where it can, rather than by Git file by file,
and `empty_trash` deletes it later, once the record is gone.
`RemoveWorktree` and `WorktreeGoing` still take it as Git's removal, with
the worktree "partly" there between them; a rename is the same two steps
with nothing between, a subset of the runs checked, and Git's removal
stays as the fallback, so no step changed. What is in the trash holds
nothing to keep: it went there only after the checks that `RemoveWorktree`
stands for. How `empty_trash` deletes it, a folder it can't list made
writable first, is after the record has gone, and has no step either.

A task whose worktree its runner makes in its terminal (`make_worktree`)
starts with none, and has steps of its own since `da80047`, behind
"unmade" in `Also`, on in `TaskOnHostUnmade.cfg`. Its record says the
worktree is yet to be made (`made`), and its run (`agent` is "starting")
takes the worktree lock, shared, reads its record again, has Git make the
worktree, and says so in the record. `stop` ends the run, and Git removes
what it made. The host restarting leaves what Git made, locked as
`initializing` (`tw` is "half"), and someone may write there. What the
existing steps do with it:

- `retire` and `merge` refuse it at `Start`, saying so (`cut_short`).
  With no worktree at all they go on as for any task whose worktree has
  gone, which the model already had.
- `discard` counts what is there as in any worktree (`Losses`), and
  removes it by `RemoveWorktree`, where `unlock_unmade` is, after every
  refusal: a discard refused leaves it as it was.
- `forget` leaves it, as it leaves all of Git.
- `stop` is `YouStop`, and `resume` `YouResume`, which takes it whatever
  is there: its run makes the worktree, takes one Git finished and nothing
  else wrote in as made, and refuses anything else.
- All of them are refused as busy while the run holds the worktree
  (`Held`), which a fork never is: a task whose agent never ran has no
  conversation to fork.

`take_ready_for`, since `c082a3d`, writes the branch and the worktree of a
task whose record isn't saved yet, and trashes one it sets aside under an
ID no record has. No request finds that task, so no step here meets it:
it is creation, which `test/formal/worktree_made_ahead` has.

Last confirmed against the code at commit `c1616b6`, which is `SYNC` in
`covered.py`. Read against the model since `951ce59`, where it was
confirmed before: `stop` ending what its agent and shell left running
(`end_left_running`), `remove_worktrees` checking a worktree with
submodules again last before `--force`, and `discard` counting its losses
again after `stop`, each of which makes the code do what `Stop`,
`RemoveBegin` and `Start` already took it to do; `put_back_removed`
relinking a worktree Git forgot partway, which is `PutBack`; the trash and
what retire keeps, described above and below; `safe_to_delete` passing
over `refs/roost/`; and `make_worktree`, `cut_short`, `unlock_unmade` and
`resume` of a task yet to have its worktree, which brought the steps
above. Between `047486f` and `951ce59` nothing in the table changed. Since
`ec689c7`, the
commit before `047486f` that this was confirmed at, nothing in the table changed
but `owned_pane`, which takes a dead pane that names no process for the
task's; what came in was beside it: `x` sending `stop` before `retire`
(`roost-retire`), hence `YouStop` and `YouResume`, and the record's new
writers, named above. Before that, since `e910487`, it took in
`require_offers_named`, its calls in `retire`, `discard` and `forget`, the
`offers` that `TASK_ACTIONS` hands them, `retarget`, which moves the branch it merges
into and never where its branch was made (`startCommit`, which
`safe_to_delete` tells a task that never committed by, merged beside this
from "Git and the forge"), conversations, a fork's start and read, offers, `require_finished` at a
plan menu, and a branch that is going keeping no commit (`safe_to_delete`,
`discard_losses`, `branches_going`). If `covered.py` names a function
`changed`, or `git log c1616b6..HEAD -- scripts/roost_remote.py` shows a
new writer of the task's record, worktree or branch, check the model
against them before you trust a pass, and move `SYNC` forward only once
you have.

What retire keeps before it removes (`keep_before_removing`) has no step
here: it takes nothing, and what it keeps, commits only a reflog names and
ignored files, is what this model's units leave out. `test/formal/git_work`
has them: `GitWork.tla` is Git cut down to units with both, and
`GitToolRoost.cfg` is `retire` as it keeps them, `GitTool.roost-before.cfg`
as it didn't. Run it beside this one:

```
python3 test/formal/check.py git_work
```

A change to what `keep_before_removing` keeps, or to where `retire`
calls it, is checked there, and by `test/test_kept.py` and `make crash`'s
`RetireResetAway`.

## Reading a failure

A trace is a list of steps. Tell it in the code's words: "retire asked;
`require_clean` passes; the agent writes a file; `stop`; ...". Then decide:

- **A bug** if each step is something the code allows at that moment.
  Check it in real Git before you report it: `test/crash_harness.py`'s
  `Box` makes a repository, a state folder and a task, and its `helper`
  sends one request as Emacs would. A teardown command (`teardown=`) runs
  in the window while the registry lock is let go, so it stands in well
  for something else acting then, a request for another task among them.
- **A modeling error** if a step does what the code can't: a step taken
  without a lock the code holds there, a check the code makes that the
  model skips, or two reads the code makes apart taken as one. Fix the
  model, and say in a comment which code it now follows.

Never weaken a rule, or the bounds, until it passes.

## When you change the code on purpose

- Mirror the change in the step the table names, and run again.
- A new guard: add a `Break` value that turns it off and a
  `TaskOnHost.<name>.cfg` that expects the rule it keeps, and see it fail.
  Give it the smallest bounds that show it, and only the `Also` it needs.
- A guard taken out: run again. If the model still passes, say why the
  guard wasn't needed; if not, you have found what it was for.
- A new finishing action, or one that removes something new: give it its
  own kind in `Kinds` and its steps, and say which rule covers it.
- Something new that happens beside finishing, as `retarget` did: a step of
  its own behind a member of `Also`, on in a passing config that has room
  for it, so that `TaskOnHost.cfg` stays as fast as it is. A variant's
  bounds and `Also` should lie within a passing config's, which then shows
  that the guard, on, is what keeps the rule.

## Bounds, and what is left out

`TaskOnHost.cfg`: two units of work, two requests, one crash, one task, one
agent worktree folder (x) and one branch of yours, with others at work in x
and another worktree made there as Roost removes it. The other four have
nobody else in x. All five have you stop the task and resume it, as often
as you like. `TaskOnHostRetarget.cfg`: two requests and one crash, no
work but the commit a fork starts with, and one retarget, to `main`, your
branch or the branch of the agent's worktree. `TaskOnHostRetargetWork.cfg`:
the same with one unit of work, one request and one crash.
`TaskOnHostForkOffer.cfg`: two requests and one crash, no work, one fork
made of the task and one offer, made at any moment until the task is
stopped. `TaskOnHostUnmade.cfg`: a task that begins with no worktree, or
as any does, one unit of work, two requests, and two things killed, each a
request or the run as Git makes the worktree.

Checked once and in no config: `TaskOnHostUnmade.cfg` passes with a task
that may be a fork (15 million states), and with two units of work (17
million).

Left out, by design or as covered elsewhere: creating a task (`make crash`'s
`Create`) but for a fork's read of its source, `update`, `pr` and its
shared hold of the worktree, the forge (`merged_pull_request_head`),
a merge that conflicts or a hook that refuses it (each changes nothing),
submodules, links and moved worktrees (`check_worktree`), records from older
helpers, taking an offer (`take_offer`, in `make crash` and
`test/formal/emacs_and_hosts`), so that one offer, counted, stands for the
IDs a request names, and a second task but for the one this was
forked from: its branch, and its going, where its discard told you it
would lose nothing. One that told you of the commit, as when this task's
worktree was going by then, is left out: you chose. `discard` counts its
losses and stops the agent in one step: the code counts them again once
`stop` is done, and refuses then, the agent stopped, which is at least as
strong. Likewise
`remove_agent_worktrees` reads what x holds, checks its stamp and removes
it a few Git calls apart, and the model takes those as one step, as it does
`require_clean` and the removal of the task's worktree: what is written
there in those milliseconds is lost. `stop` ends the agent's writing in the
task's worktree: it closes the agent's and shell's panes, then ends what
they left running (`end_left_running`), by the one ownership rule that
"Finishing a task" in docs/state-machines.md and `left_running` state.
Only a process that rule doesn't reach, or yours outside the task, writes
into those milliseconds. When such a write stops Git partway, Git forgets the
worktree all the same: `remove_worktrees` makes it one again, on its
branch, with the files Git deleted put back (`relink_removed`), and keeps
its `removing` mark until it has, so that the next request's
`put_back_removed` does it: the model's `PutBack` of a removal cut short,
with what was written there kept, as changes. And what you delete by hand is yours:
a branch you delete with Git while a request counts on it for the task's
commits, as the agent's worktree's once its agent switched it to another.

Of a task whose run makes its worktree, left out:

- A probe of the worktree lock meeting the run's attempt at it. Every
  other hold of that lock, and every probe (`worktree_holder`), is taken
  under the registry lock; `make_worktree` takes its hold with none. The
  model has a probe as part of one step, so the two never meet. In the
  code they can, for the microseconds a probe lasts: the run is refused,
  and ends `failed`, to be resumed. "Known and not fixed" in
  docs/state-machines.md has it.
- A run outliving its `stop`. `stop` ends it at once here, so the record
  check `make_worktree` makes under the registry lock, which leaves a task
  finished before it started alone, has no variant.
- Where `unlock_unmade` sits, which is a matter of words: unlocked by a
  discard that is then refused, what Git left would read as the task's
  uncommitted files (`require_clean`), not as cut short. The model has the
  unlock as part of the removal, and no rule for what a refusal says.
- A write in the worktree as Git makes it, by anyone but Git: it stays in
  the task's worktree, as a file there would in any.
- A removal cut short of what Git was cut short making, beyond `PutBack`,
  which takes it for a worktree there, as `restore_deleted` leaves it.

## Known findings

One open.

- **LC-11**, `TaskOnHost.finding-stop-kills-clean-up.cfg`, which fails on
  `StopLeavesNone`. `stop` on a task whose run is making its worktree
  hangs Git up, and Git removes what it made. But `end_left_running` kills
  what the pane left running a second after it asks, Git among it. With a
  large checkout Git is still removing then, its own record of the
  worktree first: part of the folder stays, which Git no longer lists.
  Resuming the task then refuses it ("stopped partway"), `retire` can't
  read it, the listing doesn't call it cut short, and the discard preview
  counts every file left as uncommitted. Replayed on the real helper with
  120,000 files: `stop` took 1.3 seconds, 70,936 files stayed, and the
  preview said `changes: 70936`. Nothing of yours is lost: with the timing
  on, `"slow clean-up"` in `Also`, every other rule holds. Once it is
  fixed, that switch goes on in `TaskOnHostUnmade.cfg`.

The variants keep what the model found before, each a fix undone:

- `TaskOnHost.x-not-seen-again.cfg`, its `-discard` twin and
  `TaskOnHost.x-stamp-first.cfg`: retire and discard removed the worktree
  its agent made with `--force --force` after the teardown command, by its
  stamp but not by what it held, and checked that stamp before reading it,
  with no lock between.
- `TaskOnHost.proof-goes.cfg` and its `-fork` twin: retire took the branch
  of that worktree for one that kept the task's commits, as when `B` named
  it, or for a fork that never committed, and then removed it with the task.
- `TaskOnHost.going-counts.cfg` and its `-discard` twin: a fork that never
  committed and the task it was made from, finished at once, each counted
  on the other's branch for the commit only those two had, and both went.
- `TaskOnHost.fork-not-held.cfg`: a fork read its source's worktree with no
  hold on it, as a removal began.
- `TaskOnHost.offers-not-named.cfg` and `TaskOnHost.offers-named-once.cfg`:
  an offer made once you were asked went with the task, unnamed. You were
  asked what a discard loses, with the offers that go; its agent, still at
  work, offered a task; you answered; the offer went with the record. Now
  the request says which offers its question named, and its host refuses
  while the record holds another (`require_offers_named`), under the
  registry lock it keeps until the agent is stopped, after which
  `propose_task` refuses. A merge lets that lock go while Git merges, so it
  asks again after: the second variant leaves that out. The timing is
  `"offer once asked"` in `Also`, on in `TaskOnHostForkOffer.cfg`.

Two more break a guard no finding came from, which the rules lean on once
you can resume a task: `TaskOnHost.resume-while-removing.cfg` and its
`-discard` twin have `resume` start the agent again while a request removes
the worktree, as `require_not_removing` refuses. It then offers a task that
goes with the record, or writes a file a discard never counted.

And five break the guards of a worktree its run makes:

- `TaskOnHost.cut-short-remade.cfg`, `TaskOnHost.cut-short-retired.cfg`
  and `TaskOnHost.cut-short-not-counted.cfg`: what Git was cut short
  making is taken for Git's alone, and forced away by the next run, forced
  away by a retire, or left uncounted by a discard, as #317 cleared it
  before review. A file someone wrote there since goes.
- `TaskOnHost.cut-short-taken-as-made.cfg`: a run takes whatever folder is
  at the worktree's path as made, and the agent starts in half a checkout.
- `TaskOnHost.made-with-no-hold.cfg`: the run takes no hold of the
  worktree it makes. No rule about your work needs that hold, as `stop`
  ends the run before anything is removed: it is what refuses a discard,
  and its preview, while Git still writes there.
