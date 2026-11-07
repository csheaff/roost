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
| 1 | LC-1 | S1 | Asking again after a cut-short removal deletes the primary checkout's branch | [Agent worktrees](#agent-worktrees) | Fixed, [#221](https://github.com/csheaff/roost/issues/221): `test_a_removal_of_an_agents_worktree_cut_short_costs_the_primary_checkout_nothing`, `test_a_folder_that_is_no_worktree_says_nothing_of_the_primary_checkout` |
| 2 | LC-2 | S1 | Finishing a task takes a branch or worktree its agent only used | [Agent worktrees](#agent-worktrees) | Fixed, [#221](https://github.com/csheaff/roost/issues/221): `test_finishing_a_task_leaves_a_branch_its_agent_only_switched_to`, `test_finishing_a_task_leaves_a_worktree_its_agent_only_went_to` |
| 3 | VIEWS-1 | S1 | "Nothing would be lost" doesn't hold for what is written before you answer | [Asking before acting](#asking-before-acting) | Fixed, [#222](https://github.com/csheaff/roost/issues/222), `test_a_file_written_since_you_were_told_stops_a_discard` |
| 4 | REQUESTS-8 | S2 | On this machine, a merge that outlasts the timeout is killed with its Git and hooks, leaving your checkout half-merged | [Host request](#host-request) | Fixed, [#223](https://github.com/csheaff/roost/issues/223): `test_what_changes_things_goes_on_once_emacs_stops_waiting` |
| 5 | LC-3 | S2 | What a push or a checkout leaves running holds a task's lock, and refuses every way of finishing it | [Worktree lock](#worktree-lock) | Fixed, [#223](https://github.com/csheaff/roost/issues/223): `test_what_a_push_leaves_running_keeps_no_hold_on_its_task`, `test_what_a_checkout_leaves_running_holds_up_no_creation_cut_short` |
| 6 | REQUESTS-1 | S2 | A refresh that can't start leaves its host unasked until Emacs restarts | [Host refresh](#host-refresh) | Fixed, `roost-a-refresh-that-could-not-start-leaves-its-host-asked-again` |
| 7 | REQUESTS-2 | S2 | An install cut short leaves a broken helper under its real name | [Helper copy](#helper-copy) | Fixed, `roost-an-install-cut-short-leaves-what-was-there` |
| 8 | STATUS-1 | S2 | A Claude task stopped before anything was said in it can never resume | [The runner's stages](#the-runners-stages) | Fixed, `test_a_task_stopped_before_anything_was_said_in_it_starts_again` |
| 9 | VIEWS-2 | S2 | A retry with an edited draft says it created a task it didn't, and drops the edit | [The creation ID](#the-creation-id) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `roost-sweep-late-a-retry-with-another-prompt-keeps-the-draft` |
| 10 | VIEWS-9, FORGE-3 | S2 | A pull request draft says it opened one it only pushed to, and `P` can't open one after a closed one | [Pushing and opening](#pushing-and-opening) | Fixed, [#227](https://github.com/csheaff/roost/issues/227): `roost-pr-draft-says-what-became-of-it-when-the-task-has-one-by-then`, `roost-pr-drafts-another-once-the-one-it-has-takes-no-more-commits`, `test_p_opens_another_after_a_closed_pull_request` |
| 11 | REQUESTS-3, VIEWS-8 | S2 | Two Emacs sessions overwrite each other's review notes | [Remembered files](#remembered-files) | Fixed, `roost-a-note-from-another-emacs-stays-as-you-write-yours` |
| 12 | STATUS-2 | S2 | Roost takes a pane changed by hand for its agent, or for gone | [A run and its pane](#a-run-and-its-pane) | Fixed, `test_a_pane_you_move_is_still_the_agents`, `test_what_tmux_starts_in_the_agents_pane_is_not_the_agent` |
| 13 | LC-4, STATUS-3 | S3 | A merge's hooks hold the registry lock, so other agents' events are lost and they stay `running` | [Registry lock](#registry-lock) | Fixed, [#223](https://github.com/csheaff/roost/issues/223): `test_every_agent_and_poll_goes_on_while_a_merges_hook_runs`, `test_every_agent_and_poll_goes_on_while_an_updates_hook_runs` |
| 14 | FORGE-1 | S3 | A pull request merged with a commit made on the forge reads as not merged, and `m` forks `main` from `origin` | [Landed](#landed) | Fixed, [#227](https://github.com/csheaff/roost/issues/227): `test_a_pull_request_merged_with_a_commit_made_on_the_forge_is_merged`, `test_commits_after_a_merge_never_count_as_merged` |
| 15 | STATUS-4 | S3 | Another tool's event ends a request that still waits, so `send` could answer a menu | [Agent status](#agent-status) | Fixed, `test_only_the_agent_that_asked_says_its_request_is_over` |
| 16 | VIEWS-5, LC-5 | S3 | A prompt goes twice when its reply was lost | [The prompt draft](#the-prompt-draft) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `test_a_prompt_queued_behind_the_first_is_pasted_once` |
| 17 | VIEWS-7 | S3 | Merging takes commits made after it asked | [Asking before acting](#asking-before-acting) | Fixed, [#222](https://github.com/csheaff/roost/issues/222), `test_a_commit_made_since_you_were_asked_stops_a_merge` |
| 18 | FORGE-2 | S3 | An agent's pull request goes unfollowed after `git pull --rebase` or a fast-forward | [A task's pull request](#a-tasks-pull-request) | Fixed, [#227](https://github.com/csheaff/roost/issues/227): `test_an_agents_pull_request_after_git_pull_rebase_is_followed`, `test_an_agents_pull_request_of_work_fast_forwarded_in_is_followed`, `test_commits_an_update_brought_in_are_still_not_the_tasks` |
| 19 | FORGE-4, REQUESTS-5 | S3 | A change a poll saw can go unmeasured until something else asks | [Task measurement](#task-measurement) | Fixed, `roost-a-measurement-dropped-as-stale-is-asked-for-again` |
| 20 | FORGE-5 | S3 | A commit made on the forge holds back all an open pull request says | [What the forge last said](#what-the-forge-last-said) | Fixed, [#227](https://github.com/csheaff/roost/issues/227): `test_an_open_pull_request_with_a_commit_made_on_the_forge_has_the_branchs_commits` |
| 21 | STATUS-6 | S3 | An MCP server's question reads as work | [Agent status](#agent-status) | Fixed, `test_a_question_of_an_mcp_server_waits_on_you` |
| 22 | FORGE-6 | S3 | A task held at a startup prompt waits, and no notification says so | [The word](#the-word) | Fixed, `roost-an-agent-held-at-a-startup-prompt-notifies-once` |
| 23 | VIEWS-3 | S3 | Undo in the new task draft changes the wrong text | [The new task draft](#the-new-task-draft) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `roost-sweep-late-undo-in-a-draft-follows-its-fields` |
| 24 | STATUS-5 | S3 | As tmux goes, a Claude task reads `exited`, not `crashed` | [Who wins](#who-wins-hooks-reports-poll-runner) | Fixed, `test_a_claude_that_says_goodbye_as_tmux_goes_crashed` |
| 25 | STATUS-7 | S3 | A report landing after the runner's end turns `exited` into `crashed` | [Agent status](#agent-status) | Fixed, `test_news_after_the_runners_end_leaves_the_agent_ended` |
| 26 | FORGE-8 | S3 | A failed review query takes back what a pull request waits on you for, then notifies again | [What the forge last said](#what-the-forge-last-said) | Fixed, `roost-a-failed-review-query-takes-back-nothing-that-waits` |
| 27 | FORGE-9, REQUESTS-4 | S3 | Conflicts there when Roost first saw a task notify after every restart | [News of a turn](#news-of-a-turn) | Fixed, `roost-a-conflict-from-before-a-restart-is-no-news` |
| 28 | VIEWS-4 | S3 | A prompt draft reads its task as it was when it opened | [The prompt draft](#the-prompt-draft) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `roost-sweep-late-a-prompt-draft-asks-as-its-task-is-now` |
| 29 | VIEWS-6 | S3 | A note taken out of a draft is cleared unsent | [A review note](#a-review-note) | Fixed, [#229](https://github.com/csheaff/roost/issues/229), `roost-sweep-late-a-note-taken-out-of-a-draft-stays` |
| 30 | VIEWS-10 | S3 | A note edited as its draft goes loses the edit | [A review note](#a-review-note) | Fixed, [#229](https://github.com/csheaff/roost/issues/229), `roost-sweep-late-a-note-edited-as-its-draft-goes-stays` |
| 31 | REQUESTS-6 | S3 | Two Emacs sessions overwrite each other's hosts and projects | [Remembered files](#remembered-files) | Fixed, `roost-a-host-remembered-in-another-emacs-stays-as-you-use-yours` |
| 32 | LC-6 | S4 | Discarding a task whose repository is gone deletes its worktree and says it failed | [Finishing a task](#finishing-a-task) | Fixed, [#221](https://github.com/csheaff/roost/issues/221): `test_discard_a_task_whose_repository_is_gone` |
| 33 | VIEWS-11 | S4 | An error after a good reply leaves a draft busy | [The new task draft](#the-new-task-draft) | Fixed, [#226](https://github.com/csheaff/roost/issues/226), `roost-sweep-late-an-org-entry-that-cant-take-the-link-closes-the-draft` |
| 34 | VIEWS-12 | S4 | A resumed task covers what you opened from a question | [Resuming](#resuming) | Fixed, [#229](https://github.com/csheaff/roost/issues/229), `roost-sweep-late-a-task-resumed-leaves-what-you-opened-from-a-question` |
| 35 | VIEWS-13 | S4 | An open held for a question connects to a session since ended | [Opening a task](#opening-a-task) | Fixed, [#229](https://github.com/csheaff/roost/issues/229), `roost-sweep-late-a-task-stopped-while-you-answer-opens-no-session` |
| 36 | FORGE-10 | S4 | A task whose worktree went keeps waiting on conflicts last measured | [Task measurement](#task-measurement) | Fixed, `test_a_worktree_gone_says_it_no_longer_conflicts` |
| 37 | FORGE-11, REQUESTS-7 | S4 | Two Emacs undo each other's turn for a stopped task, on every poll | [Verdict and turn](#verdict-and-turn) | Fixed, `roost-two-emacs-settle-on-a-stopped-tasks-turn` |
| 38 | FORGE-12 | S4 | What `P` pushed counts as unpushed until GitHub is next asked | [Pushing and opening](#pushing-and-opening) | Fixed, [#227](https://github.com/csheaff/roost/issues/227): `test_what_p_pushed_is_no_longer_unpushed` |
| 39 | FORGE-7 | S4 | A failed task you've seen keeps its colour, though the manual says otherwise | [The word](#the-word) | Fixed, in the manual |
| 40 | STATUS-8 | S4 | `/clear` reads `interrupted` for a relayed Claude | [Agent status](#agent-status) | Fixed, `test_clearing_a_conversation_stops_no_turn` |
| 41 | STATUS-9 | S4 | A dialog as a task resumes shows the last run's request | [A task's request](#a-tasks-request) | Fixed, `test_a_dialog_as_a_task_resumes_says_what_it_asks` |

From the hunt of 2026-11-05, refusals that didn't name a half-done merge and tmux
calls with no timeout are fixed ([#223](https://github.com/csheaff/roost/issues/223)). Also open from it, and taken up under
these issues: text lost as a
draft closes, and a click on another project ignored ([#226](https://github.com/csheaff/roost/issues/226)). A pull request that
branch rules block reading `to merge` is fixed under [#227](https://github.com/csheaff/roost/issues/227), by
`roost-a-pull-request-github-holds-up-isnt-to-merge`. The rest are under
[Known and not fixed](#known-and-not-fixed).

## A task on its host

The helper's records and what it does to Git, from a task being asked for to its
record being gone.

### Task record

Kind: explicit (`status`) over implicit (the file `tasks/<id>.json`, `removing`,
`integrating`, `retiringCommit`). Lives in: `Store`, `tasks/<id>.json`, `.settings`, `.removing`,
`attachments/<id>`.

[Agent status](#agent-status) has the statuses. For the lifecycle they fall in three:

| State | Meaning | How you can tell |
| --- | --- | --- |
| None | no record | no file; a note in `creating/` if under way |
| Live | a running task | status in `ACTIVE`, or `ready` with a live pane |
| Ended | agent gone, record stays | status in `ENDED`, or dead pane |
| Failed creation | `abandon` kept its worktree, as something was written there | status `failed`, its error says so, no `createId` |
| Merging | Git merges or updates it, without the registry lock | `integrating` set, worktree lock exclusive |
| Merge cut short | a helper died in it | `integrating` set, worktree lock free; see [The merge](#the-merge) |
| Finishing | passed its checks and checkpointed | `retiringCommit` set |
| Removing | worktree going | `removing` set, worktree lock exclusive |
| Removal cut short | a helper died in it | `removing` set, worktree lock free |
| Gone | record deleted | reply says `retired`, `discarded` or `forgotten`; those are never saved |
| Damaged | not JSON, wrong ID, or a field of the wrong type | `Store.all` or `listable` leaves it out |

Invariants:
- I1. A record names at most one run (`runId`), and only that run's hooks and
  runner change it (`update_hook`, `runner`, `program_status_recorder`).
- I2. No writer saves after `Store.remove`: every save follows a read under the
  same hold of the lock, or re-reads. Holds; checked site by site.
- I3. `stopped` and `retired` are closed to hooks, which is what makes it safe
  to release the lock during removal. `stop` runs before `remove_worktrees` in
  both finishing paths.
- I4. Once `removing` is set, only finishing actions run; while its lock is
  held, none (`require_not_removing`). Looking (`seen`, `turn`, `inspect`) is
  always allowed.
- I5. `retiringCommit` is a checkpoint only: nothing clears it. A task resumed
  after a failed retire keeps it. Read in one place, which is safe only because
  it matters when the branch is gone.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| None | create | Git made the worktree | Live | save, spawn | `make_task` |
| None | post-checkout hook failed | files there | Failed creation | save, `abandon` | `make_task` |
| None | spawn failed | files there | Failed creation | `abandon` | `make_task` |
| None | spawn failed | clean | None | `abandon`, `Store.remove` | `make_task` |
| None | cut short | files there | Failed creation | `undo_creation` | `settle_creation` |
| Live | stop | | Ended | agent's pane and shell closed, status `stopped` | `stop` |
| Live | agent exits | | Ended | `exited` or `failed` | `runner` |
| Live | pane missing | | Ended | `crashed`, with `statusBeforeCrash` | `list_tasks` |
| Ended | resume | worktree there | Live | new `runId` | `resume`, `spawn` |
| Ended (`crashed`) | pane found | | Live | status restored | `list_tasks` |
| Live, Ended | retire, merge | checks pass | Finishing | save `retiringCommit` | `retire` |
| Finishing | | | Ended, then Removing | `stop`, then marker | `retire`, `remove_worktrees` |
| Removing | done | | Gone | delete branch, `Store.remove` | `retire`, `discard` |
| Removing | refused | | Ended | marker cleared; agent stays stopped | `remove_worktrees` |
| Removing | helper dies | | Removal cut short | marker stays | |
| Removal cut short | retire, merge, discard | | Removing | `put_back_removed` first | `retire`, `discard` |
| any but Removing | forget | no live pane | Gone | window closed; Git left | `forget` |
| Ended | retire, merge | a step after the checkpoint fails | Finishing, still stopped | `retiringCommit` stays | `retire` |

Illegal or refused: see [Action by state](#action-by-state).
Assumed, not stated: a record's `worktree` and `repo` never change; `Store.read`
takes older records' fields as they come.
Open: none.

### Creation

Kind: implicit. Lives in: `creating/<id>.json` (the note), its flock,
`creating/<createId>.lock`, `createId` in the record, Git's `locked` file.
Makes a request Emacs gave up on safe to ask again, and clears up what a dead
one left.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Asked | request holds the ID lock | flock on `<createId>.lock` |
| Preparing | resolving base, no note yet | nothing on disk but the ID lock |
| Noted | note in place, locked | note exists, flock held by the helper |
| Made | record saved, spawned | note gone, record has `createId` |
| Cut short | note unlocked, no record | `settle_creation` gets the flock and finds no record |
| Saved, cut short | note unlocked, record there | the note goes; the record lists as `crashed` |
| Failed | refused | no note; the ID lock's file stays, empty |

Invariants:
- I1. One `createId`, at most one task. Holds, and fuzzed: two helpers at once,
  and one killed then asked again.
- I2. A note's lock is held by the helper alone, so nothing a hook leaves running
  can keep it. `create` doesn't detach: Emacs's kill at eleven minutes takes
  helper and Git together, and `settle_creation` clears up. A helper killed alone
  leaves Git writing a worktree a settler may remove under it, which nothing does
  but `make crash`'s `orphan` and `racing`.
- I3. The note is unlinked under its own lock, so a settler that gets the lock
  and finds the path gone knows the creation finished.
- I4. A worktree Git was stopped making holds only Git's checkout, so may be
  forced. Recognized by the text of Git's lock, in English (`initializing`).
  Git writes that text through gettext, so a translated Git may write
  another; unverified here, as this Mac's Git has no translations. The
  fall-back is a failed row, which `x` clears.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| | create | ID given | Asked | flock waits on any other with this ID | `asking_for` |
| Asked | | a note has this ID | waits | `settle_creation(wait=True)` | `made_for` |
| Asked | | a record has this ID | Made | returns that task | `made_for` |
| Asked | | neither | Preparing | | `make_task` |
| Preparing | | | Noted | note locked before it is in place | `noting_creation` |
| Noted | Git and spawn done | | Made | note unlinked under its lock | `noting_creation` |
| Noted | Git refused | nothing there | Failed | branch deleted | `make_task` |
| Noted | helper and Git die | | Cut short | | |
| Cut short | list, or same ID | Git stopped it | gone | force-remove, unregister, delete branch | `undo_creation` |
| Cut short | list, or same ID | else | gone, or Failed creation | `abandon` | `undo_creation` |
| Saved, cut short | list, or same ID | | Made, listed `crashed` | note unlinked | `settle_creation` |

Illegal or refused: a malformed `createId`. [The creation ID](#the-creation-id)
has Emacs's side: what a retry with an edited draft gets.
Left over, harmless: `<createId>.lock` after a failure, `.roost-*` temporary
files from a kill before the rename.
Open: none.

### Registry lock

Kind: implicit. Lives in: `registry.lock`, `Store.locked`, `Store.released`,
`Store.lock`.
Decides which interleavings exist. Every read-then-write of a record happens
inside it.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Free | nobody holds it | flock succeeds |
| Held | one process acts on records | hooks, polls and actions queue, with no timeout |
| Released under `locked` | the holder gave it up for slow work, and will take it back | `self.lock` set, flock not held |

Invariants:
- I1. "Hold it only for short record and tmux operations, never for slow Git
  work" (`Store.locked`). Holds for Git's merges and their hooks (`integrating`),
  and for tmux, whose calls end after `TMUX_SECONDS`, and a poll's after
  `INVENTORY_SECONDS`, within the three seconds some agents give a hook. `require_clean`,
  `submodule_work` and `overwritten_ignored` still run inside it: Git reading,
  with no hooks.
- I2. After `released`, records read before may have changed: re-read before
  saving. Holds at every site (below).
- I3. Nothing nests `locked` in one process: flock on a second descriptor would
  deadlock. Holds; `abandon` is called under it, `undo_creation` takes it.
- I4. No lock order cycle: registry is taken while holding a note or the
  `create` ID lock, never the reverse with a blocking wait; the worktree lock
  and the note, and the repository's merge lock, are only tried without blocking
  while the registry lock is held. Holds.

| Site of `released` | Slow work | Guard that keeps the task still | After it |
| --- | --- | --- | --- |
| `rpc` `pr` | push, forge | worktree lock shared | re-reads, then saves |
| `prepare_look` | snapshot | worktree lock shared | `record_look` re-reads, compares `looked` |
| `attach` | decoding, writing | worktree lock shared | saves nothing |
| `remove_worktrees` | teardown, removal | worktree lock exclusive, `removing` marker, status `stopped` | re-reads, clears only its own marker |
| `integrating` | Git's merge and its hooks | worktree lock exclusive, `integrating` marker, for a merge the repository's lock | re-reads, clears only its own marker; `retire` asks again whether the agent is at work |

Steps outside any lock, by design: `merged_pull_request_head` (only its answer
is kept, and `retire` compares it to the branch's tip read under the lock);
`settle_creations` before `list`; `check_pull_requests` and `add_git_stats`
after it; everything in `make_task` up to its one `locked` block.

Illegal or refused: nothing refuses; everything queues. No holder waits on Git's
hooks or a stopped tmux server any more: a server under SIGSTOP costs each `list`
`INVENTORY_SECONDS`, and it then keeps the statuses it had.

What matters isn't only whether it's held, but for how long, as hooks wait on
it with a clock running:

Invariants:

Open: none.

### Worktree lock

Kind: implicit. Lives in: `tasks/<id>.removing` and its flock.
Says what holds a task's worktree while the registry lock is released.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Free | | both probes of `worktree_holder` succeed |
| Work | shared: `pr`, a look, an attachment | SH free, EX refused: `worktree_holder` says "work" |
| Removal | exclusive: `remove_worktrees`, or Git's merge (`integrating`) | SH refused: "removal"; the record says which |

Invariants:
- I1. Taken and probed only under the registry lock, so `worktree_holder`'s own
  brief hold never collides with a taker. Holds at every call.
- I2. Held by the request alone, and nothing it starts (`holding_worktree`), so what
  Git or a hook leaves running keeps no hold. A request that takes it for long
  outlives Emacs's wait ([Request lifetime](#request-lifetime)), which is why it
  can. A helper killed alone, which nothing but `make crash` does, frees it with Git
  still at work.
- I3. Never held across a finishing action by anyone else. Holds: `FINISHING`
  all refuse on any holder, `forget` too.
- I4. The file goes only with the record (`Store.remove`), after the lock is
  dropped; no one can hold the old inode then, as nothing else may start.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| Free | `pr`, look, attach | | Work | shared | `holding_worktree` |
| Work | same | | Work | shared again | `holding_worktree` |
| Free | removal | | Removal | exclusive | `remove_worktrees` |
| Free | merge, update | | Removal | exclusive | `integrating` |
| Work | removal | | refused | "busy", before anything changes | `require_not_removing` |
| Removal | anything but looking | | refused | "still removing", "still merging", "still updating" | `require_not_removing` |
| Work, Removal | the request ends | | Free | | kernel |

Illegal or refused: a helper killed in teardown, by a reboot's kin, leaves the lock
free and the command running in its own session: a retry runs it again beside
itself. Harmless so far as seen.
Open: none.

### Request lifetime

Kind: implicit. Lives in: Emacs's timer in `roost--expire-request`, process
groups, `detach`, `DETACHED`.
What becomes of a request once Emacs stops waiting. Everything about retries
turns on this.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Waiting | Emacs holds the process | `roost--requests` has it |
| Given up, local | `delete-process` sent SIGKILL to the helper's process group | what changes things goes on, in a session of its own (`detach`); only the parent waiting for it dies. What looks, `create` and `send` die with what they started |
| Given up, SSH | `delete-process` killed the ssh client; sshd signals nothing to a session with no tty | helper and all its children go on; the reply goes nowhere, and printing it fails harmlessly |
| Lost | connection dropped, reboot | as given up, or everything dead at once |

`DETACHED` is what changes things but `create`, which has its eleven minutes, and a
kill cuts short cleanly, and `send`, whose prompt is better not sent than sent long
after you stopped waiting. `seen` and `turn` don't either: each is a line in a
record, sent again at the next poll.

Invariants:
- I1. A request Emacs gave up on may still act, for as long as it likes, on any
  host. Nothing bounds that: no deadline in the request, and the wait on the
  registry lock has no timeout. It is why the "may still finish" message in
  `roost--run` is true. A reply nobody reads ends quietly.
- I2. A retry must be safe beside the original. True where an ID or a record
  makes it so (`create`, `send` from a draft or a note, finishing actions, `stop`,
  `rename`, `update`); not for `attach` (a second copy under a new name, harmless), or
  the teardown command (runs again).
- I3. No lock is handed to what the helper starts. What must outlast Emacs's wait
  does so by the helper outlasting it.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| Waiting | reply | | done | callback | `roost--run` |
| Waiting | timer | local host | Given up, local | kills the waiting parent, and what looks; what changes things goes on | `roost--expire-request`, `detach` |
| Waiting | timer | SSH | Given up, SSH | helper goes on, and acts when it gets the lock | `roost--expire-request` |
| Given up | same action again | | two helpers | second waits on the lock, or is refused by `require_not_removing` | `rpc` |

Waits Emacs gives: 60 s by default; `create` +600 s; anything with a teardown
command +120 s; `attach` by size. A push may take 120 s (`REMOTE_GIT_TIMEOUT`)
and a merge's hooks as long as they like: past the default 60 s, Emacs says no reply
came, and the request ends by itself.

Illegal or refused: nothing refuses a request for being old.
Open: none.

### Finishing a task

Kind: implicit. Lives in: the order of steps in `retire` and `discard`,
`retiringCommit`, `removing`.
What each step leaves if it stops there, and what asking again does.

`retire` and `merge`:

| Step | What | Lock | Stopped here, then asked again |
| --- | --- | --- | --- |
| 1 | read record, ask forge | none, then none | nothing changed |
| 2 | `require_not_removing` | registry | refused, nothing changed |
| 3 | `require_finished`, pane ownership | registry | refused |
| 4 | `put_back_removed` if `removing` | registry | restores tracked files, its link |
| 5 | `check_worktree`, clean, submodules, Git lock, agent work | registry | refused, nothing changed |
| 6 | branch moved from `expect`, then merge | registry | see next machine; a second merge finds it there |
| 7 | `safe_to_delete`, save `retiringCommit` | registry | |
| 8 | `stop` | registry | task stopped; agent's window gone |
| 9 | `remove_worktrees` | released | worktree partly gone; `put_back_removed` restores it |
| 10 | staging folder, `unregister_gone`, `delete_branch` | registry | branch still there, `check_worktree` finds no folder and goes on |
| 11 | `Store.remove` | registry | record gone; attachments first, so a kill between keeps the record |
| 12 | `delete_remote_branch` | none | remote branch stays; nothing else depends on it |

`discard`: steps 2, 4, then `check_worktree(branch=False)`; the dry run stops
there. Then `expect` against the branch, `told` against `discard_losses` counted
again, `stop`, removal with force, branch, record. No checkpoint: `expect` and
`told` are the guards, and a retry asks Emacs for a new dry run.

Invariants:
- I1. No uncommitted work and no unmerged commit is lost by retire: checked
  before the agent stops (`require_clean`), again after (`remove_worktrees`), and
  the branch is deleted only at the commit verified. Holds, fuzzed against
  commits landing throughout.
- I2. A second request finds its own partial work and finishes it, for the
  task's worktree (`put_back_removed`). What a removal left of an agent's isn't
  a worktree any more, so it stays, and the reply says so.
- I3. What a removal touches is the task's, as [Agent worktrees](#agent-worktrees)
  has it. Holds.
- I4. After a step fails past 8, the task is stopped, and the merge has happened, as
  `landed` shows. With its worktree still there, `resume` works. Once removal has
  gone through, as when `delete_branch` then fails, `resume` refuses for want of a
  worktree: the way on is to clear what refused it and finish the task again.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| step 6 done | removal refused by teardown's files | | stopped, merged, `retiringCommit` | says so; clearing them and `m` finishes | `remove_worktrees` |
| step 8 done | agent committed in the last moment | | worktree gone, branch moved | `delete_branch` refuses; `m` merges the rest | `delete_branch` |
| step 10 done, branch gone, `merge` asked | `retiringCommit` set | | only the record is left | merge skipped | `retire` |
| step 10 done, branch gone, `merge` asked | no `retiringCommit` | | refused | "nothing to merge"; retire finishes | `retire` |

Illegal or refused: an agent at work, a task another pane took, a dirty worktree,
unmerged commits, work in its agent's worktree or submodules, a locked worktree,
and for `merge` a branch moved from `expect`; each before anything changes. `discard`
refuses what `check_worktree` refuses with `branch=False`, a link, a path outside
Roost's folder, a moved worktree, and a missing one whose branch the primary checkout
holds; then a branch moved since its dry run, more to lose than it told you, and what
`require_nothing_kept` finds. With the repository gone, nothing keeps a worktree, and
`unregister_gone` has nothing to do.
Open: none.

### The merge

Kind: implicit. Lives in: `.git/MERGE_HEAD`, the index, the integration ref,
`integrating` in the record, `merging/<repository>.lock`.
What `retire`'s step 6 and `update` can leave in the checkout they merge in. Git
merges without the registry lock (`integrating`), for a merge under a lock of the
repository's (`merging_in`).

| State | Meaning | How you can tell |
| --- | --- | --- |
| Clean | ready | no tracked changes, no `MERGE_HEAD` |
| Merging | Git at work, or stopped | `MERGE_HEAD` |
| Squash staged | `git merge --squash` done, `git commit` not | staged changes, no `MERGE_HEAD` |
| Committed | work on integration | tip of task in integration, or tree equal |
| Conflicted | | `git diff --diff-filter=U` |
| Elsewhere | no worktree has integration: only the ref moves | `here` false |

Invariants:
- I1. A conflict, or a hook's refusal, changes nothing of yours. Holds
  (`undo_merge`, `refused_by_hook`), in tests of old.
- I2. The merge is once: `merge_without_checkout` and `squash_merge` find it there
  by ancestry or by tree. Holds when asked again in the same style. A squash
  retried after integration moved on the same lines reports a conflict;
  `u` then `m` adds nothing wrong.
- I3. Git's output goes to files, so a helper gone doesn't stop Git at a report
  (`git_with_hooks`). Holds.
- I4. One merge at a time in a repository. A second is refused at once, saying which
  runs: it could only wait. An `update` reads integration and takes no such lock.
- I5. A merge cut short is named, and never read as your changes. The mark stays
  until a poll, or `merge`, `retire`, `update`, `pr`, `resume` or `send`, finds with
  `merge_left` that nothing is left: HEAD moved, or nothing differs. A checkout it
  can't read, missing or not answering Git, proves nothing, so the mark stays and
  nothing is refused until it can. Git killed alone fails the action and leaves the
  mark in the same way, if anything is left, unless it put back what it did
  (`Undone`): then what is there isn't the merge's. Conflicts with no `MERGE_HEAD`
  are Git killed as it wrote them, and neither `update` nor `m` takes them for a
  conflict of the work. After the merge, retiring checks the worktree again, as hooks
  ran with no lock on what an agent does there. A poll's look runs no program an agent
  could name in that checkout's config (`read_git`). A half-done
  merge refuses `merge` and `update`, whose mark would replace its own, and a
  half-done update all six, saying how to finish or
  undo it: an agent would commit what an update left. Roost began with nothing
  uncommitted there, so what differs is the merge's, and `merge_left_in` tells a
  second task's merge the same, until that task is discarded or forgotten.
- I6. While it runs, a hook that hangs holds the task and the repository: nothing
  ends it. The refusal says how, by the process group the mark names.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| Clean | merge | `here` | Merging | `git merge --no-ff` | `merge_task` |
| Clean | squash | `here` | Squash staged | | `squash_merge` |
| Clean | merge or squash | not `here` | Committed | `merge-tree`, `commit-tree`, `update-ref` with old value | `merge_without_checkout`, `squash_merge` |
| Merging | hook refuses | exit 1, no conflicts | Clean | `refused_by_hook` | `merge_task` |
| Merging | conflict | | Clean | `git merge --abort` | `merge_task` |
| Merging | Git dies | | Merging | `m` says finish or undo | `merge_left` |
| Squash staged | Git dies | | Squash staged | `m` says undo it with `git reset --merge` | `merge_left` |
| Squash staged | hook refuses | | Clean | `refused_by_hook` | `squash_merge` |
| Squash staged | committed | | Committed | | `squash_merge` |

Illegal or refused: a merge under way, a rebase of integration anywhere, a
worktree elsewhere on integration, ignored files it would overwrite, a shallow
history; everything but looking on the task while Git runs.
Open: none. The known item on `u` and submodules is under
[Known and not fixed](#known-and-not-fixed).

### The task's worktree as Roost reads it

Kind: implicit. Lives in: the folder, its `.git` file, Git's `worktrees/<name>`.
`check_worktree` classifies it before anything acts on it.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Good | on the task's branch | `symbolic-ref` |
| Link | folder replaced by a symlink | `is_symlink` |
| Elsewhere on disk | outside Roost's folder | `is_relative_to` |
| Moved | `git worktree move`, folder there | `moved_worktree` |
| Moved, folder gone | | `moved_worktree` |
| Gone | folder missing, Git may keep it | not `exists` |
| Taken by primary | branch checked out in the primary checkout | `current_branch` |
| Operation under way | rebase, cherry-pick, revert, bisect, am | `operation_under_way` |
| Unreadable | Git fails with more than 1 | `symbolic-ref` exit |
| Other branch | | `symbolic-ref` differs |
| Branch renamed | on another, task's is gone | `ref_exists` |
| Locked | `git worktree lock` | `worktree_lock` |
| Unlinked | its `.git` missing or leading nowhere | `linked` |

Invariants:
- I1. Roost's own removal never reads as your changes (`put_back_removed`).
- I2. With `branch=False`, for an agent or a shell, only where it is matters.
- I3. Git in a task's worktree is that worktree's. True because it lies outside
  any checkout, unless the state directory lies in a repository, as with a
  `~/.git`; then an unlinked one reads as the outer repository's, and every
  action refuses. Not true of agent worktrees, which lie inside the primary
  checkout: `worktree_at` asks at the path, and takes no answer from further up.

Illegal or refused: `check_worktree` refuses every row above but Good, Gone, Locked and
Unlinked, for merge, retire, `pr` and `update`. With `branch=False`, for `discard`,
`resume` and a shell, only where it is matters: Link, Elsewhere on disk, Moved, Moved
with its folder gone, and Taken by primary. Locked refuses only merge and retire, in
`retire`: `update` and `pr` go on. Gone refuses what needs the folder, as
[Action by state](#action-by-state) says. Each refusal says what to do. Walked through
by the Git edge-case matrix ([#126](https://github.com/csheaff/roost/issues/126)) and [#212](https://github.com/csheaff/roost/issues/212).
Open: none.

### Agent worktrees

Kind: implicit. Lives in: `agentWorktrees` and `agentMade` in the record, folders
under `<repo>/.claude/worktrees/`, branches.
Worktrees Claude Code makes for a task's agent. `agentWorktrees` says where its
agent has been, and `agentMade` which of those its hooks say it made.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Unknown | no hook from there yet | not listed |
| Been there | a hook's `cwd` lay inside it, and nothing says the agent made it | in `agentWorktrees` alone; the entry never leaves |
| Made | a hook says the agent made it | in `agentMade` too: `ClaudeAgent.made_worktree` |
| Holds work | made, with commits past the task's branch, or dirty | `agent_work` |
| Idle | made, with nothing beyond the task's branch | `ahead == 0`, not dirty |
| Gone | folder missing | `agent_left` doesn't name it |
| Remnant | folder there, no worktree at that path | `worktree_at` says None |

Invariants:
- I1. A path is a worktree only if Git says so at that path: linked, with that path
  its top level, and in Git's list (`worktree_at`). What Git says from a folder
  with no `.git` of its own is the primary checkout's, and counts for nothing.
- I2. Only what its agent made goes: a hook said so, as EnterWorktree's "Created",
  not "Entered", "Reused" or "Resumed", or a subagent whose ID names the folder; Git
  made it since the task started (`made_since`, by the `commondir` Git writes once);
  and it is the one made then, by that stamp in `agentMadeAt`, not another since at
  that path, looked at again just before removal, as a teardown command runs first.
  No stamp says no. A worktree its agent makes again at that name takes a new stamp.
  A workflow's folder names no agent, so it stays. A record from before
  `agentMade` has no such key, and is never given one: its worktrees still show and
  keep the task from retiring, with `made` false, and stay.
- I3. A branch goes only if `git worktree remove` exited 0, only if it is
  `worktree-<folder>` (`ClaudeAgent.worktree_branch`), which Claude makes, and
  through `delete_branch`, which refuses one checked out anywhere.
- I4. What stays is said: `agent_left` fills `leftBehind` in the reply, and Emacs
  shows it.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| Unknown | hook | `cwd` under the folder, not `stopped` | Been there | saved | `update_hook`, `agent_worktree` |
| Unknown, Been there | hook | says the agent made it | Made | saved | `update_hook`, `ClaudeAgent.made_worktree` |
| Made | retire | holds work | refused | names it, says what to do | `require_agent_work_kept` |
| Made | retire | idle | Gone | `git worktree remove --force --force`, then the branch | `remove_agent_worktrees` |
| Made | discard | | Gone | the same, whatever it holds | `remove_agent_worktrees` |
| Made | Git can't remove it | | stays | so does its branch; the reply says both | `remove_agent_worktrees`, `agent_left` |
| Made | on another branch | | Gone | that branch stays, and `worktree-<folder>`, which the reply names | `remove_agent_worktrees`, `agent_left` |
| Been there | retire, discard | | stays | the reply says so; work there refuses nothing | `agent_left` |
| Remnant | retire, merge, discard | | stays | the reply says so; Git's entry stays for `git worktree prune` | `agent_work`, `agent_left` |

Illegal or refused: retire with work there, as above; a hook from a stopped task
records nothing. A worktree Roost never heard of stays where Git put it, which is
safe. After a removal stopped with its `.git` still there, the files Git had deleted
read as uncommitted, so retire refuses, and says to run the `git worktree remove`
that finishes it.
Open: none.

## What an agent is doing

How the helper knows, and the process that runs the agent. `roost-program-status`
is off by default, so **unrelayed is what most tasks run**: hooks alone set the
status, and the poll fills in what hooks can't say. Relayed means the runner's
`relay` reads OSC 7501 reports, and the task's `programStatusRun` equals its `runId`,
set by the run's first report.

### Agent status

Kind: explicit. Lives in: `status` in the task's record, with `lastEvent`,
`updatedAt`, `error`, `exitCode`, `endedRun`, `statusBeforeCrash`, `seenBeforeCrash`.
What the agent is doing as far as Roost knows. Emacs names it (`roost--status-name`):
`failed` with a live pane reads `error`; `ready` with `lastEvent` `Interrupt`
reads `interrupted`.

| State | Meaning | How you can tell |
| --- | --- | --- |
| `starting` | Runner made, agent has reported nothing yet | `ACTIVE`; set by `make_task` and `spawn` |
| `ready` | Agent waits for a prompt | `lastEvent` says why: `SessionStart`/`session_start` (counts as seen), `Stop`, `Interrupt`, `Idle`, `Notification` |
| `running` | Agent works on a prompt | `ACTIVE` |
| `permission` | Agent asks something | `ACTIVE`; `lastEvent` `Dialog` means it holds up no turn |
| `background` | Turn ended with work left: Claude's tasks or crons, Pi's queue | `ACTIVE`; never reported by Codex or OpenCode |
| `stopped` | Stopped with `K` | `ENDED`; `paneId`, `windowId` None |
| `exited` | Agent's process ended 0, or Claude said you left it | `ENDED` |
| `failed` | Runner: agent ended non-zero, or setup failed. Hook/report: a turn ended on an error while the agent lives | `ENDED`, though the second meaning has a live agent; `live` tells them apart |
| `crashed` | Pane gone or dead while the record said otherwise | `ENDED`; only `list_tasks` writes it |
| `retired` | Only in a reply; older helpers left it in records, which `list_tasks` deletes | |
| `discarded`, `forgotten` | Only in a reply | |

Invariants:

- I1. `ACTIVE` means work may be under way; `ENDED` means the process has ended
  (comment at `ENDED`). Assumed by `list_tasks` and `require_finished`. **Not
  true of `failed` from `StopFailure`, or a report's `error`:** the agent lives,
  which is why Emacs reads `live`.
- I2. A status comes only from the current run: a hook, report or runner of an
  earlier run changes nothing (manual, How it works).
- I3. `stopped` is final until `spawn`: no source but `spawn` leaves it.
- I4. `crashed` means the pane went (manual, What a task says), and a live pane
  never stays `crashed`. An agent's own word on its end counts only if you ended
  it: as it dies by a signal, it leaves the end to the runner, or the poll.
- I5. `exited`/`failed` from the runner are final for that run: it notes `endedRun`,
  and `update_hook` and the recorder take nothing of that run's status after it.
- I6. `permission` shows while the agent waits on you, and only then, as far as
  its hooks can say. `send` depends on it: it refuses `permission` because a
  paste and Enter could answer a menu. Unsure, it stands, as the manual allows.
  Open: STATUS-3.
- I7. Every status change moves `updatedAt`; nothing else does (`turn`, `rename`,
  `seen`, `inspect` keep it).
- I8. A live agent's status can only be wrong until its next event. **Not
  promised anywhere, and the poll fills in only Claude's Esc and approvals:** for
  Codex, Pi and OpenCode nothing reads a live `running`, so an event lost stays
  lost until the agent's next one. Open: STATUS-3.

#### Transitions that belong to no adapter

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| (none) | create | | `starting` | record saved, then spawned, under one lock | `make_task` |
| any | resume | pane not live; no agent elsewhere; worktree there | `starting` | new `runId`, `error` None, request forgotten; `lastEvent`, `exitCode`, `statusBeforeCrash` left as they were | `resume`, `spawn` |
| any but `retired` | stop | | `stopped` | agent's pane and shell closed if owned; `paneId`, `windowId` None; seen carried over | `stop` |
| not `stopped`/`retired`, this run | agent's process ended | | `exited` if code 0, else `failed` | `exitCode`, `error`, `endedRun`; after `finish()` | `runner` |
| same | setup, copy or submodules failed | | `failed` | `error` is the reason; pane shows it | `runner` |
| not `ENDED` | poll: pane not live | tmux answered | `crashed` | `statusBeforeCrash`, `seenBeforeCrash` | `list_tasks` |
| `crashed` | poll: pane live | | `statusBeforeCrash`, else `ready` | seen restored | `list_tasks` |
| `running`, `permission` | poll: transcript's newest entry is Claude's interrupt marker, since `updatedAt` | unrelayed; Claude only | `ready`, `Interrupt` | request cleared | `list_tasks`, `ClaudeAgent.interrupted` |
| `permission` | poll: the asked command's `eval '…'` runs under the agent | unrelayed; `requestCommand` | `running`, `Approved` | request cleared | `list_tasks`, `approved_command_running` |
| `starting` | creation failed after the worktree | | `failed`, or the record goes | | `abandon` |

#### Claude, unrelayed (`ClaudeAgent.observe`)

| From | Event | Guard | To | `lastEvent` | Effect |
| --- | --- | --- | --- | --- | --- |
| any | `SessionStart` | `source` not `compact` | `ready` | `SessionStart` | `source=clear` clears `lastReply`, and counts over reports |
| any | `SessionStart` | `source=compact` | unchanged | unchanged | session and transcript noted |
| any | `SessionEnd` | `reason` `clear`/`resume` | unchanged | unchanged | nothing at all |
| any | `SessionEnd` | `reason` `prompt_input_exit`, `logout` | `exited` | `SessionEnd` | you left it: `/exit`, C-c, C-d, `/logout` |
| any | `SessionEnd` | any other, as `other`, for SIGHUP and SIGTERM | unchanged | unchanged | session noted; the end is the runner's, or the poll's |
| any | `UserPromptSubmit` | | `running` | same | `lastReply` None; `lastPrompt` unless it's Claude's own note |
| not `permission` | `PreToolUse`, `PostToolUse` | | `running` | same | |
| `permission` | `PostToolUse` | from the agent that asked, of the tool it asked for | `running` | same | request cleared |
| `permission` | `PreToolUse` | from the agent that asked | `running` | same | request cleared: it went on, as when what it asked for failed |
| `permission` | `PreToolUse`, `PostToolUse` | named by a notification, not an MCP question's; the main agent's | `running` | same | request cleared |
| `permission` | `PreToolUse`, `PostToolUse` | any other | unchanged | unchanged | `tool_answers` |
| any | `PermissionRequest` | | `permission` | same | `request`, `requestCommand` |
| any | `Stop` | `background_tasks` or `session_crons` | `background` | `Stop` | `lastReply` |
| any | `Stop` | else | `ready` | `Stop` | `lastReply` |
| any | `StopFailure` | | `failed` | same | `error`, `lastReply` |
| any | `Notification` | `permission_prompt`, `worker_permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog` | `permission` | `Notification` | names the request if none was |
| `starting`, `running` | `Notification` | `idle_prompt` | `ready` | `Notification` | |
| others | `Notification` | `idle_prompt` | unchanged | | |
| `permission` | `Notification` | `elicitation_response`, `elicitation_complete`; `requestQuestion`, so an MCP server's question asks, and nothing beside it | `running` | `Notification` | request cleared |
| any | `Notification` | any other type | unchanged | | |

Claude waits for a hook before it goes on, and the captures show `PreToolUse`,
`PermissionRequest`, `PostToolUse` in order. Whether it waits for `Notification`,
which comes on a timer, isn't established. Subagents' tool events come through
the same hooks, beside the main agent's, with `agent_id`, which the main agent's
lack; no capture has one yet. As a request waits, a tool called together with
the one that asked may still end, and is left out by its arguments: a tool's end
agrees with the request on each argument both name, as a question's end adds its
answers, and Codex's leaves out a `description`. A next `PreToolUse` from that
agent counts as going on, though one called together with it could land after
the request; its notification, six seconds on, then shows `permission` again.
What stands may stand long: a subagent declined that calls no tool again, and
another agent's request (`worker_permission_prompt`, `agent_needs_input`), which no
tool's event ends, each show `permission` until the turn ends.

Between `SessionEnd` and the process's end, a moment: with `prompt_input_exit`, an
unrelayed task reads `exited` and a relayed one what it was, and with `other`, both
read what they were, while the pane is live. `send` reaches an agent on its way
out, and `resume` says it still runs. Then the runner records the end, or the
pane has gone with it and the poll says `crashed`.

#### Codex, unrelayed (`CodexAgent.observe`, after `concerns`)

`concerns` drops events from a `cwd` outside the worktree, as Codex's memory
agent. No `Notification`; no `background`; `error` isn't reset by hooks.

| From | Event | To | `lastEvent` | Effect |
| --- | --- | --- | --- | --- |
| any | `SessionStart` | `ready` | same | `source=clear` clears `lastReply` |
| any | `SessionEnd` | unchanged | unchanged | its schema's only `reason` is `other`: the end is the runner's, or the poll's |
| any | `UserPromptSubmit` | `running` | same | |
| any | `PreToolUse`, `PostToolUse` | `running` | same | from `permission`, as Claude's above |
| any | `PermissionRequest` | `permission` | same | |
| any | `Stop` | `ready` | `Stop` | `lastReply` |
| any | `Interrupt` | `ready` | `Interrupt` | Esc, or a declined request |

Codex waits for each hook, and kills one after 3 s (`timeout = 3`), losing its
event: STATUS-3.

#### Pi, unrelayed (`PiAgent.observe`)

| From | Event | Guard | To | `lastEvent` |
| --- | --- | --- | --- | --- |
| any | `session_start` | | `ready` | `session_start` |
| any | `prompt` | not `source=extension` | unchanged | unchanged; `lastPrompt`, `lastReply` None |
| any | `agent_start` | | `running` | `agent_start` |
| any | `agent_end` | `pending` | `background` | `Stop` |
| any | `agent_end` | else | `ready` | `Stop` |
| any | `agent_settled` | `aborted` | `ready` | `Interrupt` |
| any | `agent_settled` | else | unchanged | |
| `running`, `background` | `ui_prompt_start` | | `permission` | `ui_prompt_start` |
| others | `ui_prompt_start` | | `permission` | `Dialog` |
| `permission` | `ui_prompt_end` | `idle` true | `ready` | `ui_prompt_end` |
| `permission` | `ui_prompt_end` | else, `idle` unknown too | `running` | `ui_prompt_end` |
| others | `ui_prompt_end` | | unchanged | |

No event for a failed agent, so a turn's API error reads `ready` unrelayed.

#### OpenCode, unrelayed (`OpenCodeAgent.observe`)

| From | Event | Guard | To | `lastEvent` |
| --- | --- | --- | --- | --- |
| any | `start` | | `ready` | `SessionStart` |
| any | `status` busy, retry | | `running` | `Busy`; `lastReply` None unless from `running`/`permission` |
| any | `status` idle | aborted, or declined with no error | `ready` | `Interrupt` |
| any | `status` idle | another error | `failed` | `StopFailure` |
| any | `status` idle | else | `ready` | `Stop` |
| `running`, `permission` | `asked` | | `permission` | `PermissionRequest` |
| others | `asked` | | `permission` | `Dialog` |
| `permission` | `replied` | | `running` | `Answered` |
| others | `replied` | | unchanged | |
| any | `prompt` | | unchanged | unchanged |

[The extensions' report chains](#the-extensions-report-chains) says what its
plugin folds into these.

#### Reports, relayed (`apply_program_status`)

`T` = the adapter's `reports_turns` (Claude, Pi, OpenCode true; Codex false).
A report with an `id` is a subagent's, and left out. A report read before `hookAt`
is dropped first; Codex's hooks set that, and Claude's `SessionStart` with
`source=clear`. Conditions are tried in this order:

| From | State | Guard | To | `lastEvent` |
| --- | --- | --- | --- | --- |
| not `running` | `working` | `T`, or from `permission` | `running` | `Approved` from `permission`, else `Working` |
| not `permission` | `blocked` | | `permission` | `Blocked` from `running`, else `Dialog` |
| `permission`, `lastEvent` `Dialog` | `done`, `idle` | | `ready` | `Idle` |
| `starting`, `running`, `permission` | `done` | | `ready` | `Stop` |
| `running`, `permission` | `idle` | | `ready` | `Interrupt` if `T`, else `Idle` |
| `starting` | `idle` | | `ready` | `SessionStart` |
| not `failed` | `error` | | `failed` | `Error`; `error` set |
| any | `clear`, or none of the above | | unchanged | |

`error` is cleared whenever a report changes the status. `background` survives
`done` and `idle`, and gives way to `working` and `blocked`.

Notes, not findings: `background` then `blocked` then `idle` ends at `ready`, so
the background work is forgotten until the next turn. `/clear` reports `working`,
then `idle`, which reads `Interrupt` until its `SessionStart` lands, about 60 ms
on. Other slash commands that report `working` may read `interrupted` too; no
capture has one.

Illegal or refused: `update_hook` and the recorder ignore `stopped`, `retired`
and any other `runId`. After the runner's end (`run_ended`), the recorder ignores
that run, and `update_hook` keeps only what a hook says beside the status, as
its reply.

Open: STATUS-3.

### Who wins: hooks, reports, poll, runner

Kind: implicit. Lives in: `programStatusRun`, `runId`, `hookAt`,
`receivedAt`, the `reports_turns` of each adapter, `beside_program_status`, the
`guess` in `list_tasks`.
Four sources write one field. This says which counts when they disagree.

| Mode | How you can tell | Status comes from |
| --- | --- | --- |
| Unrelayed | `programStatusRun` != `runId` | Hooks, in order of the lock; the poll for Claude's Esc and approvals |
| Relayed, turns (Claude, Pi) | `programStatusRun` == `runId`, `reports_turns` | Reports. Hooks keep their other fields, and their status only if `failed`, `background` from `running`/`ready`, or Claude's `SessionStart` with `source=clear`, as reports can't say that a new conversation started |
| Relayed, hooks (Codex) | same, not `reports_turns` | Hooks, but for `running` from `permission`. Reports for what hooks miss: a request, its approval, `idle` after a failed request, `error`. A report read before `hookAt` is older news |

Before a relayed run's first report it counts as unrelayed. The poll's guesses
(`was_interrupted`, `approved_command_running`) run only when unrelayed. The
crash check runs in every mode. The runner's end is last in every mode, as
`finish()` records what is queued first.

Invariants:

- I1. Everything that writes a status holds the registry lock, and reads the
  record under it: checked for each writer (`spawn`, `stop`, `update_hook`, the
  recorder, the runner's end, `list_tasks`, `abandon`). No stale save writes a
  status: after `store.released()`, `remove_worktrees`, `pr` and
  `check_pull_requests` read afresh or save nothing of it.
- I2. For a relayed agent, reports are one queue in order, and a hook's status
  counts only for what reports can't say.
- I3. A hook is recorded before its agent goes on (Claude, Codex), or in order
  with the next (Pi, OpenCode): "it runs its hooks before it goes on" at
  `apply_program_status`. **Broken by timeouts:** an event may never be recorded
  (STATUS-3). Subagents' hooks aren't ordered with the main agent's, so a tool's
  event ends a request only from the agent that asked.

Is the outcome the same in any order? Replayed: each capture in
`test/captures` with each event delivered up to three places late.

| Swap | Can it happen | Outcome |
| --- | --- | --- |
| Report later than following hooks (the queue waits for the lock) | Yes | Same end, each step, for all relayed captures: Claude's hooks hold only other fields, and Codex's `hookAt` drops the old report |
| Report later than another report | No: one queue | |
| Hook later than the agent's next event | Not for an awaited hook of one agent | Different, and stays so until the next event, for `Stop`, `PermissionRequest` |
| `PermissionRequest` and another agent's tool event, unrelayed | Yes, with subagents | `permission`, either way |

Disagreements, and who wins:

| Case | Wins | Right? |
| --- | --- | --- |
| Hook `running`, report `blocked`, Claude | Report | Yes |
| Hook `Stop` with work left, report `done`, either order | Hook: `background` | Yes |
| `StopFailure`, report `done`/`idle`, either order | Hook: `failed` | Yes |
| Hook `PostToolUse` during `permission`, Codex relayed | Dropped | Yes |
| The same unrelayed, Claude or Codex | The request, unless the hook is the agent that asked moving on | Yes |
| `SessionEnd` as tmux goes, relayed or not | Poll: `crashed` | Yes |
| Hook after the runner's end | Runner: the hook keeps only what it says beside the status | Yes |
| Claude's `SessionStart` with `source=clear`, report `idle`, either order | Hook: `ready`, `SessionStart` | Yes |
| Poll `crashed`, then a hook of a live agent | Hook, and `statusBeforeCrash` goes stale, unused | Yes |
| Poll `crashed`, then relayed `done` | Neither: the report changes nothing, and recovery brings back `running` | Would be wrong, but needs a false `crashed`, and none is known since the C locale fix |

Open: STATUS-3.

### A task's request

Kind: implicit. Lives in: `request`, `requestCommand`, `requestFrom`,
`requestCall`, `requestQuestion`, `activity`.
What the agent asks, in words; the command to watch start; whether the words are
the agent's own report; which tool call will say it's over; what it says it's doing.

| State | Meaning | How you can tell |
| --- | --- | --- |
| None | Nothing asked | no `request` |
| Named by a hook | From the tool's payload, or a notification's message | `request`, no `requestFrom` |
| Watching a command | As above, for the main agent's Bash, as the poll can't tell whose process it sees | `requestCommand`, at most 200 characters |
| Knowing its tool | Named by a hook that names a tool | `requestCall`: who asked, the tool, a digest of each argument |
| Overlapping | Another agent asks, by `worker_permission_prompt` or `agent_needs_input`, or anything new asks beside a request, unrelayed | `requestCall` names no agent that reports; no `requestCommand` or `requestQuestion` |
| An MCP question alone | The first thing to ask since the agent last didn't | `requestQuestion` |
| Named by a report | The agent's words | `requestFrom` = `report` |

Emacs shows `request` only while `status` is `permission`
(`roost--permission-request`). No Emacs code reads `activity`.

Invariants:

- I1. A request belongs to the question that named it.
- I2. A report's words give way to a hook's, and to the next report.
- I3. A notification that follows a request, naming no tool, keeps it.
- I4. A tool's event ends a request only from the agent that asked: the end of what
  it asked for, or its next tool (`tool_answers`). Without `requestCall`, a
  notification named it, and only the main agent's event does. `requestQuestion`
  is ended by word that it was answered, and by no tool's event. Unsure, it stands.
- I5. Overlapping requests end together: one answer can't say the other was, so
  no tool's event, answer or approval ends them. Only the turn's end, as `Stop` or
  the poll's Esc, a new prompt, or the run's end does. A `permission_prompt`
  beside a request is taken for the notification that follows it, as it can't be
  told from one, but for a question's, which has none.

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| any | hook that asks, naming a tool | | hook-named; `requestFrom` gone; `requestCommand` if Bash; `requestCall` | `update_hook` |
| any | adapter names it (`named`) | | same | `update_hook` |
| any | hook that asks, naming nothing | was `permission` | unchanged | `update_hook` |
| any | hook that doesn't ask | unrelayed, Codex, or a new conversation; not `permission` to `permission` | None | `update_hook` |
| any | a tool's event that isn't an answer | unrelayed | unchanged | `tool_answers`, `update_hook` |
| An MCP question alone | `elicitation_response`, `elicitation_complete` | | None | `update_hook` |
| any but Overlapping | `PermissionRequest`, or a notification of an MCP question, while `permission`; a `permission_prompt` beside a question | unrelayed | Overlapping | `update_hook` |
| any | notification of another agent's request | unrelayed | Overlapping | `update_hook` |
| None, report-named | report `blocked` | `permission` now | report-named; words from `msg`, or `kind` | `apply_program_status` |
| hook-named | report `blocked` | | unchanged | `apply_program_status` |
| any | report leaves `permission`, or anything but `running` | | None | `apply_program_status` |
| any | poll: Interrupt or Approved | | None | `list_tasks` |
| any | stop, runner's end, crash | | unchanged, and shown only while `permission` | |
| any | spawn | | None, `activity` too | `spawn` |

Known, and left: two calls of one tool with the same arguments, one approved and one
waiting. The first's end reads as the second's, which `tool_answers` can't tell
apart, as a request carries no ID of its call.

Open: none.

### A run and its pane

Kind: implicit. Lives in: `runId`, `paneId`, `panePid`, `windowId`, `windowIndex`,
`session`, `shellPaneId`, `helper`; the pane option `@roost_task_id`;
`remain-on-exit`; tmux itself.
Which process is this task's agent, and whether Roost may touch it.

| State | Meaning | How you can tell |
| --- | --- | --- |
| No run | Stopped, or made and never spawned | `paneId` None |
| Owned, live | The run's pane | `owned_pane`: tag and `panePid` match, not dead |
| Owned, dead | The runner ended; the pane holds its last output | `owned_pane`, `dead` |
| Gone | No such pane | not in the inventory |
| Reused | Another pane has the ID, after tmux restarted | ID there, tag differs |
| Moved | Owned, in another window or session | `windowId`, `windowIndex` and `session` follow it at the next `list`, `inspect` or `shell` |
| Respawned | Another process in the run's pane | ID and tag match, `panePid` doesn't: not owned |
| Unknown | tmux didn't answer | `pane_inventory` None; `live` None |

Invariants:

- I1. Roost steers or kills only a pane it owns: its tag "prevents steering or
  killing an unrelated process with the same ID" (`owned_pane`), which is all that
  tells panes apart after tmux restarts, when window IDs start over too.
- I2. One agent per task. `resume` refuses a live pane, and an agent started by
  hand in the task's session (`agent_elsewhere`).
- I3. `runId` changes at each `spawn`, before the window starts; the runner waits
  on the lock until it is saved, and closes its window if the record names
  another run.
- I4. Owned means the agent's runner: the tag stays on whatever tmux starts in the
  pane, so `spawn` notes the process tmux started, and only that is owned. A task
  whose run began before `panePid` is taken as it is, until it resumes.
- I5. Not owned means the agent isn't in that pane: the tag goes where the pane goes.
- I6. What Roost closes is the agent's pane and the task's shell, where tmux has
  them as it closes them, each with its window if nothing else is in it
  (`close_panes`): a pane of yours beside them stays.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| No run, Gone, Reused, Respawned, Owned dead | `resume` | | Owned, live | dead pane and the task's shell closed; new `runId`; session named for the task; `shellPaneId` gone | `resume`, `spawn` |
| Owned, live | `resume` | | refused | "still running" | `resume` |
| Owned | `stop` | | No run | `close_panes` | `stop` |
| Gone, Reused, Respawned | `stop` | | No run | only the task's shell closed; IDs forgotten | `stop` |
| Owned, live | runner ends | | Owned, dead | | `remain-on-exit` |
| Owned, live | tmux restarts | | Gone or Reused | runner killed by SIGHUP, with no end recorded | |
| Owned, live | `kill-pane` | | Gone | shell pane, if any, stays in its window | |
| Owned | `break-pane`, `join-pane`, `move-pane` | | Moved | still owned; a shell it left stays, and `shell` opens one beside it | `list_tasks`, `inspect`, `shell` |
| Owned | `respawn-pane` | | Respawned | not `live`: `send` refused; a status not in `ENDED` reads `crashed` | `owned_pane` |
| any | a window a failed request made | `runId` differs | closes | `remain-on-exit` off | `runner` |

What an earlier run can still do. Its hooks and reports return at the `runId`
check; its runner writes nothing, as each write checks `runId`. Its Claude keeps
the path of `<id>.settings`, which the next run rewrites, so an old Claude still
alive would, if it reloads settings, report as the new run. None is known to
stay alive.

`stop`, `resume` and a restart, against each in-flight source:

| | Hook in flight | Report queued | Poll | Runner |
| --- | --- | --- | --- | --- |
| `stop` | Dropped: `stopped` | Dropped: `stopped`, or its runner died | No effect: `ENDED` | Killed by SIGHUP, or writes nothing: `stopped` |
| `resume` | Dropped: `runId` | Dropped: `runId` | Under the lock | The old one has ended; new one waits for the lock |
| tmux restart | Lands, and Claude's `SessionEnd`, reason `other`, says nothing of its status | Lost with its runner, which changes nothing | `crashed`, or `{}` for all tasks of the socket | Killed: no end recorded |

Open: none.

### The runner's stages

Kind: implicit. Lives in: `submodulesComplete`, `allSubmodules`, `copyComplete`,
`setupComplete` in the record; the runner's process.
What a new worktree needs before its agent starts, each resumed if cut off.
A flag is False until done, missing on older records and when there's nothing
to do, and `is False` is what's tested.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Waiting | Runner started, lock not yet had | `starting` |
| Submodules | `check_out_submodules` | `submodulesComplete` False |
| Copy | `copy_included` | `copyComplete` False |
| Setup | the project's setup command | `setupComplete` False |
| Agent | `relay` or `subprocess.call` | all done |
| Ended | status written | `exited`, `failed` |

Invariants:

- I1. Each flag is set only by the run that finished the stage (`runId` checked
  under the lock), and after it did.
- I2. Each stage may run again whole. `copy_included` never writes over a file;
  its staging folder is emptied first; setup is the project's to make so.
- I3. Setup runs on a first run, and on a resume only if it never finished.
- I4. `resume` of a task with no conversation yet gives it its prompt: `launch`
  passes `--resume` only with a session, and for Claude, which says its session's
  ID before anything is written to it, only with the transcript it said it would
  write (`has_conversation`). A session it never said that of is left to `--resume`.
  Codex and OpenCode name a session only at the first turn, and Pi starts on a
  session file that isn't there.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| Waiting | lock had | other `runId` | exit 0 | window closes | `runner` |
| Waiting | lock had | `stopped`, `retired` | exit 0 | | `runner` |
| Waiting | launch made | | Submodules, or next | argv fixed now, hook settings written | `agent.launch` |
| Submodules | `decided` | this run | same | `allSubmodules` saved before Git initializes any | `check_out_submodules` |
| Submodules | done | | Copy | flag saved | `runner` |
| Copy | done | | Setup | flag saved | `runner` |
| Setup | done | | Agent | flag saved | `runner` |
| any stage | fails | | Ended, `failed` | `error` shown in the pane | `runner` |
| any stage | SIGHUP, as `stop` | | gone | flag stays False; next run redoes it | |
| Agent | ends | this run, not `stopped` | Ended | see [Agent status](#agent-status) | `runner` |

Checked: a stop or kill in each stage, then resume. Sound.

Open: none.

### The relay and its recorder

Kind: implicit. Lives in: `relay`'s `to_agent`, `to_pane`, `pane`, the agent's
process; `program_status_recorder`'s queue and thread.
Gives the agent a terminal of its own, reads its reports, and keeps them from
ever holding up its output on the registry lock.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Relaying | Both ways | main loop |
| Pane gone | Only the agent's side | `pane` False |
| Backed up | A buffer past `RELAY_BUFFER`: stop reading master | `readers` empty of master |
| Draining | Agent ended; what it wrote passes on, up to `RELAY_BUFFER` | after the loop |
| Recording | Thread takes batches under the lock | first report started it |
| Finishing | `None` queued; runner joins | `finish` |

Invariants:

- I1. No thread until the first report, as the agent's start runs code between
  fork and exec.
- I2. A report read is recorded before the runner records the end, however long
  that takes ("a report recorded after the runner records the agent's end would
  undo it").
- I3. A report waits for the lock, not the agent, up to `PROGRAM_STATUS_QUEUE`.
- I4. Terminal modes are restored on every way out.

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| Relaying | master at EOF, or `process.poll()` | | Draining | `relay` |
| Relaying | fd 0 at EOF, or write to 1 fails | | Pane gone | `relay` |
| Draining | done | | `process.wait()`, then `finish()`, then the end | `relay`, `runner` |
| Relaying | SIGHUP, as `stop` or a restart | | gone at once, no `finally`; master closes, agent gets its hangup | |
| Recording | a batch | this run, not `stopped`/`retired` | applied in order, saved if changed | `record` |
| Recording | `OSError`, `ValueError`, `RoostError` | | batch dropped, thread goes on | `record` |

Checked: reading and writing at EOF and EIO both ways (`read_some`,
`write_some`), an agent that leaves its terminal busy, a `select` loop that sees
the agent's end within `RELAY_POLL`. Sound. An exception `record` doesn't suppress
would kill the thread and, after 1000 reports, stop the relay; only a damaged
record (`KeyError`) raises one.

### ProgramStatusFilter

Kind: implicit, a byte parser. Lives in: `held`.
Takes OSC 7501 out of an agent's output, whatever way its reads are cut.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Clear | Nothing held | `held` empty |
| Maybe | A prefix of `ESC ] 7501 ;` at the end of what came | `held`, `waiting` true |
| In sequence | Whole prefix, no terminator yet | `held` starts with the prefix |
| ESC at the end of a sequence | May be `ESC \` | as above |

Invariants:

- I1. Reports and passed bytes don't depend on how the input is cut, for a
  sequence within the limit.
- I2. What is no report passes on, in order; nothing is held past
  `PROGRAM_STATUS_LIMIT`.
- I3. A byte that may start a sequence waits at most `RELAY_HOLD`; one under way
  waits for its end or the limit.

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Clear | bytes, no prefix | ends in a partial prefix | Maybe | rest passes |
| Maybe | bytes | prefix completes | In sequence | |
| Maybe | no bytes for `RELAY_HOLD` | | Clear | `flush`: bytes pass |
| In sequence | BEL or `ESC \` | within the limit | Clear | report or probe read |
| In sequence | same | over the limit | Clear | discarded whole |
| In sequence | `ESC` then anything else | | Clear | passes as it is |
| In sequence | no end by the limit | | Clear | passes as it is |
| any | agent ended | | Clear | `flush(everything=True)` |

Checked: 200,000 random mixes of prefixes, terminators, other sequences and bytes
that aren't UTF-8, each cut at random, against the same uncut: no difference;
`held` never over the limit; 50,000 with flushes between reads: no difference.
Sound. The one dependence on cuts: a sequence over the limit passes on if it
arrives in pieces and is discarded if whole, which the protocol doesn't allow
anyway.

### The extensions' report chains

Kind: implicit. Lives in: `reported`, in `PI_EXTENSION` and `OPENCODE_PLUGIN`;
the plugin's `turns`, `waiting`, `failed`, `yours`, `said`.
Pi and OpenCode don't wait for handlers, so each report waits for the one before.

Invariants:

- I1. Reports reach the helper in the order of their events. Holds, but a report
  killed at 3 s is gone: the chain goes on without it.
- I2. OpenCode: the task works while any root session's turn does, and waits on
  you while any question does.
- I3. Nothing outlives the agent's exit but a report already started, which dies
  by SIGHUP as the runner exits, or lands first, and then says nothing of the
  status (`run_ended`).

OpenCode's plugin, per root session:

| From | Event | Guard | To | Reports |
| --- | --- | --- | --- | --- |
| No turn | `session.status` not idle | nothing waits | Turn | `status` busy, with your words |
| No turn | same | a question waits | Turn | nothing, or `prompt` |
| Turn | same | | Turn | `prompt`, if you sent words |
| Turn | idle, or deleted | other turns left | gone | the newest question, or busy |
| Turn | idle, or deleted | last | gone | `status` idle: reply, declined, any failure |
| any | `permission.asked`, `question.asked` | | waits | `asked` |
| any | replied, rejected | others wait | | the newest other |
| any | replied, rejected | none | | `replied`; a reply after the turn's end is ignored by `observe` |

Checked: order at abort, a reply after a turn's end, a double idle, a child
session's question. Sound.

### Seen, on the host

Kind: implicit. Lives in: `seen`, `updatedAt`, `lastEvent`, `status`,
`seenBeforeCrash`; `seen_since_last_event`; in Emacs `roost--seen` and
`roost--seen-p`.
Whether you have seen the agent since its last event, which decides whether
`ready`, `interrupted`, `error`, `failed`, `crashed` and `exited` wait on you.

| State | Meaning | How you can tell |
| --- | --- | --- |
| Seen | You saw this event | `seen` == `updatedAt` |
| Just started | Did nothing since it started | `ready`, `lastEvent` in `START_EVENTS` |
| Unseen | Else | |

Invariants:

- I1. An event moves `updatedAt`, so makes it unseen. What isn't news mustn't:
  `idle_prompt` to an agent waiting, a compaction, `stop`, and a false `crashed`.
- I2. The helper's rule and Emacs's agree (`START_EVENTS`,
  `roost--just-started-p`).

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| any | any status change | | Unseen, or Just started | every writer of `updatedAt` |
| any | relayed hook, status stripped | | unchanged | `beside_program_status` |
| Unseen | `seen` with an `updatedAt` | it's the current one | Seen | `seen` |
| Seen | `seen` with an older `updatedAt` | | Unseen | `seen`: no check |
| Seen | `stop` | | Seen | `stop` |
| Seen | `crashed` | | Unseen; `seenBeforeCrash` kept | `list_tasks` |
| any | crash recovered | was seen, then or since | Seen | `list_tasks` |

Checked: each writer of `updatedAt`, against I1. Sound. `seen` writes what it's
given, so a late reply can put back an older time: two `seen` requests in flight
could leave an agent unseen in the record while Emacs's own table says seen. It
shows only in another Emacs or after a restart, and heals as you look, so it isn't
a finding.

### History

Kind: implicit, an append-only log. Lives in: `history/YYYY-MM-DD.jsonl`.
Each change of `status`, seen, or `turn`, for Emacs to measure work and waiting.

Invariants:

- I1. Every save notes what changed, under the lock, so records and history agree.
- I2. A failure to note fails nothing else.
- I3. A line cut short costs only itself.

Every writer goes through `Store.save` or `Store.remove`, under the lock, so I1
holds. `history` reads under the lock too. Sound.

## Emacs and its hosts

A **Host request** carries everything. **Helper copy** decides whether a request
installs first. **Host refresh** is the one kind of request with state of its own, and
its replies feed **Cached task**, which drives what follows. **Watching** starts
refreshes. **Remembered files** say which hosts there are. A **Blocking wait** sits on
top of Host request, for commands that need the answer before they prompt.

### Host request

Kind: implicit. Lives in: `roost--run`'s closure (`finished`, `timed-out`,
`input-file`), the process and its `roost-timer` and `roost-dropped` properties,
`roost--requests`, the buffers ` *roost-rpc*` and ` *roost-rpc-errors*`, the
`roost-rpc stderr` pipe.
One process per request. It must end in exactly one call of one callback, and
leave nothing behind.

| State | Meaning | How you can tell |
|---|---|---|
| Unstarted | Nothing made yet | No process; buffers just made |
| Running | Process live, timer armed | In `roost--requests`, `process-live-p` |
| Expired | Timer fired, `timed-out` set | Only within `roost--expire-request`'s lambda: `delete-process` runs the sentinel at once |
| Reported | Sentinel past its guard | `finished` t, gone from `roost--requests` |
| Done | One callback ran, buffers killed | No trace |
| Dropped | Unloading Roost | `roost-dropped` set: no callback |

Invariants:
- I1. Each started request reaches Done or Dropped: its timer guarantees it if the process never ends (docstring of `roost--expire-request`).
- I2. Exactly one of SUCCESS or FAILURE runs, once (`finished`; `roost-sweep-late-a-real-reply-leaves-nothing-behind`).
- I3. No process, timer, buffer, stderr pipe or input file outlives the request (same test).
- I4. An error in a callback is Roost's, not the host's: the outcome is settled before it runs (comment in the sentinel).
- I5. A request that gets no reply "may still finish on the host" (the message; `roost--run`). Holds of what changes things, on any host, by `detach`; of `create` and `send`, only over SSH; of what looks it doesn't matter.
- I6. Time asleep isn't counted against a request (`roost--expire-request`).
- I8. A callback that signals is only logged, so whatever it would have done after
  that point doesn't happen. Nothing states this, and drafts depend on it: VIEWS-11.
- I7. Quit or a signal before the sentinel leaves no flag set. `roost--run` catches `error`, not `quit`, and the `let*` above its `condition-case` is covered by neither, so a caller that sets a flag first ends it itself: `roost--refresh-host`, `roost--report-turn`.
- I9. No timer runs between a request's end and its callback: one that throws, as `with-timeout`'s does, would leave without one (`roost-a-reply-reaches-its-callback-before-any-timer`).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Unstarted | `make-process` works | | Running | Timer armed; input sent, or read from a temp file over 4096 bytes | `roost--run` |
| Unstarted | `error` in setup | | Done | Cleans up; FAILURE called synchronously | `roost--run` |
| Unstarted | `quit`, or `error` in the `let*` (`roost--python-command`) | | (none) | Signal goes to the caller; the two buffers leak | `roost--run` |
| Running | Process exits or is signalled | | Reported | Timer cancelled, input file deleted, stderr drained with no timer run, pipe deleted | sentinel |
| Running | Timer fires | live, not late | Expired | `timed-out` set, `delete-process` | `roost--expire-request` |
| Running | Timer fires | live, over 5s late | Running | Re-armed for the whole timeout | `roost--expire-request` |
| Running | Timer fires | not live | Running | Nothing: the sentinel is due | `roost--expire-request` |
| Expired | `delete-process` | local host | Reported | **`kill(-pid, SIGKILL)`: helper, Git and hooks die** | Emacs |
| Expired | `delete-process` | SSH host | Reported | ssh dies; the helper carries on until it writes | Emacs, sshd |
| Reported | exit 0, `ok` true | not dropped | Done | SUCCESS with `result` | sentinel |
| Reported | exit 0, `ok` false | not dropped | Done | FAILURE with the host's words | sentinel |
| Reported | exit 0, no readable line | not dropped | Done | FAILURE: "returned no response" or "can't read" | `roost--decode-response` |
| Reported | exit not 0 | timed out | Done | FAILURE, marked `roost-no-reply` | sentinel |
| Reported | exit not 0 | not timed out | Done | FAILURE with the end of stderr, or "Host operation failed" | sentinel |
| Running | `roost-unload-function` | | Dropped | `roost-dropped`, `delete-process` | `roost-unload-function` |

Illegal or refused: a second sentinel call stops at `finished`. A stopped
(`SIGSTOP`) process is ignored by the sentinel; the timer kills it.

Open: none.

Notes, checked and not findings:
- Input temp files of requests live when Emacs exits stay in the temporary
  directory, mode 600.
- A dead ` *roost-rpc*` buffer in the sentinel would skip the callback, but
  killing it needs something that kills hidden buffers with a live process;
  `clean-buffer-list` and `desktop-clear` both refuse.

### Blocking wait

Kind: implicit. Lives in: `roost--requests-wait`'s `outcomes` vector, its
`with-timeout`.
For commands that need an answer before prompting.

| State | Meaning | How you can tell |
|---|---|---|
| Waiting | A slot of `outcomes` is nil | Loop in `accept-process-output` |
| Answered | All slots filled | Returns |
| Abandoned | Quit, or `with-timeout` fired | `user-error` or quit reaches the command |

Invariants:
- I1. Nothing is set before the wait that only its end clears: callbacks write only into a vector the abandoned command no longer reads.
- I2. Timers and sentinels run in the loop, with quitting inhibited, so `C-g` lands between them, never in one.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Waiting | Each request ends | | Waiting or Answered | Slot filled | `roost--requests-wait` |
| Waiting | 60s pass | | Abandoned | `user-error` naming the first unanswered | `with-timeout` |
| Waiting | `C-g` | | Abandoned | Quit; requests run on, harmlessly | `accept-process-output` |

Illegal or refused: none.

Open: none. Callers checked: `roost-discard` (dry run, re-checks `roost--went-p`
after), `roost-compose-set-issue`, `roost--jira-issue-whole`
(`roost--back-in-draft` after). `with-timeout` isn't sleep-aware, so a wait across
a laptop's sleep says "timed out" on waking; the request itself gets its time
again. Harmless.

### Helper copy

Kind: implicit. Lives in: `roost--installed` (key `(HOST ROOT)`),
`roost--helper-cache`, the file `ROOT/remote-HASH.py` on the host, each task
record's `helper`, the file's mtime, `prune_helpers`.
A helper named by its content, installed once per Emacs and host, called by
requests and by agents' hooks.

| State | Meaning | How you can tell |
|---|---|---|
| Unknown | This Emacs hasn't installed it | No entry, or another filename |
| Installing | Install request in flight (any number at once) | Requests take `install-and-invoke` |
| Installed | Entry matches; file is whole | Requests run |
| Pruned | Entry matches; file gone | `FileNotFoundError` naming it |
| Broken | File cut short, by an older Roost's install | A request says `Not whole`, naming it |

Invariants:
- I1. A file named `remote-HASH.py` holds what HASH says. Hooks of running agents call this path. An install replaces it only with every byte sent, and leaves what was there otherwise (`roost--install-code`).
- I5. A file of the right size stays, as newly used: no start of an Emacs touches what hooks call, and `prune_helpers` goes by its mtime.
- I2. A helper a task's agent was launched with is never pruned (`prune_helpers`).
- I3. Retrying can't run an action twice: only for what `roost--helper-unusable-p` accepts, `FileNotFoundError` naming the file or `Not whole`, each said before the helper runs. A request compares the file's size first, which catches a cut anywhere, and `rpc` turns what it catches into words of its own.
- I4. An unreachable host keeps its entry (`roost-an-unreachable-host-keeps-its-helper`).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Unknown | Any request | | Installing | Sends the helper as input | `roost--request` |
| Installing | Install replies | | Installed | `puthash`, then invokes | `install-and-invoke` |
| Installing | File there, of the right size | | Installed | Left in place, its mtime moved; the input goes unread | `roost--install-code` |
| Installing | Install fails | | Unknown | Nothing changes on the host; FAILURE; the next request tries again | `install-and-invoke` |
| Installing | Connection cut mid-transfer | | Unknown | Python reads EOF, finds too few bytes and replaces nothing | `roost--install-code` |
| Installed | Another Emacs's task starts | not kept, over a week old | Pruned | `path.unlink()` | `prune_helpers` |
| Pruned | Request fails, naming the file | | Installing | `remhash`, install, invoke once | `roost--request` |
| Broken | Any request | entry matches | Installing | Says `Not whole`, then as for Pruned | `roost--request` |
| Broken | Any request | no entry | Installing | Replaced whole | `roost--request` |

Illegal or refused: `prune_helpers` does nothing while a record is unreadable or
names no helper.

Open: none.

A local install killed partway leaves `tmpXXXX` in the state directory,
which nothing removes. Two Emacs of different versions reinstall each other's only
after a week. Sound.

### Host refresh

Kind: implicit. Lives in: `roost--refreshing`, `roost--full-refresh-pending`,
`roost--measures-owed`, `roost--failures`, `roost--errors`, `roost--revisions`,
`roost--list-requests`, `roost--snapshots`, `roost--pull-requests-asked`, per host.
At most one list in flight per host; its reply replaces what Roost holds of the
host unless something newer happened.

| State | Meaning | How you can tell |
|---|---|---|
| Idle | No list in flight | No `roost--refreshing` entry |
| Asking | One list in flight | `roost--refreshing` t |
| Asking, owed | And another to run after | Also `roost--full-refresh-pending`: t, or IDs |
| Backing off | Polls skip it | `roost--failures` retry time ahead |
| Offline | Views say so | `roost--errors` entry |

Backing off and Offline hold alongside Idle or Asking.

Invariants:
- I1. `roost--refreshing` is cleared by every way a refresh can end ("Each ends the refresh even if drawing what it found fails"): `finish` runs from the callbacks, and from an `unwind-protect` round `roost--request`, which can signal before any is registered. Once only: by then the flag may be the next refresh's.
- I2. One list per host at a time, so list replies can't overtake each other.
- I3. A list asked before a mutation's reply never overwrites it: `revision` is read as the list starts and bumped as the reply arrives (`roost--act`, `roost--create-task`). Checked: bumping at the reply is right; at the request would let a list read before the mutation through.
- I4. A list arriving after its host was forgotten changes nothing (`member host (roost--hosts)`).
- I5. Any reply clears Offline and Backing off; a stale one too, as the host answered.
- I6. A refresh asked for while one is in flight happens after it. One that failed, was dropped or couldn't start is owed to the next good poll, not to `finish`, so a host that always fails is asked at the pace of polls (`roost--measures-owed`). Polls stay quiet, and what is owed goes once more, so a list too slow ever to answer holds up no polls.
- I7. One message per outage (`roost--errors` tested before it's set).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Idle | `roost--refresh-host` | | Asking | Flag set, counted, revision read, `asked` stamped if asking GitHub; if not quiet, what is owed goes with it | `roost--refresh-host` |
| Asking | `roost--request` signals, or a quit | | Idle | What it would have measured is owed, `finish` runs, and the signal reaches the timer or command | `roost--refresh-host` |
| Asking | Quiet asked | | Asking | Nothing | `roost--refresh-host` |
| Asking | Full or IDs asked | | Asking, owed | Merged: t beats IDs | `roost--refresh-host` |
| Asking | Good reply | revision same, host known | Idle or Asking | Snapshot; if quiet, what changed and what is owed are measured next; if of some tasks, what changed of others is owed | success lambda |
| Asking | Good reply | revision moved | Idle or Asking | Whole reply dropped; what it measured is owed, and `asked` put back | success lambda |
| Asking | Good reply | host forgotten | Idle | Dropped | success lambda |
| Asking | Reply isn't a task list | | Idle | As a failure | `roost--task-list-p` |
| Asking | Failure or timeout | host known | Idle, Offline, Backing off | Once per outage a message; backs off up to 60s; what it would have measured is owed, unless it was owed already, and `asked` put back | `failed` |
| Asking | Failure | host forgotten | Idle | Nothing said | `failed` |
| any end | `finish` | owed | Asking | Flag cleared, then the owed refresh runs | `finish` |
| Backing off | Quiet poll | before retry time | Backing off | Skipped | `roost-refresh` |
| Backing off | `g`, or any full refresh | | Asking | Goes anyway | `roost-refresh` |
| any | `roost-forget-host` | | same | `roost--errors`, `roost--failures` go; in-flight list dropped by I4 | `roost-forget-host` |

Illegal or refused: none.

Open: none.

Notes:
- `roost--pull-requests-asked` is stamped before the request, and put back as it was
  if the list fails or is dropped, so a poll after an outage asks GitHub.
- A full list that takes over a minute reads as Offline until the next quiet poll.
- A stopped tmux server holds the registry lock ([Registry lock](#registry-lock)):
  each poll then times out and the host reads Offline. Over SSH each leaves a helper
  blocked on `flock`.
- Roost sets no `ServerAlive` option. After a network change, requests sharing a
  control connection may attach to a master whose TCP is dead and time out one by
  one until the master gives up, minutes later. Known ssh behaviour; not proved
  here, so not a finding. `tmux-control-ssh-options` can set it.

### Cached task

Kind: implicit. Lives in: `roost--tasks`, and what is keyed alongside:
`roost--statuses`, `roost--pr-verdicts`, `roost--agent-news`, `roost--seen`,
`roost--turns-sent`, `roost--merges-reported`.
What Emacs believes of each task, and how a reply merges into it.

| State | Meaning | How you can tell |
|---|---|---|
| Absent | Never seen, or dropped from a list | No key |
| Cached | Listed or replied about | Key in `roost--tasks` |
| Went | Was cached, gone since a request began | `roost--went-p` with the request's `listed` |

Invariants:
- I1. A reply read before a task went doesn't bring it back (`roost--cache-reply`, `roost--went-p`; lists by I3 of Host refresh). Checked for `inspect`, `roost--act`, the turn reply, `roost--compose-listed`.
- I2. No reply rolls a task back: older `updatedAt` keeps the old record with the reply's measurements (`roost--newer-events`); name and look have clocks of their own (`roost--newer-name`, `roost--newer-look`).
- I3. A reply saying the task went always counts. It would not if its `updatedAt` were older, but `retire`, `discard` and `forget` all stamp `now()` last.
- I4. String order of `updatedAt` is time order. `now()` is UTC isoformat; `+` sorts before `.`, so a whole second sorts first. True while the host's clock doesn't step back.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Absent | List names it | | Cached | No news: `previous` nil, verdict `unknown` | `roost--cache-task` |
| Absent | Create replies | | Cached | Revision bumped | `roost--task-made` |
| Cached | List names it | | Cached | Merged by I2; absent measurements carried over | `roost--cache-task` |
| Cached | List lacks it | | Absent | All keyed state and its notes go | `roost--apply-snapshot` |
| Cached | Reply says retired, forgotten or discarded | | Absent | Its notes go | `roost--cache-task` |
| Cached | Host forgotten | | Absent | | `roost-forget-host` |
| Went | Reply, not saying so | `listed` | Went | Reply goes only to the command | `roost--cache-reply` |
| Went | Reply saying so | | Went | Recorded quietly | `roost--cache-reply` |

Illegal or refused: none.

Open: none. Mentioned, not findings: an `inspect` read before `P` with the same
`updatedAt` drops `pr` until the next list; a host clock stepping back holds a task
at its old status until time catches up (I4). `roost--apply-snapshot` deletes a
task's review notes when a list lacks it, so a host that answers from an empty
state directory, as with an unmounted home, deletes them; no way to reach that
from Roost alone is known.

### Attention notice

Kind: implicit. Lives in: `roost--statuses`, `roost--agent-news`,
`roost--held-notices`, `roost--notice-timer`.
Whether a status change becomes a notification, once.

| State | Meaning | How you can tell |
|---|---|---|
| Quiet | Nothing pending | `roost--statuses` equals the status |
| Inspecting | `inspect` in flight for words | `roost--agent-news` holds a fresh token |
| Held | Gathering for up to a minute | Entry in `roost--held-notices`, timer set |
| Sent | Gone | Entry dropped |

Invariants:
- I1. First sight of a task is no news (`previous` nil).
- I2. One notification per change: `roost--statuses` is set before notifying; a newer token voids an older inspection.
- I3. A held notice goes only if still true and unseen, and not on screen (`roost--notice-holds-p`).
- I4. A host dropping and coming back changes nothing here: `roost--errors` isn't read, `roost--statuses` stays, and what changed meanwhile notifies once on return. Checked.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Quiet | Status becomes ready or permission | unwatched, not just started | Inspecting | Older held one dropped | `roost--notify-attention` |
| Quiet | Becomes failed, crashed, exited | unwatched | Held | | `roost--notify-attention` |
| Quiet | First reads `prompt`, past `roost-startup-grace` | unwatched, not so when first seen | Held | Dropped if it moves on: only slow to start. `roost--statuses` holds `prompt` until it stops starting, and hooks still get the record's status | `roost--cache-task` |
| Quiet | Same status, new `Stop` | | Inspecting | `new-stop` | `roost--cache-task` |
| Inspecting | Reply or failure | token same, permission | Sent | At once | `send` |
| Inspecting | Reply or failure | token same, unseen | Held | | `send` |
| Inspecting | Reply or failure | seen, or token moved | Quiet | | `send` |
| Held | Timer | holds | Sent | One notification, most urgent first | `roost--send-notices` |
| Held | Timer | doesn't hold | Quiet | | `roost--send-notices` |
| Held | `roost--cache-task` finds it untrue | | Quiet | | `roost--cache-task` |
| Held | Seen | | Quiet | | `roost--mark-seen` |

Illegal or refused: nothing notifies while `roost-notify` is nil.

Open: none. A permission answered during its `inspect` still notifies; a request
that follows another between two polls doesn't, as only `ready` has `new-stop`.
Both need you at the terminal, where `unwatched` is false anyway.

### Seen, in Emacs

Kind: implicit. Lives in: `roost--seen`, the record's `seen`.
Whether you have seen an agent since its last event, here or in another Emacs.

| State | Meaning | How you can tell |
|---|---|---|
| Unseen | | Neither equals `updatedAt` |
| Seen here | This Emacs only | `roost--seen` equals it |
| Seen everywhere | Recorded on the host | Record's `seen` equals it |

Invariants:
- I1. Seeing an agent that waits, or a stopped one, is recorded for your other Emacs and the next session (`roost--mark-seen`). Not a working one, whose every event would send a request. What of a task waits on you goes by this, so two Emacs must agree.
- I2. Its next event unsees it, as `updatedAt` moves.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Unseen | Terminal or panel selected, Emacs focused | status ready, interrupted, error, failed, crashed, exited, stopped | Seen everywhere | `seen` sent, reply ignored | `roost--mark-seen` |
| Unseen | Same | other status | Seen here | | `roost--mark-seen` |
| Seen everywhere | Stop | it was seen | Seen everywhere | Helper carries it over | `stop` |
| any | Agent event | | Unseen | | hook |

Illegal or refused: the helper takes any non-empty `updatedAt`, even older than the
`seen` it holds, so two `seen` requests delivered out of order leave the older.
Needs one to take longer than an agent's whole turn; not a finding. A `seen` that
fails isn't sent again, so after a restart that task reads as unseen.

Open: none.

### Watching

Kind: explicit plus implicit. Lives in: `roost-watch-mode`, `roost--watch-timer`,
`roost--watching-on-demand`, `roost--last-watch`.

| State | Meaning | How you can tell |
|---|---|---|
| Off | No polls | Mode nil; sidebar says paused |
| On, focused | Polls every `roost-watch-interval` | Some frame has focus |
| On, unfocused | Polls every `roost-watch-unfocused-interval` | `roost--watch-tick` skips ticks |

Invariants:
- I1. One timer. The mode's body cancels before it makes one.
- I2. `roost--watching-on-demand` keeps its first answer through repeated `(roost-watch-mode 1)`.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Off | Dashboard, sidebar, a task made, config | | On | Timer, mode line, save hook | `roost-watch-mode` |
| On | `(roost-watch-mode 1)` again | | On | Timer restarted, nothing else | `roost-watch-mode` |
| On | Turned off | | Off | In-flight list still lands; held notices still go | `roost-watch-mode` |
| On, focused | Focus leaves | | On, unfocused | Next tick | `roost--watch-tick` |

Illegal or refused: none.

Open: none. Sound. No focus hook is needed: every reply redraws, and
`roost--redraw` notes what you are watching. Repeat timers catch up at most
`timer-max-repeats` times after sleep, and the refresh flag absorbs them.
`frame-focus-state` says `unknown` for a tty frame, which counts as focused.

### Remembered files

Kind: implicit. Lives in: `roost--hosts-loaded` with `roost--remembered-hosts` and
`roost-hosts-file`; `roost--projects-loaded` with `roost--remembered-projects` and
`roost-projects-file`; `roost--notes-loaded` with `roost--notes` and
`roost-notes-file`; `roost--file-stamps`.
Each file is read once per session. Each change here first takes up what the file
holds, if it moved, and then writes the whole list.

| State | Meaning | How you can tell |
|---|---|---|
| Unread | Not loaded | `-loaded` nil |
| In step | Memory equals the file | `roost--file-stamp` as in `roost--file-stamps` |
| Ahead | Memory holds a change a failed write left | The stamp as above, memory not as the file |
| Apart | Another Emacs wrote since | The stamp differs |

Invariants:
- I1. What you remember or write stays until you forget or send it, in either of two Emacs, and what you forget or send stays gone (`roost--hosts-as-on-file`, `roost--projects-as-on-file`, `roost--notes-as-on-file`). Each runs before a change, which then goes on what the file holds.
- I2. A file is written whole, through a new file renamed into place: nothing reads it half written, and a write that fails leaves it (`roost--write-json-list`). What a link leads to is what changes.
- I3. A file that hasn't moved says nothing: what this Emacs holds is at least as new, as after a write that failed. One gone or unreadable isn't another Emacs's doing, so what is held here stands, and the next write replaces it (`roost--read-again`).
- I4. A note still on file stays the same object here, by ID: the note box and drafts hold it. A note gone elsewhere leaves drafts here, and one edited elsewhere changes in them, and Magit shows what changed (`roost--notes-as-on-file`).
- I5. A host forgotten in another Emacs goes here at this Emacs's next write of the file, its tasks and terminals with it, unless you are using it again: no poll would ask it, and its rows would stay as they were (`roost--stop-watching`).
- I6. A stamp is of what a link leads to, and is taken before the rename, as what is there after it may be another Emacs's (`roost--file-stamp`, `roost--write-json-list`).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Unread | First use | | In step | Reads, noting the stamp | `roost--read-remembered` |
| In step | A write here | | In step | Whole list, noting the stamp | `roost--write-json-list` |
| In step | A write here fails | | Ahead | File as it was; an error reaches the command | `roost--write-json-list` |
| Ahead | A write here | | In step | Memory goes whole, the failed change with it | `roost--write-json-list` |
| In step, Ahead | A write in another Emacs | | Apart | Nothing here until this Emacs writes or starts | |
| Apart | A change here | file readable | In step | Takes up the file, applies the change, writes | `roost--read-again` |
| Apart | A change here | file unreadable | In step | Memory written, replacing the file | `roost--read-again` |

Illegal or refused: none.

Open: none. Between one Emacs's read and its rename, another's write goes: a window of
microseconds, with no lock, as nothing else would need one. A change a failed write
left, in Ahead, goes if the other Emacs then writes, as the file's word stands: the
failed write said so at the time.

## Git and the forge

What Roost works out about a task, and what it decides the task's word is. "Forge" is
GitHub through `gh` or GitLab through `glab`, and "pull request" covers GitLab's merge
requests, as the code does. The word is derived from the rest, so it comes last.

### A task's pull request

Kind: implicit, over one explicit field. Lives in: the record's `pr`
(`number`, `url`, `state`, `head`, `base`, `forge`, `mergedHead`,
`mergedBases`, `unfetched`), written by `check_pull_requests`, `rpc`'s `pr` branch
and `record_push`; what the forge lists; `worktreePr`, never recorded.

It says which pull request is the task's, and whether it merged, so that views
and retiring can go by the record without asking the forge.

| State | Meaning | How you can tell |
| --- | --- | --- |
| none | No pull request known | `recorded_pull_request` is `{}` |
| fresh | `P` just opened or found one; nothing asked since | `pr` has `number` and `url`, no `state`. Also every record from an older helper |
| open | Open as last asked, draft or not | `pr.state == "OPEN"` |
| closed | Closed unmerged as last asked | `pr.state == "CLOSED"` |
| merged at tip | Its head has all of the branch: it is the tip, or comes after it, as a commit made on the forge does | `recorded_merge_at`: `has_tip` of `pr.mergedHead`, or of `head` with `state == "MERGED"` |
| merged, commits since | Merged at a head that lacks some of the branch | `state == "MERGED"`, not `has_tip` |
| open beside a merge | Another of its pull requests merged at the tip, and an open one is shown | `state == "OPEN"`, `has_tip` of `mergedHead` |

Invariants:

- I1. A pull request is the task's only if it is the recorded one, or its head
  is a commit of the task's own, made since it started and still on its branch
  (`task_pull_requests`). Someone else's fork, an earlier task's branch of the
  same name and commits brought in by an update don't count.
- I2. A merge stays a merge while the tip stands: a later listing that no longer
  has it doesn't undo it (`record["mergedHead"]`, `mergedBases`).
- I3. A lookup never overwrites a record newer than the one it read
  (`check_pull_requests`: `stale`, a compare-and-swap under the lock).
- I4. Only a record says `merged at tip`, and retiring believes only that or an
  answer got for this request (`merged_pull_request_head`, `safe_to_delete`).
- I5. A commit on the branch is the task's own when its reflog says so, by a
  subject `own_commits` knows, or its integration branch lacks it, here and as last
  fetched from origin, so no update brought it in. A fast-forward from another
  branch counts; one from the integration branch, by any remote's name for it, or
  from a commit or an expression, as Git names one from `FETCH_HEAD`, doesn't. Fixed:
  FORGE-2.
- I6. The forge's head can be compared with the branch: one that isn't here is
  fetched by its commit, outside the lock and within the deadline, in the primary
  checkout (`fetch_head`, `fetch_heads`), for the recorded pull request only. A
  refusal is kept in `unfetched`, so a poll tries once for each head, while running
  out of time is tried again, and so does your `x` or `m`. Such a head, as on a
  fork's branch, stays unknown, as does one before Git 2.29, which can't leave
  `FETCH_HEAD` alone. Fixed: FORGE-1, FORGE-5.
- I7. Commits on the branch after what merged never count as merged: `has_tip`
  asks whether the tip is in the head, not the other way, and `record_push` leaves
  a closed or merged one's `head` alone. Retiring deletes on this word.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| none | `P`, none open | commits, clean | fresh | Push, `forge.create`, record | `pull_request`, `rpc` |
| none | `P`, one open | | fresh | Push, record it, reply with `pushed` | `pull_request` (`existing`) |
| none | Poll finds one of its own | `pushed` or recorded | open, closed or merged | Record what's shown | `check_pull_requests`, `shown_pull_request` |
| any | Poll, forge gives no answer or nothing of its own | | same | Nothing; `prStatus` left out | `task_pull_requests` -> None |
| fresh, open | Poll says OPEN | | open | `head`, `base` recorded | `check_pull_requests` |
| open | Poll says CLOSED | | closed | Measured whole, as the forge no longer says whether it conflicts | `rpc`'s `was_open` |
| closed | Poll says OPEN (reopened) | | open | | `check_pull_requests` |
| closed | Agent opens another | | open | The newer one replaces it | `shown_pull_request` |
| closed | `P` with a title | | fresh | Another opened, in its place | `rpc`, `pull_request` |
| open | Poll says MERGED at tip | | merged at tip | `mergedHead`, `mergedBases` | `check_pull_requests` |
| open | Poll says MERGED, head after tip | that head here, or fetched | merged at tip | `mergedHead` is that head | `fetch_heads`, `merged_tip` |
| open | Poll says MERGED, head not here | it doesn't come | merged, commits since | `unfetched`, tried no more | `fetch_heads` |
| open, merged | Poll: the forge's head isn't here, and hasn't failed | 5 s left | same | Fetched, or `unfetched`; with less left, the next poll tries | `fetch_heads` |
| fresh, open | `P` pushes | | same | `head` is what it pushed | `record_push` |
| merged at tip | Commit on the branch | | merged, commits since | `mergedHead` dropped at the next poll | `check_pull_requests` |
| merged, commits since | Agent opens another | | open | | `shown_pull_request` |
| merged, commits since | `P` with a title | | fresh | Another opened, in its place | `rpc`, `pull_request` |
| merged at tip | Second pull request opened at the tip | | open beside a merge | `mergedHead` kept, the open one shown | `check_pull_requests` |
| any | `retire`, `merge`, `discard`, `forget` | | gone | Record removed; a lookup in flight fails to read it and shows, not records | `check_pull_requests`' `except` |

`worktreePr` follows the same listing for the branch the worktree is on, is null
once it leaves, and is never recorded: `roost--pr-view` stands it in for the
task's own in every view. Its head isn't fetched: only the recorded pull request
passes `task_pull_requests` with a head not here, so one from that branch with a
commit made on the forge goes unfollowed until the branch has it.

A merge request GitLab rebases as it merges has a head no commit of the branch
comes before. Fetching it finds no ancestor, so it reads as merged, commits since.
By reading: no run against a GitLab server.

Illegal or refused: a lookup while `removing` skips the task. `pr` on a retired
or removing task is refused (`require_not_removing`).

Branch reuse: Roost's branch names end in six hex digits of the task's ID, so a
task's own branch can't really be reused. Reuse is possible only for a branch the
agent made (`worktreePr`), and I1 covers that: `own_commits(task, branch)`.

Open: none.

### What the forge last said

Kind: implicit. Lives in: Emacs's `prStatus`, `unpushed`, `worktreePr` in
`roost--tasks`; `checkedAt` in `prStatus`; `roost--pull-requests-asked`. Transient
on the host (`TRANSIENT`).

| State | Meaning | How you can tell |
| --- | --- | --- |
| never | Nothing asked since Emacs started | no `prStatus` |
| whole | List and review query both answered | `prStatus` has `requested`, `threads`, `mergeable`, and from GitHub `mergeState` |
| partial | List answered, review query didn't | `prStatus` has `reviewsFailed` |
| stale | Older than the agent's last event + `roost--pr-settle` | `checkedAt` too early: `roost--pr-status` is nil |
| frozen | Forge stopped answering | `prStatus` kept, `checkedAt` old, no sign |
| dropped | The record's `pr` changed without a new status | `roost--cache-task` and `roost--newer-events` drop it |

Invariants:

- I1. A status goes with the record's `pr`: when `pr` changes with no status, the
  old status goes (`roost--cache-task`).
- I2. A word goes by what the forge said after the agent's last push:
  `roost--pr-status`'s `checkedAt` test, and `checked = now()` before asking.
- I3. All forge questions end by `PULL_REQUEST_DEADLINE`, inside Emacs's wait, and
  so does fetching a head, which comes after them so as to hold none up.
- I4. A status says when its review query failed (`reviewsFailed`). Of the same pull
  request, head and base, the last status stands, whole, as when the forge doesn't
  answer (`roost--kept-reviews`): a word doesn't go for a poll and come back as news,
  and old reviews beside new checks make no word nobody said.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| never | Quiet poll, first | always, as nothing was asked | whole or partial | | `roost--refresh-host` |
| whole | Poll every `roost--pull-request-interval`, or a full refresh | | whole | | `roost--refresh-host` |
| whole | Review query fails or deadline passed | same pull request, head, base | whole | Last status stands | `pull_request_status`, `roost--kept-reviews` |
| whole | Review query fails or deadline passed | another | partial | Word and threads go until it answers: they are of other commits | same |
| whole | Forge list fails: `gh` missing, signed out, slow | | frozen | Emacs keeps it | `task_pull_requests` -> None; `roost--cache-task` |
| any | Agent event | | stale | Verdict nil until next asked, 30 s on | `roost--pr-status` |
| any | `pr` changes in a reply without a status, as after `P` pushes | | dropped | | `roost--cache-task` |

`unpushed` goes with this: with the forge's head fetched, it compares a commit made
there with the branch, so such a commit no longer holds back the word (FORGE-5).

Frozen is a design limit rather than a finding: the code and manual say Roost
goes by what the forge last said, `roost-doctor` reports a signed-out `gh`, and
nothing unsafe follows, as retiring asks again and otherwise goes by the record.
With `gh` signed out, though, a `to merge` lasts until it is back, with no sign.

Open: none.

### Pushing and opening

Kind: implicit. Lives in: `roost--pr-sending`, `roost--pr-task` (draft buffer
locals); the worktree lock held `LOCK_SH`; `branch.X.remote`.

| State | Meaning | How you can tell |
| --- | --- | --- |
| idle | | no draft |
| drafting | Draft open | a `roost-pr-mode` buffer, `roost--pr-sending` nil |
| sending | `pr` request out | `roost--pr-sending` t |
| pushing to one | `pr` with a recorded number, and no title for one closed or merged | `push_pull_request` under `store.released()` |
| opening | `pr` with none recorded, or a title and one closed or merged | `pull_request` under `store.released()` |

Invariants:

- I1. Nothing finishes the task while it pushes: `holding_worktree` `LOCK_SH`.
- I2. Pushing only ever adds: no force. A push that is not a fast-forward is
  refused by Git, in Git's words.
- I3. Opening is idempotent: `existing` is asked first, so a retry after a timeout
  or a killed helper finds it, and a poll records it if the helper died.
- I4. Create means create: "opened pull request" is said for one opened. A reply
  with `pushed`, a number or null, says it wasn't, and the draft stays. Fixed: FORGE-3.
- I5. After a push, nothing counts as unpushed that it pushed: `record_push` moves
  `head` to the commit it pushed by name, and the reply says `unpushed`. Not over a
  record that moved meanwhile, as for a later push, nor for one closed or merged:
  see [A task's pull request](#a-tasks-pull-request), I7. Fixed: FORGE-12.

Action against state of the record, in Emacs and on the host:

| Record | Next step says | `P` does | Host's `pr` does |
| --- | --- | --- | --- |
| none, ahead 0 | nothing | Not offered | Refuses: nothing to propose |
| none, ahead > 0 | `m merges it, or P opens a pull request` | Drafts | Pushes, creates |
| fresh, open, draft | `roost--pr-next-step` | Pushes new commits, opens it | `push_pull_request` |
| open, branch rewritten by its agent | `P pushes new commits to its pull request` | Git refuses the push | Error in Git's words |
| open, nothing unpushed, no word | `#12 has every commit of the task's: P opens it`, or what it waits for | Pushes nothing, opens it | `push_pull_request` |
| open, forge has a commit that didn't come | `P pushes new commits to its pull request`; it has none | Fetches, "up to date", opens it | `unpushed` compares |
| closed, ahead > 0 | `m merges it, or P opens a pull request` | Drafts another (`C-u`: opens the closed one) | With a title, opens another; without, pushes |
| closed, ahead 0 or unknown | nothing | Opens the closed one | |
| merged, commits since | `merged, but not its commits since: m merges them, or P opens a pull request` | Drafts another (`C-u`: opens the merged one) | With a title, opens another; without, pushes |
| merged at tip | `x retires it` | Opens it | |
| worktree on another branch | Says so | Refused (`check_worktree`) | Refused |
| agent at work | nothing | As open | Pushes committed work; refuses uncommitted changes |

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| idle | `P` | no recorded PR, or `roost--pr-spent-p` | drafting | | `roost-pr`, `roost--pr-draft` |
| drafting | `C-c C-c` | a title, not sending | sending | | `roost-pr-submit` |
| sending | Good reply | | idle | Draft closes, "opened pull request" | `roost-pr-submit` |
| sending | Good reply with `pushed` | | drafting | Text kept, the draft says it pushed to that one | `roost-pr-submit` |
| sending | Refused, dropped, timed out | | drafting | Text kept, error in the draft | `roost-pr-submit` failure |
| sending | Nothing reached the host | | drafting | | its `condition-case` |
| drafting | Poll records an open PR meanwhile | | drafting | Create will then push only, and say so | |

Flags: `roost--pr-sending` is cleared on each exit: good reply
(buffer goes, or stays for a push), failure, a signal before the request, quit. A
live draft can always be cancelled.

Open: none.

### Landed

Kind: derived. Lives in: `landed` from `landed()`; `roost--landed`.

| State | Meaning | How you can tell |
| --- | --- | --- |
| not landed | Host says no | `(landed)` |
| landed, measured | Host says yes, with statistics | `landed` true and `dirty` present |
| unknown | The forge says merged, statistics not in | no `landed`, or no `dirty`, and `roost--pr-state` merged |

Invariants:

- I1. Landed implies retiring loses no commit. Holds: `safe_to_delete` accepts
  every tip `landed` does, and also a task that never committed.
- I2. A task that never committed hasn't landed.
- I3 (manual, "Work that is merged"). Only commits after the merge keep it from
  saying so. Fixed: FORGE-1, where the branch was behind what merged, and FORGE-2,
  where the merge was never found. A head that can't be fetched still reads as
  commits since.

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| not landed | Poll records a merge at the tip, or after it | | landed | `recorded_merge_at`, `has_tip` |
| not landed | Tip reaches the integration branch | `committed_on` | landed | `landed` |
| landed | New commit, tip moves | | not landed | `landed`, at the next measurement |
| any | Reflog gone or empty | | not landed unless recorded | `own_commits` -> True |

`rpc`'s `list` measures a task whole when a merge arrives, so `landed` never comes
without `dirty` from that path, and `task["landed"] = False` covers the others.

Retiring fetches a merged head no poll has, as `merged_pull_request_head` asks for
itself, and tries one a poll gave up on. Its remote branch goes under a lease on the
head that merged, so commits pushed there since stay.

Open: none.

### Task measurement

Kind: implicit. Lives in: the fields of `roost--measured-fields` in a cached task,
`roost--task-states`, the `changed` list in the success lambda,
`roost--measures-owed`.
Quiet polls measure nothing; a task must be measured after it changes, or views
say what is no longer so.

| State | Meaning | How you can tell |
|---|---|---|
| Unmeasured | Never measured here | No `conflicts` field. `landed` isn't enough: a poll that asks GitHub says it of what it asked about, unmeasured |
| Measured | Fields are as new as its last change | `gitStamp` and `updatedAt` as when measured |
| Owed | Changed since, measurement asked | Its ID is in pending, in a list in flight, or in `roost--measures-owed` |

Invariants:
- I1. A change any reply brings gets a measurement, unless that reply measured it. A list dropped, failed or never started owes it to the next good poll, and one that fails then is given up: the next change, or `g`, asks again.
- I6. Measuring goes at the pace of polls: a quiet poll's changes go right after it, and what a list of some tasks brings of others goes after the next poll, or two busy agents would be measured back to back.
- I2. What waits on you isn't told, or reported, until the task is measured (`roost--judged-p`).
- I3. A stale list reply never overwrites a newer action: `roost--revisions`.
- I4. An open pull request's conflict is the forge's word, otherwise Git's.
- I5. `conflicts` is left to Git only where it means something: null with the
  worktree on another branch or a pull request open, `[]` once landed.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Unmeasured | Quiet poll first sees it | | Owed | Every task of a first poll is `changed` | success lambda |
| Measured | Quiet poll sees its state move | | Owed | ID pended | success lambda |
| Owed | List with its ID replies | revision same | Measured | | `roost--apply-snapshot` |
| Owed | That list dropped as stale | | Owed | Into `roost--measures-owed`, for the next poll | success lambda |
| Owed | That list fails, or can't start | not owed before | Owed | Same | `failed`, `roost--refresh-host` |
| Owed | That list fails | owed before | Measured, in name | Given up, so a list too slow ever to answer holds up no polls | `failed` |
| Measured | IDs list for another task brings its event | | Owed | Same | success lambda |
| Owed | A good quiet poll | | Owed | Asks to measure them, right after | success lambda |
| Owed | A full refresh | | Owed | It covers them | `roost--refresh-host` |

Conflicts:

| Case | `conflicts` | Code |
| --- | --- | --- |
| No integration branch | null | `add_git_stats` |
| Pull request open | null: `mergeable` says | same |
| Worktree on another branch | null | same |
| Landed | `[]` | same |
| Git before 2.38, branch gone | null | `merge_conflicts` |
| One is before the other | `[]` | same |
| Worktree gone | null, with what else it measures of the worktree: left out, Emacs would keep what it had | `add_git_stats` |

Stamp: index, `logs/HEAD` of the worktree, and the integration branch's reflog. It
moves for commits, staging, resets, `m` and a pull in the primary checkout. Edits
not staged leave it, which is why a merge or open pull request found by a poll is
measured whole. With `core.logAllRefUpdates` false the integration branch's part
never moves.

`update` is a field of one reply: `{conflicts, changed, resolved}`, never saved
(`TRANSIENT`), read by `roost-update`, which then asks for a full refresh.

Illegal or refused: none.

Open: none.

### Since you last looked

Kind: implicit. Lives in: the record's `looked` (`commit`, `head`, `base`, `at`,
`since`); `sinceLooked` (transient); a commit no ref holds.

| State | Meaning | How you can tell |
| --- | --- | --- |
| never | | no `looked` |
| looked, measured | `sinceLooked.at == looked.at` | |
| looked, unmeasured | A newer look than the measurement | `at`s differ: Emacs shows nothing |
| gone | Git pruned what it held | `look_start` None: `sinceLooked` null, the panel says nothing |

Invariants:

- I1. Another Emacs's look stands: `record_look` is a compare-and-swap on `looked`.
- I2. A failed comparison keeps the look before.
- I3. A late reply can't bring back an older look, or lose a newer one
  (`roost--newer-look`, both ways).
- I4. Commits made of what you saw don't count: it compares content.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| any | `r`, `v`, `D`, notes with `@` | | looked, measured | Snapshot, then record | `prepare_look`, `record_look` |
| any | `D` with an untracked file | | same | `LeftOut`: the look stands | `look` |
| any | Send fails | | same | `prepared` not recorded | `rpc` |
| looked | Measured | | looked, measured | | `since_looked` |
| looked | `gc --prune` | | gone | Falls back on `head`, then none | `look_start` |
| any | Task removing or gone | | refused | | `prepare_look`, `record_look` |

Checked and sound. Racing looks, a look in flight as the task retires, a merge under
way, and an update between looks all behave.

Open: none.

### Verdict and turn

Kind: derived, then recorded. Lives in: `roost--pr-verdict`, `roost--turn`; the
record's `turn`, one of `TURNS` or absent; `roost--turns-sent`; the history.

| State | Meaning | How you can tell |
| --- | --- | --- |
| none | | `roost--turn` nil |
| `ci failed`, `comments`, `to merge`, `conflicts` | The word, once you've seen the agent | `roost--turn` |
| sent | Told to the host, not yet in its record | `roost--turns-sent` |
| noted | Record and Emacs agree | `turn` equal |

Invariants:

- I1. Only Emacs judges; the host only notes (`turn`).
- I2. `turn` isn't an agent event: `updatedAt` stays.
- I3. Nothing is told until the task is measured and the forge has spoken
  (`roost--judged-p`), or a turn would seem to end at every restart.
- I4. `roost--turns-sent` empties on every reply, and if the request can't start, so a failure is sent again.
- I5. Every Emacs on a host works out the same turn, as what you have seen, a
  stopped task's too, goes to the host.

Inputs of the verdict, all needed: agent not `starting`, `running`, `background`,
`permission`; `checkedAt` past the last event plus 30 s; status head equal to the
recorded head; `unpushed == 0`; not dirty; not merging; no agent work left. Then
failing and due, else threads and due, else all checks passed with no threads, no
reviews asked, none refused, `mergeable` MERGEABLE, and `mergeState`, where GitHub
gives it, neither BLOCKED nor BEHIND, which the next step names as what it waits for.

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| none | Verdict appears | seen, not merged | turn | `roost--turn` |
| turn | Agent starts, event, commit, PR moves | | none | same |
| any | `roost--turn` differs from the record | measured, status known | sent | `roost--report-turn` |
| sent | Reply | | noted | |
| sent | Failure | | none; sent again | |
| noted | Another Emacs changes it | | sent, by the next poll | |

No Emacs running, a turn stays in the record; the history counts it, and the time
away rule covers it.

Open: none.

### News of a turn

Kind: implicit. Lives in: `roost--pr-verdicts`; `roost--held-notices`,
`roost--notice-timer`.

| State | Meaning | How you can tell |
| --- | --- | --- |
| unknown | Roost can't tell yet: `roost--judged-p` isn't so | `roost--pr-verdicts` has no entry |
| known nil | | entry nil |
| known turn | | entry is the turn |
| held | Gathering for 60 s | a notice with no `:recorded` |

Invariants:

- I1 (comment in `roost--cache-task`). What was there when Roost first measured the
  task is no news. A quiet list says nothing of what waits, so what it says is no
  verdict.
- I2. Nor one that comes as you stop its agent, or while you watch it.
- I3. One that's so no longer doesn't go.
- I4. The same state isn't news twice: a failed review query takes nothing back.

| From | Event | Guard | To | Effect | Code |
| --- | --- | --- | --- | --- | --- |
| unknown | Cached, not judged, as with a review query failed and no status to keep | | unknown | Nothing said | `roost--cache-task` |
| unknown | First judged | | known | Nothing said | `roost--cache-task` |
| known nil | Turn appears | not watched, not just stopped | known turn, held | | same |
| held | 60 s | still so, unseen, unwatched | gone | Notified | `roost--send-notices` |
| held | Not so any more | | gone | Dropped | `roost--notice-still-p` |
| known turn | Turn goes, or the pull request changes and is not judged yet | | known nil | So the new one's turn is news | `roost--cache-task` |

`roost--news-turn` ignores `merged`: a task whose tip is in its integration branch
with a pull request still open and failing notifies `ci failed` and reads `merged`.
That is true of the pull request, and clears when it closes.

Open: none.

### Merges reported

Kind: implicit. Lives in: `roost--merges-reported`, by task key, of `(COMMIT . BRANCH)`.
It keeps `roost-task-merged-functions` to once for each merge.

Invariants:

- I1. Once per commit and branch, whichever of `m` and a poll sees it first.
- I2. A merge there when Roost first saw the task runs no hook.

| From | Event | Guard | To | Code |
| --- | --- | --- | --- | --- |
| absent | `roost--pr-merges` gains one | `old` | reported, hook runs | `roost--cache-task` |
| absent | The same | no `old` | reported, quietly | same |
| reported | Seen again | | same | `roost--report-merge` |
| absent | `m` succeeds | | reported, hook runs | `roost-merge-retire` |

Checked: survives a retire reply, which is why `roost--cache-task` leaves it. Not
cleared by `roost-forget-host`, which is harmless as IDs aren't reused. A pull request
merged with a commit made on the forge is one merge, at its head, whenever that came:
`mergedHead` is that head, not the tip.

Open: none.

### The word

Kind: derived. Lives in: `roost--display-status`, `roost--attention-status`,
`roost--row-word`, `roost--waiting-p`, `roost--attention-rank`.

Precedence: offline, merged, pull request's turn, conflicts, then `roost--status-name`.
Then `starting` past `roost-startup-grace` is `prompt`, and `ready` or `interrupted`
seen is `idle`, which rows show as `seen`.

Enumerated: 329,472 inputs, every combination of 13 agent states, seen, 11 pull
request states, `unpushed` (0, 2, unknown), dirty, merging, agent work, other
branch, worktree gone, `landed` (absent, nil, t), conflicts and offline, and
grouped by what each view says (234 distinct results).

| Word | Waits | Inputs | `n` | Mode line, sidebar count | Notified | Dot |
| --- | --- | --- | --- | --- | --- | --- |
| `permission` | Yes, first | status | Yes | Yes | At once | Colour |
| `starting`, held | Yes | past grace | Yes | Yes | Once, held to go with others, unless it moves on | Colour |
| `starting` | No | | No | No | No | Dim |
| `ready` | Until seen | status, unseen | Yes | Yes | Yes | Colour |
| `interrupted` | Until seen | `lastEvent` | Yes | Yes | Yes | Colour |
| `error`, `failed`, `crashed` | Until seen | status | Yes | Yes | Yes | Colour, after too |
| `exited` | Until seen | status | Yes | Yes | Yes | Dim |
| `conflicts` | Once seen | see 5 | Yes | Yes | Yes | Colour |
| `to merge`, `ci failed`, `comments` | Once seen | see 7 | Yes | Yes | Yes | Colour |
| `running`, `background` | No | status | No | No | No | Dim |
| `stopped` | No | status | No | No | No | Dim |
| `merged` | No | see `roost--merged-p` | No | No | No | Dim |
| `offline` | No | host | No | No | No | Dim |
| `seen` | No | ready, seen | No | No | No | Dim |

Invariants:

- I1. Each input gives one word. Holds: it is a function, and every word is one
  in the manual's table.
- I2. `n`, the mode line and the sidebar's count agree: all are `roost--waiting-p`,
  and the blocked are a subset. Holds on every input.
- I3. Every waiting word has a next step. Holds on every input.
- I4. `roost--history-waiting-p` agrees with `roost--waiting-p`. Holds, but for
  `prompt`, which `roost--history-spans` handles, and offline.
- I5. `roost--turn` is the word whenever the word is a turn. Holds.
- I6. The manual's "a notification announces" holds for each waiting word.
- I7. The manual's "the dot ... is dim when the task waits for nothing", but for one
  that failed, crashed or hit an error, which keeps its colour once seen. The reverse
  isn't promised: an `exited` agent you haven't seen waits on a dim dot.

Words the manual doesn't quite cover, all as designed by comments in the code:
a stopped task you hadn't seen stays `stopped`, not `merged` or `to merge`, until
you open it, and a failed or crashed agent you've seen stays so rather than
`conflicts` or `merged`, though it does show `ci failed`.

The word goes by inputs, so wrong inputs give a wrong word. A review that requests
changes with no thread open gives no word; the manual
promises none, and the next step says only that `P` pushes new commits.

Open: none.

## What you are doing in Emacs

Every function named here is in `roost.el`, unless it says otherwise.

### The new task draft

Kind: implicit. Lives in: the buffer `*roost new task*`; `roost--compose-submitting`,
`roost--draft-note`, `roost--compose-fields`, `roost--compose-timer`,
`roost--compose-changing-shown`, `roost--compose-body`.
One draft at a time, found by name. Its fields are read-only text above a marker.

| State | Meaning | How you can tell |
|---|---|---|
| Absent | No draft | no buffer |
| Editing | Yours to change | submitting nil, note nil |
| Asking | `C-c C-c` pressed; a question about the setup command is open | submitting t, no request |
| Creating | Request in flight | submitting t, note "Creating…" |
| Refused | The host said no, or the connection dropped | submitting nil, note "Could not create…" |
| NoReply | Timed out; the task may be made | submitting nil, note "No reply…" |
| Closing | Task made, held for the minibuffer | submitting as it was, task cached |

Invariants:
- I1. A flag says Creating only while a request is in flight or a question is open.
  (`left-behind` rule of `test/roost-sweep-late.el`.)
- I2. A draft is kept if creation fails. (Docstring of `roost-compose-submit`.)
- I3. A draft closes only for what it says now: what the request that made the task
  said, as `roost--compose-what` has it. That is this request, or, when its host says
  an earlier one made it (`alreadyMade`) or a poll finds it, what it first asked with
  that ID. Anything else is yours. A draft that was refused, changed, then lost a
  reply, can stay though it says what was made: it says so, and costs a `C-c C-k`.
- I4. The prompt is what you wrote: Roost's redraws of the fields leave it alone, and
  undo goes on working, as they shift each position it holds by what they moved
  (`roost--shift-undo`).
- I5. An untouched draft follows the context; a written one keeps its text, and its
  project unless you click another and nothing ties it there: files it quotes, a task
  it forks, an issue it starts from (`roost--compose-tied`). (Comment in `roost--compose`.)
- I6. "Roost created NAME" names the task as made, by its own name. A draft that says
  otherwise says what was made from what.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Absent | `roost--compose` | | Editing | buffer, fields, seed | `roost--compose` |
| Editing | `roost--compose` | prompt empty, or fork | Editing | fields replaced | `roost--compose` |
| Editing | `roost--compose` | prompt written | Editing | fields kept; a seed is dropped, and a DIRECTORY with it | `roost--compose` |
| Editing | `roost--compose`, a DIRECTORY and no seed, as a click on a project | prompt written | Editing | moves there, or says why it stays | `roost--compose`, `roost--compose-tied` |
| Editing | edit | | Editing | idle timer redraws fields | `roost--compose-changed` |
| Editing | a poll changes who touches a quoted file | | Editing | redraw | `roost--compose-redraw-changing` |
| Editing | `C-c C-c` | no project or name | Editing | user-error | `roost-compose-submit` |
| Editing | `C-c C-c` | question left open | Editing | quit it, submit from a timer | `roost--quit-questions-here` |
| Editing | `C-c C-c` | setup command risky | Asking | asks | `roost--project-value` |
| Editing | `C-c C-c` | | Creating | ID kept or made, request | `roost-compose-submit` |
| Asking | answered | | Creating | request | `roost--create-task` |
| Asking | `C-g` or error | | Editing | flag and note cleared | `condition-case` in `roost-compose-submit` |
| Creating | `C-c C-c` | | Creating | user-error "Already creating" | `roost-compose-submit` |
| Creating | good reply | no minibuffer, says what the task does | Absent | Org link, close, redraw, open if you stayed | `roost--task-made`, `roost--compose-made` |
| Creating | good reply | no minibuffer, says otherwise now | Editing | Org link, note says what was made; ID forgotten, nothing opens | `roost--compose-made` |
| Creating | good reply | minibuffer open | Closing | task cached | `roost--when-out-of-minibuffer` |
| Closing | minibuffer ends | | Absent or Editing | as above | `roost--task-made` |
| Creating, Closing | Org link signals | | as if it hadn't | says so | `roost--compose-made` |
| Creating | failure | not `roost-no-reply` | Refused | note | `roost--draft-error` |
| Creating | failure | `roost-no-reply` | NoReply | remember host, watch, note | `roost-compose-submit` |
| Creating | draft killed | | Absent | request goes on; task made, not opened | `roost--task-made` |
| Refused, NoReply | `C-c C-c` | same project | Creating | same ID | `roost-compose-submit` |
| Refused, NoReply | `C-c C-c` | project changed | Creating | new ID | `roost-compose-submit` |
| Refused, NoReply | poll lists the ID | says what it first asked | Absent | closes; opens if you are in it | `roost--compose-listed` |
| Refused, NoReply | poll lists the ID | says otherwise now, its project too | Editing | note says what was made; ID forgotten | `roost--compose-listed`, `roost--compose-made` |
| any | `C-c C-k` | prompt empty or yes | Absent | `quit-window t` | `roost-compose-cancel` |

Illegal or refused: `C-c C-c` in Creating. While busy the header has no buttons, so a
hand on the mouse has no Cancel; `C-c C-k` works. Fields can still be changed in
Creating and text typed there; neither is refused.

Open: none.

### The creation ID

Kind: implicit. Lives in: `roost--compose-asked` (DIRECTORY ID), the host's
`createId` field, `creating/ID.lock` and creation notes under its state directory.
It lets a draft ask again without making a second task.

| State | Meaning | How you can tell |
|---|---|---|
| None | Never asked | `roost--compose-asked` nil |
| Asked, unknown | Emacs doesn't know what became of it | Refused or NoReply |
| Being made | The host holds the lock | lock file held, note present |
| Made | A record has `createId` | listed |
| Undone | Creation failed | no record, or `failed` with `createId` popped |

Invariants:
- I1. One ID makes at most one task. (`create`, `made_for` in the helper;
  `test_asking_again_for_a_task_returns_the_one_made`.)
- I2. A second request waits for the first. (`asking_for`.)
- I3. A failed creation can be asked for again. (`abandon` pops `createId`.)
- I4. The ID is kept while the project is the same, so the task it finds may have been
  made from what the draft said first. Its host says so (`alreadyMade`, of one reply),
  the draft compares that with what it says now, and an ID that found something else
  is forgotten: asked again, it is another task.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| None | submit | | Asked | new ID | `roost-compose-submit` |
| Asked | submit | project same | Asked | same ID, whatever else changed; the draft then compares what comes | `roost-compose-submit` |
| Asked | task comes, draft says otherwise | | None | | `roost--compose-made` |
| Asked | submit | project differs | Asked | new ID; a task from the old one stays | `roost-compose-submit` |
| Asked | host: not seen | | Being made | `make_task` | `create` in the helper |
| Asked | host: seen | | Made | answers with the old task, ignoring the request | `made_for` |
| Being made | second request | | waits | | `asking_for` |
| Being made | failure | | Undone | | `abandon` |
| Made | task retired | | none on host | a retry makes it anew | `store.remove` |
| any | draft closes | | None | buffer-local goes with it | |

Checked: `random` is seeded differently at each start, so IDs don't repeat across
restarts. A refused create records nothing, so retrying with a fixed base works.

Open: none.

### The send ID

Kind: implicit. Lives in: `roost--send-asked` (TEXT . ID) in a draft, a hash of a note's
ID and text for a note sent alone, the record's `sendIds`.
It lets a prompt be asked for again without reaching its agent twice.

| State | Meaning | How you can tell |
|---|---|---|
| None | Never asked | `roost--send-asked` nil |
| Asked, unknown | Emacs doesn't know what became of it | draft Failed |
| Pasted | Its host pasted it | record's `sendIds` holds this ID |

Invariants:
- I1. One ID pastes once: `send` reads the record and writes it under the registry lock,
  so a retry queued behind the first finds it. Written after the paste: a kill between
  the two pastes again, and a prompt never pasted is never said to have gone.
- I2. A record holds the last 16 IDs (`SEND_IDS_KEPT`), as a note or a draft can go
  between a lost reply and asking again. A record from an older helper has none, and
  sends.
- I3. Another text is another prompt: a new ID. `roost--send-asked` goes when a draft
  keeps what you wrote since.
- I4. Refused, nothing is recorded, so the same ID goes once it can.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| None | submit | | Asked | new ID | `roost-send-submit` |
| Asked | submit | same text | Asked | same ID | `roost-send-submit` |
| Asked | submit | text changed | Asked | new ID | `roost-send-submit` |
| Asked | host: not among its IDs | | Pasted | pastes, records | `send` in the helper |
| Asked | host: among its IDs | | Pasted | pastes nothing, `alreadySent`; records no look | `send`, `rpc` in the helper |
| Asked | host refuses | | Asked | nothing recorded | `send` in the helper |
| any | draft closes | | None | | |

`alreadySent` is of one reply: `roost--act` says "Already sent to X", and the cache
leaves it out. What `roost-send` sends from code, as for conflicts, has no ID.

Open: none.

### The prompt draft

Kind: implicit. Lives in: a buffer per task, found by `roost--draft-buffer`;
`roost--send-task`, `roost--send-sending`, `roost--send-notes`, `roost--send-asked`,
`roost--draft-note`.

| State | Meaning | How you can tell |
|---|---|---|
| Absent | No draft | |
| Editing | Yours | sending nil |
| Asking | "send anyway?" is open | sending t, no request |
| Sending | Request in flight | sending t |
| Failed | Refused, dropped or no reply | sending nil, note "Could not send…" |
| Closing | Sent, held for the minibuffer | sending t, notes cleared |

Invariants:
- I1. A draft is kept if sending fails. (Docstring of `roost-send-submit`.)
- I2. While the agent may be at a prompt, Roost asks first. (Docstring of `roost-send`.)
  `roost--send-task` is a copy from when the draft last opened, so each reader takes
  the task as listed now (`roost--as-listed`).
- I3. Notes in the draft are cleared once it is sent, if the draft held them as they
  are and they are as they went (`roost--send-notes-going`).
- I4. A prompt reaches the agent once: [The send ID](#the-send-id).
- I5. What the header says of asking again holds. After no reply it says the prompt may
  have gone, that unchanged, asking again sends it only if it didn't, and that edited it
  goes as a new prompt, with an ID of its own.
- I6. A draft closes only for what it sent, all of it, though you have narrowed it, as
  it is once you are out of the minibuffer. What you wrote since stays, without what
  went if that is all still there.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Absent | `roost--send-draft` | | Editing | notes follow | `roost--send-draft` |
| Editing | `roost--send-draft` | | Editing | `roost--send-task` taken up again, new notes added | `roost--send-draft` |
| Sending | `roost--send-draft` | | Sending | note cleared, text added, which then stays | `roost--send-draft` |
| Editing, Failed | `C-c C-c` | empty, or attachment copying, failed or stale | same | user-error | `roost-send-submit` |
| Editing, Failed | `C-c C-c` | status starting or permission, as listed now | Asking | yes-or-no-p | `roost--send-text` |
| Editing, Failed | `C-c C-c` | | Sending | request | `roost--send-text` |
| Asking | yes | | Sending | `force` | `roost--send-text` |
| Asking | no, `C-g` | | Editing | flag cleared | `condition-case` |
| Sending | `C-c C-c` | | Sending | user-error "Already sending" | `roost-send-submit` |
| Sending | good reply | says what it sent | Absent | notes removed, close | `roost-send-submit` |
| Sending | good reply | says more or otherwise now | Editing | what went leaves it, if whole; notes removed; note says so | `roost--send-kept` |
| Sending | saving notes signals | | as if it hadn't | says so | `roost-send-submit` |
| Sending | failure | | Failed | blank lines trimmed unless edited since; note | `roost-send-submit` |
| Sending | killed | | Absent | notes stay until a good reply | |
| any | `C-c C-k` | empty or yes | Absent | `quit-window t` | `roost-send-cancel` |
| any | another task takes the frame | | as it was, hidden | [Drafts set aside](#drafts-set-aside) | `roost--set-aside-drafts` |

Illegal or refused: as in the table. The host refuses a task gone, an agent not
running, a control character, and `starting` or `permission` without `force`.

Open: none.

### The pull request draft

Kind: implicit. Lives in: `roost--pr-task`, `roost--pr-sending`, `roost--draft-note`.
As [The prompt draft](#the-prompt-draft), without the question and the notes.

Invariants:
- I1. The text is kept if creation fails. (Docstring of `roost-pr-submit`.)
- I2. "opened pull request" means this draft opened it. A task with one open by
  then gets a push, and the draft stays, with the text, and says so. Fixed: VIEWS-9.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Editing | `C-c C-c` | no title | Editing | user-error | `roost-pr-submit` |
| Editing | `C-c C-c` | | Sending | request | `roost-pr-submit` |
| Sending | good reply | | Absent | close, "opened pull request" | `roost-pr-submit` |
| Sending | good reply with `pushed` | | Editing | text kept, the note says it pushed to that one | `roost-pr-submit` |
| Sending | good reply | text changed since it went | Editing | text kept, the note says it opened one first | `roost-pr-submit` |
| Sending | failure | | Failed | note | `roost-pr-submit` |
| Sending | `quit` or error at once | | Editing | flag cleared | `condition-case` |

A retry after a lost reply is safe here: the record has its pull request, so the host
pushes, or GitHub refuses a second.

Open: none.

### A review note

Kind: implicit. Lives in: `roost--notes`, `roost--notes-loaded`, `roost-notes-file`,
`roost--send-notes` in each draft, `roost--notes-sending`, overlays in Magit.

| State | Meaning | How you can tell |
|---|---|---|
| Unsent | In `roost--notes` | |
| In a draft | Also in a draft's `roost--send-notes` | |
| Going alone | ID in `roost--notes-sending` | |
| Going in a draft | In a draft with `roost--send-sending` | no field of its own |
| Gone | Out of `roost--notes` | |

Invariants:
- I1. A note leaves only by being sent, discarded by you, or going with its task.
  (Manual, "Review notes".)
- I2. A note edited while it was being sent stays, with your edit, alone or in a draft,
  and a draft on its way keeps saying what it sent. (Docstring of `roost-note-send`.)
- I3. One sent at a time. (`roost--notes-sending`.) Not across machines: a note in a
  draft going, and the same note sent alone, go twice. Seen by reading; the window is
  the reply's flight, so not a finding.
- I4. `roost-notes-file` holds your notes, from two Emacs too ([Remembered files](#remembered-files)).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| — | save in the box | task listed | Unsent | saved to file | `roost--note-save` |
| Unsent | `roost--send-draft` | | In a draft | text added | `roost--send-draft` |
| In a draft | text deleted by hand | whole draft empty | Unsent | comes back on reopening | `roost--send-draft` |
| In a draft | text deleted or changed by hand | rest of the draft stays | In a draft | counted, but sending passes it over | `roost--send-notes-going` |
| In a draft | note edited in the box | draft's text unchanged | In a draft | draft follows | `roost--update-drafts` |
| In a draft | note edited in the box | you changed it there | Unsent | draft keeps yours | `roost--update-drafts` |
| In a draft | draft sent | draft holds it as it is | Going in a draft | | `roost-send-submit` |
| In a draft | draft sent | draft doesn't | Unsent | | `roost--send-notes-going` |
| Going in a draft | good reply | text as sent | Gone | | `roost-send-submit` |
| Going in a draft | good reply | edited since | Unsent | | `roost-send-submit` |
| Going in a draft | failure | | In a draft | | |
| Unsent | `roost-note-send` | | Going alone | | `roost-note-send` |
| Going alone | good reply | text as sent | Gone | | `roost-note-send` |
| Going alone | good reply | edited since | Unsent | | `roost-note-send` |
| Going alone | failure, `C-g`, no | | Unsent | | `roost-note-send` |
| any | saved empty, discard | | Gone | | `roost--note-save`, `roost-discard-notes` |
| any | task retired, or a listing lacks it | | Gone | | `roost--cache-task`, `roost--apply-snapshot` |

Illegal or refused: saving for a task Roost no longer has, with the box left open so
the text isn't lost.
Open: none.

### The note box

Kind: implicit. Lives in: `roost--note-box`, the buffer `*roost note*`, a child frame.
One box at a time.

| State | Meaning | How you can tell |
|---|---|---|
| Closed | | `roost--note-box` nil |
| Open | Writing | plist set, buffer live |

Invariants:
- I1. A note being written elsewhere is kept. (Comment in `roost-note`.)
- I2. The plist and the buffer go together. (`roost--note-box-killed`.)

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Closed | `roost-note`, a click | | Open | | `roost--note-box` |
| Open | `roost-note` elsewhere | | Open | old one saved, if its task is listed | `roost--note-box-set-aside` |
| Open | save | task listed | Closed | saved | `roost-note-box-save` |
| Open | save | task gone | Open | user-error | `roost-note-box-save` |
| Open | cancel | | Closed | | `roost-note-box-cancel` |
| Open | buffer killed | | Closed | | `roost--note-box-killed` |
| Open | its frame or parent deleted | | Closed | saved | `roost--note-box-frame-deleted` |
| Open | Magit buffer killed | | Closed | saved | `roost--note-box-place` |
| Open | note sent or removed meanwhile | | Open | saving makes a new note from its place | `roost--note-save` |

Open: none. Each exit clears the plist and its hooks. Sound by reading and by the
existing tests.

### The note button

Kind: implicit. Lives in: `roost--note-button`, `roost--note-mouse-timer`.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Hidden | mouse over a diff line | | Shown | timer at the fast interval | `roost--note-show-button` |
| Shown | rests for 8 looks | | Shown, slow | timer at 1 s | `roost--note-follow-mouse` |
| Shown, slow | moves | | Shown | fast | `roost--note-follow-mouse` |
| Shown | off the lines | | Hidden | timer cancelled | `roost--note-follow-mouse` |

Open: none.

### An attachment

Kind: implicit. Lives in: the text property `roost-attachment-state`,
`roost--attachments-copying`, `roost--attachment-count`.

| State | Meaning | How you can tell |
|---|---|---|
| Copying | Placeholder, copy under way | `copying`, ID in the list |
| In | Its path is in the draft | no property |
| Failed | "[Not attached…]" | `failed` |
| Stale | Placeholder of a copy done, as undo brings back | `copying`, ID not in the list |

Invariants:
- I1. A draft isn't sent with a copy under way, failed or stale. (`roost-send-submit`.)
- I2. Each copy of a placeholder is filled in. (`roost--attachment-done`.)

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| — | attach | | Copying | placeholder, request | `roost--send-attach-start` |
| — | attach signals at once | | — | placeholder deleted | `roost--send-attach-start` |
| Copying | good reply | draft live | In | | `roost--attachment-done` |
| Copying | failure | draft live | Failed | | `roost--attachment-done` |
| Copying | reply | draft killed | — | file stays on the host until the task goes | `roost--attachment-done` |
| Copying | text deleted | | — | reply finds none | `roost--attachment-done` |
| In | undo | | Stale | submit refuses | `roost--attachment-states` |

Attaching during Sending isn't refused, and goes with the draft: text typed after
sending again.
Open: none of its own.

### Opening a task

Kind: implicit. Lives in: the closure of `roost--open` (`generation`, `window`,
`shown`, `place`, `frame`, `listed`), `roost--opening-timer`.

| State | Meaning | How you can tell |
|---|---|---|
| Asking the host | `inspect` in flight | generation current, timer pending |
| Held | Replied; a minibuffer is open | closure on `minibuffer-exit-hook` |
| Shown | `roost--display-task` ran | |
| Dropped | You moved on, or it went | a message says which |
| Offering | Window gone: "Resume?" | y-or-n-p from a timer |

Invariants:
- I1. Only the latest open shows. (`roost--open-generation`.)
- I2. It shows only if you are still where you asked. (`roost--still-there-p`.)
- I3. A task that went doesn't come back. (`roost--went-p`, `roost--cache-reply`.)
- I4. Connecting to an ended session starts an empty one, so Roost asks its host first.
  (Comment in `roost--restore-terminal`.) A reply that was held is old by the time you
  are out, however long you took, so it asks again.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| — | `roost--open` | | Asking the host | generation bumped, timer | `roost--open` |
| Asking the host | 0.5 s | generation current | same | "opening…" | `roost--open` |
| Asking the host | good reply | no minibuffer, wanted | Shown | | `roost--open` |
| Asking the host | good reply | minibuffer | Held | reply cached | `roost--when-out-of-minibuffer` |
| Held | minibuffer ends | wanted | Asking the host | anew, from where you are then | `roost--open` |
| Held, Asking | newer open | | Dropped | silently | `still-wanted` |
| Held, Asking | you moved | | Dropped | "didn't open…" | `still-wanted` |
| Held, Asking | task went | | Dropped | "didn't open…" | `still-wanted` |
| Asking the host | refused, window gone | no VIEW | Offering | from a timer | `roost--open` |
| Asking the host | refused, window gone | VIEW | Shown | the view alone | `roost--open` |
| Asking the host | refused otherwise | | Dropped | says why | `roost--open` |
| Offering | yes | | [Resuming](#resuming) | | `roost--open` |

Open: VIEWS-13.

### The open generation

Kind: implicit. Lives in: `roost--open-generation`.
A counter: each navigation bumps it, and a reply compares what it captured.

| Bumps | Compares |
|---|---|
| `roost--open` | its own `still-wanted`, `opening` timer, offer |
| `roost--you-stay` (create, resume, views) | its closure |
| `roost--look-then` | `roost--look-then`'s `open` |
| `roost--open-from-notification` | its idle timer |
| `roost--quit-questions-left-open` | its timer |
| `roost--go-back` | stops a task still opening |
| — | `roost--open-once-out`, `roost--compose-listed` (reads, doesn't bump) |
| — | `roost--focus-shell` |

Invariants:
- I1. A navigation made by Roost is seen by every pending open.
- I2. A navigation Roost didn't make isn't counted, so each opener must also compare
  window and buffer. `roost--open`, `roost--look-then`, `roost--you-stay` and
  `roost--while-you-stay` do, and `roost--open-once-out`'s callers through
  `roost--stayed-as-it-goes`.

Views that take the selection and don't bump (`roost-task-info`, `roost-dashboard`,
`roost--compose`, the drafts, search, workload, doctor) are caught by I2's window and
buffer check.

Open: none.

### Held for the minibuffer

Kind: implicit. Lives in: closures on `minibuffer-exit-hook`,
`roost--held-for-minibuffer`, which only the tests read.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Free | `roost--when-out-of-minibuffer` | no minibuffer | Free | calls it | same |
| Free | same | minibuffer | Held | count up, hook | same |
| Held | a minibuffer exits, by RET or `C-g` | | Free | count down, timer | `done` |
| timer | fires | still a minibuffer, as in recursion | Held | | same |

Invariants:
- I1. No reply changes windows or asks while you type in the minibuffer.
- I2. What was true when it was held may not be when it runs. `roost--task-made`,
  `roost--while-you-stay` and `roost--stayed-as-it-goes` look again at where you are,
  and `roost--open` asks its host again. `roost-shell`'s reply goes by what it held,
  which a session that ended would meet too: rarer, and no finding of its own. So does
  a refused open, whose question then asks about what may have changed; its host
  refuses what no longer applies.

`roost--compose-listed` holds a closure at each poll while a minibuffer is open: the
first to run closes and opens, and the rest find you gone. Harmless, and it repeats
"Roost created".

Open: none.

### Questions left open

Kind: implicit. Lives in: Emacs's minibuffer depth; `roost--questions-left-open`,
`roost--quit-questions-left-open`, `roost--quit-questions-here`.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Open, you are elsewhere | a command you gave | | Quit | timer calls THEN, non-local exit | `roost--quit-questions-left-open` |
| Open, you are in it | command | | none | returns nil | `roost--questions-left-open` |
| Open, recursive edit too | command | | none | returns nil | same |
| any | a reply | | none | never quits: the quitting would end a command that waits | docstring |

A draft with its own question open says "Already sending" (or creating) if you press
`C-c C-c` again, ahead of the check that would quit it; `C-c C-k` quits it. There is a
way out, so it is no finding.

Open: none.

### Resuming

Kind: implicit. Lives in: `roost--resuming`; closures in `roost-resume` and
`roost--resume-together` (`there`, `tried`, `failures`).

| State | Meaning | How you can tell |
|---|---|---|
| Asked | Request in flight | |
| Waiting its turn | One of several, not yet asked | key in `roost--resuming` |
| There | Replied; you had stayed | `there` set |
| Done | | key gone |

Invariants:
- I1. No key stays in `roost--resuming` once its reply has come. (Sweep's `left-behind`.)
- I2. A task resumed opens only if you stayed. `there` is read as the reply comes, and
  again once you are out of the minibuffer, before its terminal goes: asked after, where
  you are says nothing (`roost--stayed-as-it-goes`).

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| — | `roost-resume` | others crashed, you say yes | Asked + others Waiting | keys added | `roost--resume-together` |
| — | `roost-resume` | | Asked | key removed | `roost-resume` |
| Asked | good reply | you stayed | There | | `roost--act`'s `replied` |
| There | out of the minibuffer | you moved | Done | nothing opens | `roost--stayed-as-it-goes` |
| There | out of the minibuffer | generation, listed, you stayed | opens | | `roost--open-once-out` |
| Asked | failure | | Done | counted | `roost--resume-together` |
| Waiting | its turn | stopped, gone or resumed | Done | passed over | `next` |
| Waiting | its turn | | Asked | | `next` |

A synchronous error from `roost--act` on the first task would leave every key in
`roost--resuming`; nothing in it signals on real input, so this is no finding.

Open: none.

### A terminal's connection

Kind: implicit. Lives in: tmux-control's process and `tmux-control--session`;
`terminals` in `roost--act`.

| State | Meaning | How you can tell |
|---|---|---|
| Connected | Live control client | buffer has a process |
| Released | Roost disconnected it ahead of an action | `terminals` holds it |
| Gone | Killed | |

Invariants:
- I1. A terminal never reports a lost connection for an action of yours. (Docstring of
  `roost--release-terminal`.)
- I2. Reconnecting is only after the host confirms the window. (`roost--restore-terminal`.)
- I3. A refused action on a live agent gives its terminal back.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Connected | stop, retire, merge, forget, discard | own session | Released | disconnect | `roost--act` |
| Connected | resume | not live | Released | disconnect | `roost--act` |
| Released | good reply | | Gone | killed once out of the minibuffer | `roost--discard-terminal` |
| Released | failure | `live`, or resume | Connected | `inspect`, then reconnect if shown | `roost--restore-terminal` |
| Released | failure | not `live` | Released | opening reconnects | `roost--act` |
| Released | `roost-forget-host` | | Gone | agents run on | `roost-forget-host` |

Open: none of its own. A refused action on a dead pane leaves its terminal
disconnected until you open it, which is what opening is for.

### `n`, the run through waiting tasks

Kind: implicit. Lives in: `roost--next-run`, `roost--next-unblocked`.

| State | Meaning | How you can tell |
|---|---|---|
| No run | | `roost--next-run` nil, or you are in no task it opened |
| Running | Opened at least one | `:opened` holds the task here |
| Offered | Said none waits; next press goes back | `:offered` |

Invariants:
- I1. A run goes on only from a task it opened. (Docstring of `roost--next-run`.)
- I2. Going back stops a task still opening. (`roost--go-back`.)
- I3. Going back survives what went: a frame or workspace gone says so.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| No run | `n` | a task waits | Running | place kept, open | `roost-next-waiting` |
| No run | `n` | none | No run | user-error | `roost-next-waiting` |
| Running | `n` | a task waits | Running | `:opened` grows | `roost-next-waiting` |
| Running | `n` | none | Offered | says so | `roost-next-waiting` |
| Offered | `n` | a task waits | Running | | `roost-next-waiting` |
| Offered | `n` | none | No run | goes back | `roost--go-back` |
| Offered | `n` | its frame gone | No run | user-error | `roost--go-back` |

`roost--next-unblocked` holds a key that may go; `member` then fails and `n` starts from
the first. An old run has no expiry: `n` a day later, from a task it opened, can offer
a way back to yesterday's windows. That is harmless, and no finding.

Open: none.

### The frame's task and the task opened last

Kind: implicit. Lives in: the frame parameter `roost-task`, `roost--current-task`,
workspaces by `roost--workspace-name`, `roost--perspectives`.

Invariants:
- I1. Without workspaces a frame shows one task. (Docstring of `roost--set-aside-drafts`.)
- I2. A key may name a task that went; each reader looks it up. (`roost--frame-task`,
  `roost--task-at-point`.)
- I3. A task renamed keeps its workspace. (`roost--rename-workspace`.)

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| any | opened | | that task | both set; drafts set aside | `roost--activate-workspace` |
| any | a view takes the frame | | that task | `roost--take-frame` | `roost--in-task-frame` |
| gone | redraw | another's terminal shows | that task | taken up | `roost--adopt-shown-task` |
| any | frame deleted | marked in no frame | the selected frame's | redraw | `roost--frame-deleted` |
| any | go back | | as it was | set back | `roost--go-back` |
| any | retired | | workspace closed | in every frame | `roost--retired-workspace` |

`roost--display-task` sets these before it connects, so a failing connect leaves them
naming a task whose terminal didn't show. Only a redraw notices, and only for a task
gone. Reachable only through a tmux-control error; no finding.

Open: none.

### Drafts set aside

Kind: implicit. Lives in: `roost--set-aside`, frames in each draft.

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Shown | another task takes the frame | no workspaces | Aside | window closes or goes back | `roost--set-aside-drafts` |
| Aside | its task opens in that frame | not shown yet | Shown | beside its terminal | `roost--bring-back-drafts` |
| Aside | `e` or `@` | | Shown | list keeps the frame | `roost--send-draft` |
| Aside | that frame deleted | | Aside | comes back only by `e` or `@` | |
| Aside | its task goes | | Aside | stays in the buffer list | |

Compose drafts have no task and aren't set aside. By reading, not tested: nothing is
lost, as `e` finds the draft.

Open: none.

### Side windows

Kind: implicit. Lives in: `roost-sidebar-mode`, `roost-task-panel-mode`,
`roost--layout-timer`, `roost--beside-terminal`, `roost--near-terminal`.

Invariants:
- I1. They change after redisplay, never from a window hook. (Docstring of
  `roost--layout-changed`.)
- I2. One timer at a time: it clears itself first, so an error can't stop the next.
- I3. A panel names keys for where the terminal is. (`roost--redraw-moved-panels`.)

| From | Event | Guard | To | Effect | Code |
|---|---|---|---|---|---|
| Idle | layout changes | no timer | Pending | timer | `roost--layout-changed` |
| Pending | layout changes | | Pending | | same |
| Pending | fires | | Idle | sync, redraw moved panels | timer |
| any | mode off | | Idle | windows close | modes |
| any | panel `q` | docked | mode off | | `roost-task-info-quit` |

`roost--go-back` can restore a side window you turned off during a run; the next layout
change closes it. It heals itself.

Open: none.

### Stale and marked views

Kind: implicit. Lives in: `roost--stale`, `roost--selection`, `roost--marked-key`.

- `roost--stale`: a hidden buffer records its redraw, and `roost--shown` runs it from
  `window-buffer-change-functions`. Every redraw of a shown buffer clears it.
- `roost--selection`: an overlay per buffer, moved by `post-command-hook`.
- `roost--marked-key`: `unset` outside a sidebar drawing, let-bound within one. No
  state survives a drawing.

The sweep's `gone` rule can report a stale row in batch, where no redisplay runs
`roost--shown`. A real Emacs draws it.

Open: none.

### Views that show one run

Kind: explicit counters. Lives in: `roost--search-generation` (buffer-local),
`roost--workload-generation`, `roost--doctor-generation`.

| Machine | Bumped by | Checked by | Buffer killed |
|---|---|---|---|
| Search | `roost--search-start`, every run | `roost--search-arrived` | `buffer-live-p` |
| Workload | `roost-workload`, every run | `roost--workload-reply` | reply draws nothing |
| Doctor | `roost-doctor`, every run | `done` | `roost--render-doctor` looks it up |

Each is bumped at the one place a run starts, and nothing else clears results. A killed
search buffer takes its counter with it, and the old closure holds the dead buffer.

Open: none. Sound.

### Asking before acting

Kind: implicit. Lives in: each command's closure, and a question in the minibuffer for
as long as you leave it there.

Invariants:
- I1. Roost deletes work only when you discard a task and type its name.
  (CLAUDE.md, Rules; manual.) The `y-or-n-p` path has nothing to lose when it asks,
  and its host counts again before it stops the agent.
- I2. What the question told you holds when you answer it, or the action is refused,
  with nothing done. A count that went down isn't more than you were told. What an
  agent writes between that count and `stop` goes with the task: a moment, not the
  time you take to answer.
- I3. A merge takes the commit it checked, by all three ways of merging, whatever the
  branch does after. A commit made past that check stays out, and the task stays, as
  `safe_to_delete` then finds its branch has work unmerged.
- I4. A count Git can't give isn't nothing: with a damaged index, a discard counts
  every file in the worktree (`uncommitted_files`), so it wants the name. A new folder
  counts file by file, in a submodule too.

| Question | From | Pins | The host checks again | Changes it misses |
|---|---|---|---|---|
| Discard, name typed | dry run | branch commit (`expect`), counts (`told`) | branch moved, any count higher | a change that adds to no count: a file edited, one swapped for another, a commit amended off the branch |
| Discard, y-or-n-p | dry run | the same, all counts 0 | the same: asked again, it wants the name | none: any new file or commit counts |
| Retire | cache | nothing | agent, dirty, unmerged | none: it refuses |
| Merge | cache | branch commit (`branchTip`, as `expect`), once measured | branch moved, just before merging; agent, dirty, conflicts | a commit before it was measured, which is refused too: the question spoke of what was measured |
| Stop | cache | nothing | | none that matter |
| Forget | cache | nothing | agent running | none: it refuses |
| Send anyway | status | nothing | status without `force` | a stale copy: VIEWS-4 |
| Resume? | a refusal | nothing | agent running | none |
| Update: ask its agent? | a reply | nothing | | none |

Commands against what Emacs offers (`roost--action-applies-p`) and what the host refuses:

| Command | Offered when | Refused in Emacs | Refused by the host |
|---|---|---|---|
| open | always | | window gone: offers resume |
| shell | worktree, not stopped or crashed | | window gone |
| send | agent running | control characters | not running; starting or permission without `force` |
| stop | agent running | | retired |
| resume | worktree, not running | | running |
| update | worktree | | active, dirty, merge under way |
| pull request | worktree, and commits or a pull request | | dirty |
| merge | work unmerged, not active, none left by the agent | another branch; dirty offers Magit | branch moved, active, dirty, conflicts |
| retire | not active, none left by the agent | active; else offers discard | active, unmerged, dirty |
| forget | always | | running: stops it first |
| discard | always | | branch moved; holds more than you were told |

No state has no way out, and nothing offered is always refused: a task on another
branch has `x`, and a task gone has `X`.

A merge refused as moved measures the task, so that the next `m` asks about where it
is now, watching or not; a removal cut short, which `m` finishes, is measured that far
too. With no `branchTip` yet, nothing is pinned, and a merge goes as it always did. A
discard refused while its agent is at work says to stop it first, as each new look
would find more.

Open: VIEWS-4.

## Across machines

### Action by state

Rows are what `rpc` does, whatever Emacs offers. `ok` runs; otherwise the
reply is a refusal that says why. With tmux not answering, what asks it for the task's
pane refuses: `resume`, `stop`, `send`, `shell`, `inspect`, `rename`, `update`, `retire`,
`merge`, and `discard` once past its dry run. `forget` goes on as if no pane were there,
and `seen`, `turn`, `attach`, `pr` and `look` don't ask it. Each cell was run on real Git
and tmux, a fresh repository for each, 128 cells, and none stuck or showed a bug word.
"Work holds worktree" is on an idle agent; only the finishing actions differ from the
column beside it. `pr` here means on a task with commits; with none it says there is
nothing to propose.

| Action | Idle agent | Active agent | Ended | Work holds worktree | Removing | Removal cut short | Worktree gone | Repository gone |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| resume | still running | still running | ok | still running | removing | was removing | worktree gone | ok; the agent fails |
| stop | ok | ok | ok | ok | removing | was removing | ok | ok |
| send | ok | ok; `force` at a prompt | not running | ok | removing | was removing | not running | not running |
| shell | ok | ok | window gone | ok | removing | was removing | window gone | window gone |
| attach | ok | ok | ok | ok | removing | was removing | ok | ok |
| inspect | ok | ok | window gone | ok | window gone | window gone | window gone | window gone |
| seen, turn | ok | ok | ok | ok | ok | ok | ok | ok |
| rename | ok | ok | ok | ok | removing | was removing | ok | ok |
| update | ok | active | ok | ok | removing | was removing | worktree gone | Git can't read |
| pr | ok | ok | ok | ok | removing | was removing | worktree gone | Git can't read |
| look | ok | ok | ok | ok | removing | was removing | worktree gone | no commit to look at |
| retire | ok | active | ok | busy | removing | ok | ok | Git can't read; ok if the folder went too (by reading) |
| merge | ok | active | ok | busy | removing | ok | ok | Git can't read; nothing to merge if the folder went too (by reading) |
| discard | ok | ok | ok | busy | removing | ok | ok | ok |
| forget | running | running | ok | busy | removing | ok | ok | ok |

No state lacks a way out. While Git merges or updates a task, each row reads as
Removing does, in words of its own. Two refusals have the wrong words, both cosmetic: `update` for an active
agent says "before retiring", from `require_finished`; and `inspect` while a
worktree is removed, or after that was cut short, says to resume the task, which
those states refuse.

### Action by status

By the agent's status, where `L` is a pane that's live, and `D` one dead or gone.

| Status | `send` | `resume` | `stop` | `retire`, `merge`, `update` | `forget` |
| --- | --- | --- | --- | --- | --- |
| `starting` | L: refused without `force` | L: refused | Yes | Refused: active | L: refused |
| `permission` | L: refused without `force` | L: refused | Yes | Refused: active | L: refused |
| `running`, `background` | L: yes | L: refused | Yes | Refused: active | L: refused |
| `ready` | L: yes | L: refused; D: yes | Yes | Yes | L: refused |
| `exited`, `failed` | L: yes; D: refused | L: refused; D: yes | Yes | Yes | L: refused |
| `crashed` | D: refused | D: yes | Yes | D: yes; L: refused | D: yes |
| `stopped` | Refused | Yes | Yes | Yes | Yes |

`retire` and `merge` stop a live agent as they go; `update` leaves it running.
A pane running something else since the runner, as after `respawn-pane`, counts as
`D`. A false `running` passes `send`'s check, where `permission` would be refused,
which is why a request stands while unsure. No state lacks a way out.

### Writers

Each persisted field, and whether its read and write share a hold of the
registry lock.

| Field | Writers | Same hold? |
| --- | --- | --- |
| `status`, `updatedAt` | `make_task`, `spawn`, `stop`, `list_tasks`, `update_hook`, `apply_program_status`, `runner`, `abandon` | yes; `abandon` from `undo_creation` has no record to lose |
| `removing` | `remove_worktrees` | set in the hold; cleared by re-read and compare |
| `retiringCommit` | `retire` | yes; never cleared |
| `agentWorktrees`, `agentMade` | `update_hook` | yes; never pruned |
| `createId` | `make_task`, `abandon` (pops) | yes |
| `sendIds` | `send` | yes |
| `pr` | `pr` action, `check_pull_requests` | re-read after the release; compared with what it asked about |
| `looked` | `record_look` | re-read, compared with the look it measured from |
| `seen` | `seen`, `stop`, `list_tasks` | yes (a late `seen` can set an older value: [Seen, on the host](#seen-on-the-host)) |
| `turn` | `turn` | yes |
| `runId`, `paneId`, `panePid`, `helper` | `spawn`, `stop` | yes |
| `endedRun` | `runner` | yes |
| `session`, `windowIndex`, `windowId` | `spawn`, `resume`, `stop`, `list_tasks`, `inspect`, `shell` | yes |
| `shellPaneId` | `shell`, `spawn`, `stop` | yes |
| `name`, `task`, `renamedAt` | `rename` | yes |
| `setupComplete`, `copyComplete`, `submodulesComplete`, `allSubmodules` | `runner` | yes, fresh read each |

No lost update found in any of them.

### Checked and found sound

What the audit tried and didn't break, so that nobody has to wonder, and so that the
next one starts somewhere else.

- **Two things at once, on one task.** Real helpers, Git and tmux, five workers doing
  every action and hook on the same few tasks with commits landing throughout, a third
  of requests abandoned and asked again at once, slow Git hooks and a teardown command
  to widen each window: 8,939 requests with no lost commit, no record without its
  branch, no branch without its record, and a way out of each task. With half of those
  abandoned requests killed with their process group, as Emacs does: about 7,000 more,
  the same but for `removing`, which a kill leaves on purpose. Once in those a branch
  stayed with no record, which fits the known item on a ref deletion below.
- **The races you'd expect.** Merge against stop, retire against send, discard against
  `pr`, rename during retire, resume during removal: each is serialized by the registry
  lock, or refused by `require_not_removing`.
- **Writes.** Every status write is a fresh read under the lock, and no field in
  [Writers](#writers) has a lost update. `check_pull_requests` and `add_git_stats` run
  outside the lock: the first saves a fresh read after comparing, and the second saves
  nothing. After `store.released()`, every site re-reads, or saves nothing.
- **Earlier runs.** A hook, report or runner of an earlier run changes nothing.
- **Order.** Each capture in `test/captures`, with each event delivered up to three
  places late: reports delayed past hooks end the same.
- **`ProgramStatusFilter`.** 200,000 random mixes of prefixes, terminators and bytes
  that aren't UTF-8, each cut at random, against the same uncut: no difference.
- **The word.** 329,472 inputs give one word each, and `n`, the mode line, the sidebar's
  count, `roost--turn` and the history agree.
- **Requests.** Timers, callbacks, sleep and wake, `C-g` in waits: each request ends
  once. No reply from before a mutation resurrects or rolls back a task. Across a host
  dropping and returning, no notification repeats or goes missing.
- **Flags.** `roost--compose-submitting`, `roost--send-sending`, `roost--pr-sending`,
  `roost--notes-sending`, `roost--attachments-copying`, `roost--resuming` and
  `roost--held-for-minibuffer` reset on good, refused, dropped, timed out, `C-g`,
  declined and killed buffer. The exits that missed were `roost--refreshing` (REQUESTS-1,
  fixed) and errors after a good reply (VIEWS-11).
- **Since you last looked.** Compare-and-swap on `looked`, and looks without `base` or
  `commit` from older records still read.
- **Older records.** `runId`, `claudeSession`, missing flags, `retired`, `{number, url}`
  and `{}` for a pull request all read.

Not proved: that sshd leaves a helper running after a dropped connection, taken from
OpenSSH's behaviour and not run; perspective.el and tab-bar paths, read but not driven;
and pairs of commands in flight at once, where a throwaway sweep of about 5,700 cases
found no bug but wasn't made for two commands, so it is weak evidence.

### Known and not fixed

Known since the hunt of 2026-11-05 and left, each still reachable unless it says
otherwise.

| Item | Machine | Why it stays |
| --- | --- | --- |
| `u` with a submodule bump on the integration branch leaves ` M lib`, so `m` refuses, and following its advice reverts the bump | [The merge](#the-merge) | Roost doesn't update submodules, as that fetches; needs a decision |
| A ref deletion that fails during undo, as with a lock left by a reboot, leaves an empty branch with no task | [Creation](#creation) | Costs an empty branch, and nothing else. `make crash` counts it as what stays, not as a problem, only with Git's lock beside the branch |
| A damaged record is hidden, so its worktree and branch can't be finished from Roost | [Task record](#task-record) | Acting on it by ID says so, and to finish with Git |
| `ref_exists` reads any Git failure as no branch | [Finishing a task](#finishing-a-task) | On the safe side: a branch not deleted |
| `approvalsLeft` may be GitLab EE's alone, which would fail the merge request query on a CE server | [A task's pull request](#a-tasks-pull-request) | Unverified: needs a run against one |
| Forgetting a task while its tmux server is stopped can drop the record of an agent still running | [Finishing a task](#finishing-a-task) | It is the way out when tmux doesn't answer, and the worktree and branch stay |
| A signed-out `gh` freezes words, with no sign but `roost-doctor` | [What the forge last said](#what-the-forge-last-said) | By design: a task keeps what it had |
