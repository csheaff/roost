---
name: verify-task-on-host
description: >
  Model-check how the host helper finishes a task (retire, merge, discard,
  forget) against what Roost promises about your work: it deletes work only
  when you discard a task, takes only what is the task's own, and loses no
  more than a discard told you. Use when a change touches retire, discard,
  forget, remove_worktrees, remove_agent_worktrees, agent_work, delete_branch,
  safe_to_delete, put_back_removed, require_not_removing, holding_worktree,
  integrating, the registry lock, or the order of their steps in
  scripts/roost_remote.py; when "A task on its host" in docs/state-machines.md
  changes; or when asked to verify finishing a task. Not for creation, the
  agent's status or Emacs's views.
---

# Verify a task on its host

`test/formal/task_on_host/TaskOnHost.tla` is a TLA+ model of how the helper
finishes a task. TLC tries every order of its steps, within small bounds:
two requests for the same task at once (a retry beside the original, which
goes on once Emacs stops waiting), a request killed between any two steps,
the agent working until `stop` closes its pane while its record says it's
idle, others working in the repository's `.claude/worktrees`, in the
worktree its agent made too, and another worktree made at its path as
Roost removes it.
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

## Run it

```
python3 test/formal/check.py task_on_host
```

About 70 s, eleven runs. `TaskOnHost.cfg` must pass. Each
`TaskOnHost.<variant>.cfg` breaks one guard, through the `Break` constant,
and must fail on the rule its first line names: that proves each rule can
still fail. `make formal` runs every model. TLC and Java come from mise.

The last line says `all models as expected`, or names each run that
wasn't, with TLC's output. Read every result with the pstack `/statechart`
skill: a violation as its shortest path in plain words, a pass as a chart
of how a task moves between states.

## Does your change touch it?

Each step of the model names the code it stands for. Compare your diff with
this table. A change to a function listed, or to the order in which `retire`
or `discard` calls them, needs the model checked against it.

| Model | Code in scripts/roost_remote.py |
| --- | --- |
| `Start` | `rpc` (lock, `read_to_act_on`), `require_not_removing`, `forget`, `retire` up to `merging_in`, `discard` up to `stop`, `discard_losses`, `put_back_removed` |
| `GitMerge`, `AfterMerge` | `integrating`, `merge_task`, `retire` after the merge |
| `Checkpoint` | `safe_to_delete`, `retiringCommit` in `retire` |
| `Stop` | `stop`, the list of agent worktrees `retire` passes to `remove_worktrees`, with `seen` |
| `RemoveBegin` … `RemoveEnd` | `remove_worktrees`, `holding_worktree`, `remove_agent_worktrees`, `agent_worktree_seen`, `run_teardown` |
| `DeleteBranch`, `RemoveRecord` | `delete_branch`, `Store.remove` |
| `AsMade`, `Ahead`, `Losses` | `is_as_made`, `made_since`, `agent_work`, `discard_losses` |
| `Hook`, `AgentMakesX`, `AgentEntersX` | `update_hook`, `agent_worktree`, `ClaudeAgent.made_worktree` |
| `Crash` | what a reboot leaves: locks freed, `removing` mark kept |

Last confirmed against the code at commit `e910487`, with the change
to `remove_agent_worktrees` that came with this line. If `git log
e910487..HEAD -- scripts/roost_remote.py` shows changes to anything above,
check the model against them before you trust a pass, and move this commit
forward only once you have.

## Reading a failure

A trace is a list of steps. Tell it in the code's words: "retire asked;
`require_clean` passes; the agent writes a file; `stop`; ...". Then decide:

- **A bug** if each step is something the code allows at that moment.
  Check it in real Git before you report it: `test/crash_harness.py`'s
  `Box` makes a repository, a state folder and a task, and its `helper`
  sends one request as Emacs would. A teardown command (`teardown=`) runs
  in the window while the registry lock is let go, so it stands in well
  for something else acting then.
- **A modeling error** if a step does what the code can't: a step taken
  without a lock the code holds there, a check the code makes that the
  model skips, or two reads the code makes apart taken as one. Fix the
  model, and say in a comment which code it now follows.

Never weaken a rule, or the bounds, until it passes.

## When you change the code on purpose

- Mirror the change in the step the table names, and run again.
- A new guard: add a `Break` value that turns it off and a
  `TaskOnHost.<name>.cfg` that expects the rule it keeps, and see it fail.
- A guard taken out: run again. If the model still passes, say why the
  guard wasn't needed; if not, you have found what it was for.
- A new finishing action, or one that removes something new: give it its
  own kind in `Kinds` and its steps, and say which rule covers it.

## Bounds, and what is left out

Two units of work, two requests, one crash, one task, one agent worktree
folder (x) and one branch of yours. Left out, by design or as covered
elsewhere: creating a task (`make crash`'s `Create`), `update`, `pr` and its
shared hold of the worktree, `resume`, the forge (`merged_pull_request_head`),
a merge that conflicts or a hook that refuses it (each changes nothing),
submodules, links and moved worktrees (`check_worktree`), records from older
helpers, and a second task. `discard` counts its losses and stops the agent
in one step: an agent's write in the moment between them is lost untold, as
stopping first would stop an agent you didn't agree to stop. Likewise
`remove_agent_worktrees` reads what x holds, checks its stamp and removes
it a few Git calls apart, and the model takes those as one step, as it does
`require_clean` and the removal of the task's worktree: what is written
there in those milliseconds is lost.

## Known findings

None. `TaskOnHost.x-not-seen-again.cfg`, its `-discard` twin and
`TaskOnHost.x-stamp-first.cfg` keep what the model once found: retire and
discard removed the worktree its agent made with `--force --force` after
the teardown command, by its stamp but not by what it held, and checked
that stamp before reading it, with no lock between.
