---
name: verify-git-and-forge
description: >
  Model-check what Roost says of a task's merge: the helper's pull request
  record and its "landed" (which `x` retires on), and the row word "merged"
  in Emacs as polls and replies come and go, and as `B` changes the branch
  the task merges into. Use when a change touches has_tip,
  recorded_merge_at, started_at, landed, check_pull_requests, task_pull_requests,
  fetch_heads, record_push, push_pull_request, pull_request, retarget,
  safe_to_delete, merged_pull_request_head, add_git_stats, git_stamp or
  rpc's `pr`, `list` and `retire` in scripts/roost_remote.py, or
  roost--refresh-host, roost--cache-task, roost--task-states, roost--act,
  roost-retarget, roost--landed or roost--merged-p in roost.el; or when
  asked to verify "Git and the forge" in docs/state-machines.md.
---

# Verify Git and the forge

Two TLC models in `test/formal/git_and_forge/`, each checked again at other
bounds, through `test/formal/check.py`. They hold the code to these rules:

- **RetireLosesNothing** (`Landed.tla`). Whatever the helper's record says
  merged at the tip did merge, here or on the forge, so `x`, which deletes
  the branch on that word, loses no commit; and what `x` does delete is
  somewhere else too. Harm if broken: retiring deletes work that is nowhere
  else.
- **RetireOnlyLanded** (`Landed.tla`). `x` deletes a branch only when its
  tip is in the branch the task merges into, as the record names it then,
  or in what the forge merged, or the task never committed. Harm if broken:
  after `B`, `x` retires work merged only into the branch before, or merged
  nowhere.
- **RecordedMergesHappened** (`Landed.tla`). A record that says `MERGED`,
  or names a `mergedHead`, names a merge the forge made, at that head.
- **RepliesSayTrue** (`Landed.tla`). What a `list` reply tells Emacs is
  landed was, at the tip as it was measured, of the branch that reply names.
- **LandedSaysSo** (`Landed.tla`). Work that is merged reads as landed:
  only commits after the merge keep it from that, not the branch `B` names.
  Harm if broken: a merged task stops saying "merged", and its next step
  names commits since the merge that aren't there.
- **CleanNoOlderThanLanded** (`MergedWord.tla`). A row says "merged" only
  with a cleanliness measured with, or after, the news that it landed.
- **MergedHeals** (`MergedWord.tla`, temporal). A row that says "merged" of
  work with commits the merge lacks, or of a branch the task merges into no
  more, stops saying so, as polls go on.

## Does the change touch it?

```
python3 test/formal/git_and_forge/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the models (below) before you trust a
pass. A change outside these functions can still matter if it changes what
they are given, such as the fields of a record or of a reply: `retarget`
was such a change, to the branch `landed` reads, and `make_task` writes the
`startCommit` that `started_at` gives it.

## Run it

```
python3 test/formal/check.py git_and_forge
```

About four minutes. Every line must say `ok`. `Landed.cfg`,
`LandedTwoPRs.cfg`, `LandedRetarget.cfg`, `MergedWord.cfg` and
`MergedWordRetarget.cfg` must pass; each `Name.VARIANT.cfg` must fail as its
first line says, which proves the rule can still fail, or, for a finding,
that the bug is still there. `make formal` runs every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the models say

`Landed.tla`, one task on its host. Commits are numbers with parents; 0 is
where the task's branch was made. The world moves at any step: the agent
commits, amends, pushes (forced or not), pulls the forge's branch, opens a
pull request, resets its branch; the forge takes commits, merges, closes,
reopens once; you merge the task by hand into a branch, or pull a merge
into one, once; and you name another branch for it to merge into with `B`.
Meanwhile one poll, one `P` and one `x` run, in the code's locked steps:

| Model | Code |
| --- | --- |
| `HasTip`, `RecordedMergeAt`, `HostLanded` | `has_tip`, `recorded_merge_at`, `landed` |
| `target`, `base` | the record's `integrationBranch` and `baseCommit` |
| `StartedAt` | `started_at`: the record's `startCommit`, which `make_task` sets and `retarget` keeps, or writes down from `baseCommit` in an older helper's record before it moves that. Always commit 0 |
| `Retarget` | rpc `retarget`: `retarget`, with `integration_for` and `git merge-base`, for a branch, another task's, a tag or a commit |
| `Reset` | `git reset --hard` in the worktree, where a config has `Resets` |
| `PollList` | rpc `list`: `list_tasks`, then `branch_tip` and `pushed` in `check_pull_requests` |
| `PollAsk`, `OursOf` | `task_pull_requests` (no answer: None) |
| `PollFetch`, `ToFetch` | `head_to_fetch`, `fetch_heads` |
| `PollWrite`, `Shown`, `Made` | `shown_pull_request`, `merged_tip`, the record and its compare-and-swap |
| `PollMeasure` | `add_git_stats`, and rpc's `landed()` of a task asked about |
| `PStartPush`, `PPush`, `PRecord` | rpc `pr` with a record: `push_pull_request`, `record_push` |
| `POpen`, `POpenRecord` | rpc `pr` with none, or a title after closed or merged: `pull_request` |
| `XAsk` | rpc `retire`'s first read, and `merged_pull_request_head` |
| `XRetire`, `SafeToDelete`, `Elsewhere` | rpc `retire`'s second read, and `safe_to_delete` in `retire` |

A pull request merges into the base it names, which the models don't hold:
it need not be the branch the task merges into, as an agent's own may name
another and `B` leaves an open one as it is. So "landed" is of the branch
the record names now, or of a merge on the forge wherever it went, and
`RetireOnlyLanded` says as much. After `B`, a task whose pull request merged
into the branch before still reads as merged, and `x` retires it: by the
manual's "merged, on GitHub or GitLab or into the branch it merges into".

`MergedWord.tla`, one task in Emacs, its agent idle and seen. The host's
landed is taken as true (Landed.tla checks that), of the branch its record
names. Polls are quiet (`Q`) or ask the forge too (`QP`); a quiet poll that
sees the Git stamp or the branch move, or finds measuring owed, starts a
list of that task (`M`), or a full one (`F`) when every task is owed; `g`
is `F`. Replies come back good, failed, or dropped as stale, as
`roost--refresh-host`'s success lambda, `lost` and `roost--measures-owed`
and `roost--measures-due` handle them. `Merged` is `roost--merged-p`
reduced to `landed` and `dirty`.

| Model | Code |
| --- | --- |
| `Retarget` | rpc `retarget` on the host, from this Emacs or another: `landed` is then of the new branch, and `git_stamp` reads its reflog |
| `BReply` | `roost--act`'s success for `retarget`: `roost--revisions`, `roost--cache-reply`, and `roost-retarget`'s `roost--refresh-host` of the task |
| `stale`, `Dropped` | the success lambda's revision test, and `lost` untried |
| `pending`, `Finish` | `roost--full-refresh-pending`, and `finish` |
| `rBranch`, `eBranch`, `changed` | `integrationBranch` in a reply and in the cache, and in `roost--task-states` |
| `HostMeasure`'s `said` | `add_git_stats` and `landed()` go by the record `list_tasks` read |

Bounds: `Landed.cfg` three commits and one pull request, `LandedTwoPRs.cfg`
two and two, both with no `B`, `x` or reset; `LandedRetarget.cfg` two
commits, one pull request, `B` twice, `x` and resets, with no `P`;
`MergedWord.cfg` two commits, two merges and two replies lost, with no `B`;
`MergedWordRetarget.cfg` one commit, one merge, one reply lost and `B` once.
Resets beside `P` were checked once and are in no config: `Landed.cfg` at
two commits with `Resets` passes (3.1 million states), and at its own three,
or with two pull requests, takes several times as long as without.

Other tasks need no steps of their own. Several attempts at one prompt, and
a fork, are tasks with their own branch, record and reflog, and the forge
lists each one's pull requests by its branch's name. What an attempt merges
into the branch they share is commits this task's branch lacks, which
nothing here reads. A fork that merges brings this task's commits it
started from, as `HandMerge` does before this task's later ones.

A conversation, a task in no project, is a task in a repository of Roost's
own with no remote. Nothing is pushed, so no poll asks a forge and no pull
request is recorded; Emacs offers it no `m`, `P` or `B`, and `retarget`
refuses it. It is the model with no push, pull request, merge or `B`:
never landed, unless its agent commits and you merge that by hand.

Left out: a second poll at once (another Emacs); the fields
`unfetched` (every poll may try a head again, any fetch may fail, which
covers trying once), `mergedBases`, `base` and `worktreePr`; the `note` of
`retarget`'s reply; GitLab's rebase merges; branches of the same name from
forks or earlier tasks (`own_commits` is taken as so); the verdict, turn,
notices and merge hooks; the agent's status, seen, and a worktree on
another branch; `m`, which the task-on-host models have.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it, at that point, with
that lock held or not. If it can, it is a bug: keep the rule, keep a config
that shows it (`\* expect: Rule`), and report it with those steps. Do not
weaken a rule or a bound until it passes, and do not fix product code
unless asked. If a step can't happen in the code, the model is wrong: fix
the action and point its comment at the code that rules the step out.

### Findings

Open: none in the models.

Fixed, each with the variant that undoes its fix:

- `MergedWord.GivesUp.cfg`: two measurements of a change lost in a row, and
  Emacs stopped asking. What is owed stays owed, taken up later
  (`roost--measures-due`, the model's `later` and `Due`).
- `LandedRetarget.BaseOntoTip.cfg` and `LandedRetarget.BaseOntoTipRetired.cfg`:
  `B` naming what had all of the task's commits moved `baseCommit` onto its
  tip. A task merged there read as one that never committed; and `x`
  retired one named a tag at its tip, its commits merged nowhere.
  `retarget` leaves `baseCommit` where it was then. Since `started_at`,
  that guard alone keeps no rule of these models: it keeps the task's
  files and its pull request its own, which
  `test_retargeting_onto_a_branch_that_has_the_tasks_commits_leaves_them_merged`
  holds. So both configs set `StartedAtBase` too, the code as it was
  before either fix.
- `LandedRetarget.StartedAtBase.cfg`, `LandedRetarget.StartedAtBaseMerged.cfg`
  and `LandedRetarget.StartedAtBaseEmptied.cfg`: `landed` and
  `safe_to_delete` took a task at its `baseCommit` for one that never
  committed, and `B` can make that a commit of the task's own, by naming
  what has some of its commits and not all: a tag at an earlier one, a
  fork's branch, or a branch its first commits were merged into. Reset
  there, `x` retired it with its commits merged nowhere
  (RetireOnlyLanded), or it didn't read as merged where that commit was
  (LandedSaysSo); reset to where its branch was made, it read as merged,
  with no commit of its own (RetireLosesNothing). They go by `startCommit`
  now (`started_at`), which `B` never moves. `LandedRetarget.cfg` has
  resets since.
- `MergedWordRetarget.BranchUnwatched.cfg`: `B`'s reply lost, or `B` in
  another Emacs, where the Git stamp didn't move: nothing measured the task
  against the new branch, and its row went on saying "merged".
  `roost--task-states` has the branch.

Open, by reading and not in the models: what `retarget`'s `note` says of a
pull request `P` just opened, after `B` twice, and of one `P` opens while
`B` runs. See "A task's pull request" in `docs/state-machines.md`.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new way to write the record, a new step outside the
lock, or a new reply field Emacs keeps goes in as an action. To prove a new
rule can fail, add a constant that breaks the code it guards the way a bug
would, a `Name.VARIANT.cfg` with `\* expect: Rule`, and keep it.

Once the models describe the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `8f651f3`, with the changes to `landed`, `safe_to_delete`
and `retarget`, and the new `started_at`, that came with this line. Since
`e910487`: `retarget` and `B` (the record's branch, and where its commits
count from, can change, in both models, and `x` has its steps),
`startCommit` (where its branch was made, which nothing changes),
conversations, attempts and forks (no new steps: see above), and
`roost--cache-task` and `roost--apply-snapshot` noting tasks that went,
which the models don't read. From the other sections: `safe_to_delete`
leaves out branches that are going (`branches_going`, and an agent's own
worktree's), which only refuses more than the models' `SafeToDelete`; and
`retarget` stamps `retargetedAt`, which nothing here reads.
