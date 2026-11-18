---
name: verify-pull-request-left
description: >
  Model-check a pull request left to its agent: the helper's `leave` and
  `tell`, and Emacs deciding when to tell the agent and whose turn it is,
  with replies late, lost or out of order, a helper killed between the
  record and the paste, and the agent, you and a reviewer acting at once.
  Use before committing a change to leave, tell, told, counted, send,
  check_pull_requests or rpc's lock around `list` in scripts/roost_remote.py, or to roost--tell-due-p, roost--agents-turn-p,
  roost--tell-agent, roost--tell-key, roost--tell-occurrence, roost--told,
  roost--yours, roost--prompting-p, roost--newer-left, roost--pr-verdict,
  roost--pr-status, roost-leave-pull-request or roost--cache-task in
  roost.el; when "A pull request left to its agent" in
  docs/state-machines.md changes; or for /verify-pull-request-left.
---

# Verify a pull request left to its agent

One TLC model in `test/formal/pull_request_left/`, checked three ways,
through `test/formal/check.py`. It holds the code to these rules, numbered as
the section's invariants in `docs/state-machines.md`:

- **OnlyAtRest** (I2). A line of Roost's lands only at a prompt the agent
  rests at, after a turn it ended itself. Harm if broken: the line answers a
  question the agent asked, or joins a turn under way.
- **ToldOnce** (I3). Once for each thing, a head or a newest comment, each
  time the pull request is left. Harm if broken: an agent told twice of one
  failure, as after a helper killed mid-telling.
- **AtMost** (I5). `TOLD_MOST` times at most for one kind, each time it is
  left. Harm if broken: an agent whose every fix fails is told for ever.
- **RecordedIsPasted** (I3). What the record says the agent was told, it
  was, unless the helper was killed or tmux said the paste failed, which
  Emacs then leaves to you. Harm if broken: "told", with nothing pasted, and
  the failure hidden from you for two minutes.
- **ThreadsNoEcho** (I4). Of threads again only for a comment that is not
  the agent's own.
- **CacheLeftNewest** (I7). An older reply undoes no leaving, taking back
  or telling in Emacs.
- **NothingSinceJudged** (I8). The agent has done nothing since what Emacs
  judged by. Harm if broken: an agent told of a failure it fixed, or of its
  own answer in a thread, in a turn Emacs had not heard of.
- **RefusedIsYours**, **HadItsTurnIsYours** (I6). What Roost knows it did
  not tell the agent, and what the agent was told, acted on and left
  standing, wait on you at once, not after the two minutes.

I1, that Roost types only its own words, is not a matter of order:
`test_an_agent_is_told_only_what_roost_writes_and_only_at_rest` holds it.
I6's "never neither for long" is time passing; the models hold its two
ends, above.

## Does the change touch it?

```
python3 test/formal/pull_request_left/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the model (below) before you trust a
pass. `roost--cache-task` and `roost--act` are other sections' too: a change
to them that touches no `prLeft`, `prTold`, `prLeftAt` or `prLeftGen`, nor
the order of `roost--newer-events` and `roost--newer-left`, is theirs.

## Run it

```
python3 test/formal/check.py pull_request_left
```

About three minutes. Every line must say `ok`. `LeftPullRequest.cfg`,
`LeftPullRequestThreads.cfg` and `LeftPullRequestHost.cfg` must pass; each
`Name.VARIANT.cfg` must fail as its first line says, which proves the rule
can still fail, or, for a finding, that the bug is still there. `make formal`
runs every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the model says

`LeftPullRequest.tla`: one task with one open pull request. Its head is a
number each push of the agent's raises, with a check that fails on it or
not; review threads are the time of the newest comment in one unresolved.
The host's clock is a number each stamped write raises. At any step the
agent takes what was pasted, pushes, answers or resolves a thread, stops or
exits; you interrupt it, prompt it yourself, or press `L`; a reviewer
comments. Emacs holds a copy from replies that come late, out of order or
never.

| Model | Code |
| --- | --- |
| `Leave` | `leave`: `prLeft`, `prTold` dropped, a new `prLeftGen`, `prLeftAt` |
| `Take` | `tell`, to where it writes the record: its refusals in the code's order, `alreadyTold`, `TOLD_MOST`, at rest, `stale` when the record's `updatedAt` is not the request's `asOf`, the pane |
| `Recorded`, `Kept` | `prTold` written before the paste, every entry kept |
| `Paste`, `Record`, `SendId` | `send` under `tell`'s ID: the paste, tmux taking the line or not and saying it failed, the ID written after |
| `Killed` | the helper killed after the record, or after the paste |
| `Busy` | the registry lock, which the agent's hooks wait for |
| `Turn` | `roost--any-turn` of `roost--pr-verdict`: the forge asked after the agent's last event (`roost--pr-status`), and the agent not at work |
| `Key`, `Occ`, `ToldOf`, `Entries` | `roost--tell-key`, `roost--tell-occurrence`, `roost--told`, `roost--told-entry` |
| `Due`, `AgentsTurn` | `roost--tell-due-p`, `roost--agents-turn-p` |
| `Tells`, `Reply`, `NoReply` | `roost--tell-agent`: `roost--telling`, the `asOf` it sends, its success, a `stale` reply cached with nothing said, and `roost--untold` on a refusal or no reply |
| `Merge` | `roost--cache-task`: `roost--newer-events`, then `roost--newer-left`, and `prStatus` from the reply that has it |
| `Deliver` with `mine` | the reply to your own `L`, which forgets `roost--untold` |
| `GraceEnds`, `expired` | `roost--pr-grace` over, by `roost--told-here` or the entry's time |
| `Poll`, `PollAsks`, `polled` | rpc `list`: the record read under the lock, and `check_pull_requests` once it is let go; one step unless a config has `PollSplit` |
| `OtherAsks` | another Emacs's `tell`, of what the forge says then |

Three configs, as the whole is too large for one:

- `LeftPullRequest.cfg`: one Emacs, failed checks, two pushes, `L` twice,
  two tellings, two lists, one prompt of your own, and requests the helper
  takes after Emacs stopped waiting (`LateTake`).
- `LeftPullRequestThreads.cfg`: one Emacs, two comments, the agent's or a
  reviewer's, one prompt of your own, a list that asks the forge after it
  read the record (`PollSplit`), and no push.
- `LeftPullRequestHost.cfg`: the helper alone, asked by any Emacs at any
  time and killed at any step: two pushes, `L` twice, three tellings.

Checked once and in no config, for its three minutes: `LeftPullRequest.cfg`
with `PollSplit` passes (40 million states). So do two more, at one push,
no prompt of your own and no `LateTake`: this Emacs beside another that
tells and leaves (`OtherEmacs`, 11 million states), and this Emacs with a
helper killed mid-telling (`Kills`, 333 thousand).

Assumed: the forge's clock and the host's agree. A comment's time is the
forge's and `updatedAt` the host's, and `roost--tell-due-p` compares them:
on a host whose clock is behind by more than the rest of the agent's turn,
its own answer reads as newer than its last event, and it is told of it.
The model has one clock.

Assumed too: an agent that takes a prompt has its record say so in the
same step (`AgentTakes`), under the lock `tell` holds (`Busy`). In the
code the hook that says so is a process that waits for that lock, and Pi
and OpenCode go on without waiting for theirs; an agent whose status
reports are relayed has its turn recorded by the relay's recorder, once
that has the lock. A turn that starts in the moment between `tell` reading
the record and its paste, as on a prompt from another terminal or a
wake-up of the agent's own, has the line land in it. Not modelled, and not
tried on the code.

And the two minutes are by one clock. An Emacs that heard the telling
counts them by its own (`roost--told-here`); another, or this one started
again, counts from the entry's time, the host's, by its own clock
(`roost--seconds-since`): with the host's clock ahead, what the agent left
standing waits on you that much later. `GraceEnds` may come at any time, so
no rule here depends on it.

Left out: conflicts, which are told as a failed check is, by the head;
`to merge`, which is never the agent's; you at the task's terminal, a draft
to it open and the thirty seconds after a prompt of yours, which only keep
Emacs from asking, as never asking does; the two-minute patience of
`roost--pr-verdict`, taken as over; a second pull request for the task; what
the line says (`told_words`); notices and the row's word, which follow
`roost--yours`; `leavePr` on create, which is `Leave` before anything else;
and a resumed agent, whose prompt may hold what you left half typed.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it, at that point, with
that lock held or not. If it can, it is a bug: keep the rule, keep a config
that shows it (`\* expect: Rule`), and report it with those steps. Do not
weaken a rule or a bound until it passes, and do not fix product code
unless asked. If a step can't happen in the code, the model is wrong: fix
the action and point its comment at the code that rules the step out.

### Findings

None open.

Fixed, and kept as the variants that undo the fix (`AsOf` false):
`LeftPullRequest.no-as-of.cfg`, `LeftPullRequestThreads.no-as-of.cfg` and
`LeftPullRequestThreads.no-as-of-while-a-list-asks.cfg`. Emacs judged by
the copy it held, and `tell` didn't know what that copy was: an agent that
took a turn Emacs had not heard of, on a prompt from another terminal or
within one list's asking of the forge, was told of what stood before it, or
of its own answer in a thread. Emacs now sends the `updatedAt` it judged
by, and `tell` tells nothing when the record's is another
(`test_an_agent_that_did_something_since_emacs_judged_is_not_told`,
`roost-judges-afresh-when-the-agent-did-something-since`).

Fixed before the model, each kept as the variant that undoes it:
`LeftPullRequestHost.record-after-paste.cfg`,
`LeftPullRequestHost.send-id-without-gen.cfg`,
`LeftPullRequestHost.told-trimmed.cfg`,
`LeftPullRequest.refused-stays-hidden.cfg` and
`LeftPullRequest.grace-after-its-turn.cfg` are what review of #268 found.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new refusal in `tell`, a new field Emacs keeps of
the record, or a new guard in `roost--tell-due-p` goes in where its code
is. To prove a new rule can fail, add a constant that breaks the code it
guards the way a bug would, a `Name.VARIANT.cfg` with `\* expect: Rule`,
and keep it. To fix a finding, follow `.claude/skills/fix-a-finding`.

Once the model describes the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `047486f`. Since `4e0a586`, and the `asOf` and `stale`
of `tell`, `roost--tell-agent`, `roost--act` and `roost--cache-task` that
came with it, nothing the model reads has changed: `roost--cache-task`
notes what an agent shows after it has the agent told, and
`roost--watched-task`, which keeps Emacs from asking while you are at the
task's terminal, asks whichever package shows it (`roost--tmux-active-pane`).
