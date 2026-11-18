---
name: verify-emacs-and-hosts
description: >
  Model-check how Emacs talks to its hosts: requests in flight at once,
  replies late, refused, dropped or timed out, refreshes, the helper copy
  pruned and installed again, and what each reply does to the tasks Emacs
  holds. Use after changing roost.el's host requests (roost--run,
  roost--request, roost--expire-request), refreshes (roost--refresh-host,
  roost--apply-snapshot), how a reply is cached (roost--cache-task,
  roost--cache-reply, roost--newer-events, roost--newer-offers,
  roost--newer-branch, roost--newer-shown, roost--act, roost--create-task,
  roost--task-made, roost--take-offer, roost-retarget, the inspects in roost--open and
  roost--notify-attention, the refresh roost-compose-submit asks for an
  offer's draft),
  or the helper's install, prune_helpers, rpc's locking or detach, or what
  retarget, take_offer, make_task or keep_shown stamp; when the
  "Emacs and its hosts" section of docs/state-machines.md changes; or for
  /verify-emacs-and-hosts.
---

# Verify Emacs and its hosts

`test/roost-sweep-late.el` holds back one reply at a time. This checks every
order of several requests at once, against a model of the code in TLA+.
TLC explores every state the model can reach within its bounds, and fails
with the shortest path to a broken rule.

## What it promises

`CachedTasks.tla` (Host refresh, Cached task):

- **NoRollback.** A reply never takes Emacs back to older news of a task: it
  doesn't bring back a task that went, drop one Emacs knows is there, or
  roll a record back to an older `updatedAt`. Harm: a retired task back in
  the sidebar, an agent asking again for what you answered, review notes
  deleted with a task a stale list lacked.
- **NoOfferRollback.** Nor does a reply bring back an offer you took, or
  hide one made since: a task Emacs lists has the newest `offersAt` it has
  held. An offer moves no `updatedAt`, so `roost--newer-events` can't see
  it. Harm: an offer you opened back under its task, to start twice.
- **NoBranchRollback.** Nor does a reply take a task back to the branch it
  merged into before `B`: a task Emacs lists has the newest `retargetedAt`
  it has held. `B` moves no `updatedAt` either. Harm: `m` asking to merge
  into the old branch, and saying it did, while the host merges into the
  new one.
- **NoShownRollback.** Nor does a reply take a task back to the image or
  page it showed before, or to none: a task Emacs lists has the newest
  `shown.at` it has held. Showing moves no `updatedAt` either. Harm: the
  panel no longer names the image, and `roost-show-image` says the task
  has shown none, until the next list.
- **OfferRowGoes.** Once a task is made from an offer and its draft has
  asked for the host to be listed, the offer's row goes: with no list in
  flight, and none asked since that came to nothing, Emacs holds the task
  that offered it with the offer taken. Harm: an offer whose task you made
  still under its task, to start again.
- **OneList.** At most one list per host is in flight, and
  `roost--refreshing` says whether one is; a full refresh owed has a refresh
  to run it. Harm: a host never asked again until Emacs restarts
  (REQUESTS-1), or two lists overtaking each other.

`HostRequests.tla` (Host request, Helper copy):

- **OneCallback.** Every request ends in exactly one callback, SUCCESS or
  FAILURE. Harm: a command that never hears back, or acts twice.
- **EveryRequestEnds.** Each request is answered in the end, by its host or,
  if the host never answers, by its timer (`roost--expire-request`). A
  property, checked under `TimedSpec`, which assumes only that the timer
  fires. Harm: a command that waits for ever.
- **ActionOnce.** What changes things runs at most once on the host, however
  Roost asks again. Harm: a stop, merge or prompt done twice.
- **NoHelperFailure.** A helper another Emacs pruned fails no request.

## Run it

```
python3 test/formal/check.py emacs_and_hosts
```

About three and a half minutes, or seven on a machine busy with other work; `make formal`
runs every model. Java and TLC 1.7.4 come from mise. Every line must say `ok`: `CachedTasks.cfg`,
`CachedTasksOffer.cfg`, `CachedTasksRetarget.cfg`, `CachedTasksShown.cfg`,
`CachedTasksTwoCreates.cfg` and `HostRequests.cfg` pass, and each other
config fails the way its first line says.
`CachedTasksOffer.tla`, `CachedTasksRetarget.tla`, `CachedTasksShown.tla`
and `CachedTasksTwoCreates.tla` are `CachedTasks.tla` again at other bounds,
as the runner takes one passing config per model: a task made from an
offer, `B`, what an agent shows, and two tasks asked for at once, each take
too long beside all that `CachedTasks.cfg` has. Nearly all the time is
`CachedTasks.cfg`, 24.6 million states, the same as before the offer's
draft and what a task shows were added: both are switched off there
(`FromOffer`, `MaxShown`). The other four are five million between them,
three of them `CachedTasksShown.cfg`'s.

Read every result with the pstack statechart skill (`/pstack:statechart`):
it tells a failure's shortest path in plain words, and draws a passing
model as a chart.

## Does your change touch it?

Coverage, confirmed against the code at **047486f**, with `roost--newer-shown`
and its place in `roost--cache-task`, which came with this line.
`git diff 047486f -- roost.el scripts/roost_remote.py` and look for these:

| Code | Model step |
| --- | --- |
| `roost--refresh-host`: the flag, `finish`, the `unwind-protect`, `revision` read at the start, the quiet poll calling itself; what asks it quietly: the watch timer, and `roost--read-live` once a page is whole | `CachedTasks`: `AskRefresh`, `Finish`, `Succeed` (list) |
| `roost--apply-snapshot` | `ApplySnapshot` |
| `roost--cache-task`'s merge, `roost--newer-events` | `CacheTask`, `NewerEvents` |
| `roost--newer-offers` | `NewerOffers` |
| `roost--newer-branch` | `NewerBranch` |
| `roost--take-offer` (asked only of a task listed: Do it here, and Dismiss from its row or its draft), the helper's `take_offer` | `AskAct` (take), `HostRun` (take), `Succeed` (take) |
| `make_task`'s take of the offer a task was made from, under the lock it saves the task with | `HostRun` (create, of a task in `FromOffer`); run in `CachedTasksOffer` |
| `roost-compose-submit`'s callback for the draft of an offer: `roost--refresh-host`, not quiet, called by `roost--task-made` once you are out of the minibuffer | `Succeed` (create) owes it, `RefreshForOffer`; run in `CachedTasksOffer` |
| `propose_task`, `taken_offers` in `list_tasks` | No step of their own: each moves `offersAt` with no reply about it, as a take that Emacs gave up on and `HostRun` ran all the same |
| `keep_shown` (`show_image`, `show_widget`): `shown.at` moves, no `updatedAt`; nothing else writes `shown` or takes it out of a record | `AgentShows`; run in `CachedTasksShown` |
| `roost--newer-shown` | `NewerShown` |
| `leave`, `tell` (`roost-leave-pull-request`, `roost--tell-agent` from within `roost--cache-task`), `roost--newer-left` | As a take here, by `roost--act`; their clock, `prLeftAt`, is in `pull_request_left` |
| `roost-retarget` (asked of a task listed, its callback's refresh), the helper's `retarget` | `AskAct` (retarget), `HostRun` (retarget), `Succeed` (retarget), `OverAndRefresh`; run in `CachedTasksRetarget` |
| `roost--cache-reply`, `roost--went-p`, `roost--went` | `CacheReply` |
| `roost--act`: `listed`, the revision bump at the reply; `roost-retire`'s stop of an agent with work in the background, whose callback asks to retire | `AskAct`, `Succeed` (stop, retire) |
| inspect in `roost--open` and `roost--notify-attention` | `AskAct` (inspect), `Succeed` |
| `roost--create-task`'s bump, `roost--task-made` (`roost--cache-reply` with `roost--went`); what asks it: a draft, `roost-compose-submit` once for each attempt, and `roost-new-conversation` | `AskCreate`, `Succeed` (create); two at once in `CachedTasksTwoCreates` |
| `make_task`, a conversation's and a fork's (`forkFrom`) too | `HostRun` (create) |
| rpc under the registry lock; `list_tasks` | `HostRun`: one step each |
| `detach`, `DETACHED`: what changes things outlives Emacs's wait | `Ended`, `Kept`, `HostLoses` |
| `roost--run`: sentinel, `finished`, the `condition-case` (a quit too) | `HostRequests`: `Ask`, `Deliver`, `Callback`; `CachedTasks`: `AskRefresh` |
| `roost--expire-request`, a dropped connection | `GiveUp` (both models) |
| `roost--request`: `install-and-invoke`, `roost--helper-unusable-p` | `Deliver`, `Then` |
| `roost--install-code`, `prune_helpers` (a week by mtime) | `Host` (install), `OtherPrunes`, `WeekPasses` |

A change elsewhere doesn't need this. A change here does, even a refactor.

## Check a change

1. Mirror the change in the model, step for step: what the code does in one
   sentinel or one command is one step. Keep the names the code uses.
2. Run it. If the configs that must pass still do, and every variant fails
   as it says, the change keeps the promises within the bounds.
3. If one that must pass fails, read the path with `/pstack:statechart` and
   walk each step against the code:
   - **A real bug** if every step can happen in Roost. Say it in the code's
     words, step by step. Don't weaken a rule or the model to make it pass.
   - **A modeling error** if a step can't happen: fix the model, and say
     what was wrong in the commit.
4. A new guard gets a variant: a `Break` value in the spec that takes the
   guard out, and a config `CachedTasks.NAME.cfg` or `HostRequests.NAME.cfg`
   whose first line is `\* expect: RULE`. Run it and watch it fail before you
   trust the guard's rule.
5. A new kind of request, a new way into the cache, or a new step that runs
   between Emacs's steps goes into the model and the table above. So does a
   field of a task that changes with no `updatedAt`: it needs a clock of its
   own, a `Newer` step and a rule, as offers and the branch have.
6. Once the model describes the code again, move the commit above to the
   commit you checked, in the same change. Not before.

## Variants kept

Each takes one guard out of the code and must fail its rule, so the rules
are known to bite:

- `BumpAtRequest`: revision bumped as an action is asked, not as it
  replies. A list asked between them, read before the action, brings back
  what the action retired. NoRollback.
- `NoWentCheck`: `roost--cache-reply` caches a reply for a task that went.
  NoRollback.
- `NoNewerEvents`: an older `updatedAt` replaces a newer one. NoRollback.
- `NoNewerOffers`: an older `offersAt` replaces a newer one, so opening a
  task before you took its offer brings the offer back. NoOfferRollback.
- `NoNewerBranch`: an older `retargetedAt` replaces a newer one, so a reply
  read before `B`, as one to stopping the task, brings back the branch it
  merged into. NoBranchRollback.
- `NoNewerShown`: an older `shown.at`, or none, replaces a newer one, so a
  reply read before the agent showed an image, as one to opening the task,
  that comes after the list that read it since takes the image's name out
  of the panel. NoShownRollback.
- `NoRevisionCheck`: a list read before your retire lands after its reply.
  NoRollback.
- `NoRefreshingGuard`: two lists at once. OneList.
- `NoUnwind`: a refresh that can't start leaves the flag set (REQUESTS-1).
  OneList.
- `NoReinstall`: a pruned helper fails the request. NoHelperFailure.
- `RetryAnyFailure`: retrying on a timeout runs the action again beside the
  first, which went on. ActionOnce.
- `SetupErrorLeavesProcess`: an error after `make-process` calls FAILURE
  and leaves the process, whose sentinel calls back too. OneCallback.
- `NoTimer`: no timer, so a host that never answers holds the request for
  ever. EveryRequestEnds (`temporal`).
- `QuitLeavesProcess`: `roost--run` catches errors only, so C-g during `g`
  leaves its list running, and it lands after a newer one. NoRollback.
- `CreateNoWentCheck`: `roost--task-made` caches create's late reply with
  `roost--cache-task`, bringing back the task you finished meanwhile.
  NoRollback.
- `QuietOfferRefresh`: the draft of an offer asks for its host to be listed
  quietly once its task is made, which does nothing while a poll is in
  flight; that poll, read before the task was made, comes to nothing, and
  the offer waits on under its task. OfferRowGoes.

## Findings kept

None. The four the model found are fixed: C-g during `g` leaving its list
running and create's late reply bringing back a task that went, which the
main config allows (`Allow`) and `QuitLeavesProcess` and `CreateNoWentCheck`
undo; and a reply read before `B` bringing back the branch a task merged
into, which `CachedTasksRetarget.cfg` has (`MaxBase`) and `NoNewerBranch`
undoes; and a reply read before the task's agent showed an image or a page
taking the task back to what it showed before, or to nothing, which
`CachedTasksShown.cfg` has (`MaxShown`) and `NoNewerShown` undoes
(`roost-a-reply-from-before-an-image-was-shown-keeps-what-the-task-shows`).

## Bounds and what is left out

- One host. Every table is keyed by host, so hosts don't meet.
  `CachedTasks.cfg`: one task there from the start and one you create. Two
  refresh asks (plus the full refreshes they owe), two of stop, retire,
  inspect or take, on the first task, one create, `updatedAt` moving twice.
  Agents' events on the first task only. Taking the first task's offer,
  which moves `offersAt` once (`MaxOver`), and no `B` (`MaxBase` 0): with
  it the run takes twice as long. The task you create is from no offer
  (`FromOffer` empty), and nothing is shown (`MaxShown` 0).
- `CachedTasksOffer.cfg`: one task there from the start, and one you create
  from its offer, which its host takes as it makes the task. Two refresh
  asks beside the one the draft asks for, and one of stop, retire,
  inspect or take, on the task that offered it.
- `CachedTasksRetarget.cfg`: the one task, and none made. `B` on it, which
  moves `retargetedAt`, twice, so that two `B`s' replies can cross, beside
  two refresh asks and those `B`'s replies ask for, and two of stop,
  retire, inspect, take or retarget. With a task being made too, `B` once
  and one refresh ask, it passed as well: seven million states, not kept
  for the time they take.
- `CachedTasksShown.cfg`: the one task, and none made. Its agent shows an
  image or a page twice, so that a reply can name the one before as well
  as none, beside taking its offer, two refresh asks, and two of stop,
  retire, inspect or take. No `B`. With a task being made too, as
  `CachedTasks.cfg` has, and one showing, a run was stopped unfinished
  after half an hour on a busy machine, where `CachedTasks.cfg` took
  twenty minutes, so the clock stays off there; with one showing each,
  `CachedTasksRetarget.cfg` (with `B` twice), `CachedTasksOffer.cfg` and
  `CachedTasksTwoCreates.cfg` passed as well, seven million states between
  them, not kept for the time they take.
- `CachedTasksTwoCreates.cfg`: two tasks asked for at once, as a draft's
  two attempts, one refresh ask, and one act, on a task made. No offers or
  `B`.
- What else moves `offersAt` and `retargetedAt` reaches Emacs through the
  same merge, and has no step of its own: the agent's own offers, the
  offer a listing takes, and another Emacs's `B`. Each is as
  a take or a retarget of yours that Emacs gave up on and the host ran.
- OfferRowGoes excuses a list that came to nothing (failed, timed out,
  dropped for a mutation's reply, or unable to start): the next poll asks
  again, and polls coming round are not in the model. So it says the draft
  asks in a way a list in flight can't swallow, not that the row goes
  whatever fails.
- The variants run with `MaxOver`, `MaxBase` and `MaxShown` 0, as before
  each, but for `NoNewerOffers`, `QuietOfferRefresh`, `NoNewerBranch` and
  `NoNewerShown`. Three requests
  through the helper.
  The variants run smaller.
- Left out: forgetting a host, what is owed to measure
  (`roost--measures-owed`, `roost--measures-due`), back-off and Offline,
  GitHub's stamp, notifications, seen, watching, the remembered files, the
  blocking wait, a helper of another version, two Emacs editing one task,
  and Python's own work (the crash tests and `test_remote.py` cover that).
  Also the refresh `m` asks for at its reply, which starts as `B`'s does;
  asking again for a task with the creation ID it had, which `NewTaskDraft`
  in `what_you_do_in_emacs` has; and how many offers wait, three or a
  conversation's eight, and the project each names: only `offersAt` orders
  replies. Also the fetch of what a task shows (`roost--note-shown`'s and
  `roost-show-image`'s `shown` request, `roost--take-shown`), a request
  that only looks and writes no task: its buffer goes by
  `roost--shown-image-at`, read in the code and not modelled. And Do it
  here on an offer while its draft's task is being made, which sends the
  prompt and makes the task both: the offer waits until then by design.
- A refusal of an action is modelled as a timeout with nothing run: Emacs
  does the same with both. So is a fork refused because the task it would
  go on from went.
- A pass covers the model within its bounds, not roost.el itself.
