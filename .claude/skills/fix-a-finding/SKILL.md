---
name: fix-a-finding
description: >
  Fix a bug one of Roost's TLA+ models found: a finding config under
  test/formal that fails on purpose until the code is fixed. Replay the
  counterexample on the real code as a failing test, fix the code, prove
  the test both ways, fold the fix into the model so its base config covers
  the case, and update the state-machine tables and the changelog. Use when
  asked to fix a finding, a model's counterexample, or a config a
  verify-* skill lists among its findings. Not for looking for new bugs
  (that is the section's verify-* skill), nor for bringing a model back in
  line after other changes (/pstack:maintain-formal-verification-skill).
---

# Fix a finding

Each model under `test/formal/<section>/` has a base config, `Name.cfg`,
that must pass. Every other config must fail on the rule its first line
names (`\* expect: Rule`), and is one of two kinds:

- A **variant** turns off a guard the code has, and shows the rule still
  catches its loss. Variants stay.
- A **finding** is the code as it is, under timings or moves the base
  config leaves out, breaking a rule. It is a bug, kept failing until it is
  fixed. The section's skill lists its findings, each with the switch the
  base config turns on once it is.

This skill takes one finding, or a group one fix closes, to a merged fix.
The section's own skill, `.claude/skills/verify-<section>/SKILL.md`, says
how to run its model, which step stands for which code, and where its sync
commit is kept. Read it first, and follow it where it says more than this.

## Before you start

- One pull request per group, in a worktree of its own branched from
  `origin/main`. Never switch the primary checkout.
- Check that the model still describes the code. List what changed since
  the section's sync commit in the code its table covers (`git log
  SYNC..origin/main -- <files>`, or the section's `covered.py` or
  `changed.py`). A change the model already has, such as the one an earlier
  fix names beside the sync commit, needs only the sync commit moved, as
  step 3 says.
  Anything else, bring the model in line first
  (`/pstack:maintain-formal-verification-skill`): a finding against old
  code proves nothing about the new.
- Run the section's model and see the finding fail as its config says.

## 1. Replay it on the real code

Tell the counterexample as steps in the code's words; `/pstack:statechart`
gives its shortest path. Then write a test that takes the real code through
those steps in that order, and watch it fail on what the rule protects:

- The helper: `test/test_remote.py`. For real Git and tmux, and a request
  sent as Emacs sends it, `test/crash_harness.py`'s `Box`.
- Emacs: `test/roost-test.el`, or `test/roost-sweep-late.el` for a reply
  that comes back late.

Name the test for what should hold, as the others are named.

If the real code doesn't end as the trace does, the model is wrong, not the
code: some step does what the code can't. Fix the model as the section's
skill says, say in a comment which code rules the step out, and report it.
Change no code.

If the finding rests on how something outside Roost behaves, such as sshd
after a dropped connection, or whether an agent waits for its hooks, find
out from a real run first: a `make contract-live` capture, a test against
real SSH. Report what you found, and fix only what it confirms.

## 2. Fix the code

Make the smallest change that closes it. Stop and ask Clay before a fix
that would weaken a rule, change what the user sees beyond the bug, or need
a new option.

Checking again just before acting makes a race's window shorter, not gone.
Say which your fix does. If it only narrows the window, the model keeps the
check and the act as separate steps, the finding still fails, and you ask
before going on.

Watch the test pass. Then prove it both ways: put the bug back, see the
test fail for the reason it should, and take the bug out again.

## 3. Fold the fix into the model

1. Change the step the section's table names, in the code's terms, to do
   what the fixed code does.
2. The finding's config should now pass. Delete it, and turn on its switch
   in the base config, so the base covers the case from now on. A switch
   two findings share goes on once both are fixed.
3. The fix is a new guard. Add a `Break` value that undoes it, and a
   variant config that expects the rule, and see it fail. That keeps the
   rule able to catch the bug coming back.
4. Run `make formal`: every line `ok`. Never weaken a rule or a bound to
   get there.
5. Take the finding out of the section's skill, and change its table where
   the code a step stands for moved.

Squash-merging drops a branch's own commits, so a sync commit must be one
on main. Set it to the commit you branched from, in the skill and in its
`covered.py` or `changed.py` if it has one, and say what your change adds
on top: "with the change to `remove_agent_worktrees` that came with this
line".

Code, test, model and docs go in one commit.

## 4. Docs

- `docs/state-machines.md`: the machine's tables, its transitions and the
  invariant the finding broke (take off a **Broken** mark). In "What could
  go wrong", add the finding's row, or mark it Fixed, with the test's name.
- `CHANGELOG.md`: a line under Unreleased, saying what you saw and now see,
  and what to do when upgrading.

## 5. Check and send

- `make test compile` and `make formal`. Also `make crash` for a change to
  retire, discard, merge, worktree removal or how a task is recorded.
- `/code-review high`, then CLAUDE.md for the pull request, Copilot and
  merging.
- The pull request names the finding and its config, tells the trace in
  plain steps, names the test, and says it was proved both ways.

Done when the test is in the suite and fails without the fix, the finding's
config is gone and its switch on, a variant undoes the fix, `make formal`
says every line is `ok`, and the docs say what the code now does.
