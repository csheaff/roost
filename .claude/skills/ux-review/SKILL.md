---
name: ux-review
description: >
  A UX design review of Roost: walk real journeys as particular users,
  gather screenshots and real-agent runs as evidence, and report a short
  ranked list of findings, each with what you see, why it matters and the
  smallest fix, for Clay to choose from before anything is built. Use when
  asked for a UX review, a design review of how Roost looks, reads or
  feels, a walkthrough of the first hour or of a day with many agents, or
  /ux-review. Not for code or architecture review (that is /code-review),
  nor for a list of what changed lately.
---

# UX design review

A UX review starts from what a person is trying to do, not from the code or
from what changed. It asks, journey by journey: where am I, what needs me,
what do I do next, and how do I get back. It ends in decisions for Clay, not
in code: build nothing until he picks.

## 1. Frame it

Say in two or three lines what this review covers, then go.

- **Scope.** The whole product, or an area Clay names (the sidebar,
  finishing a task, remote hosts). For a whole-product review, weight what
  changed since the last one: `git log` since the last "UX review" entry in
  `docs/validation.md`.
- **Personas.** Take two or three:
  - *Clay*: Emacs 32, perspective.el, xah-fly-keys, ef themes following
    macOS, a dozen tasks across this Mac and claylien, reviews in Magit,
    merges by pull request or `m`.
  - *New to Roost*: plain Emacs 30 with Vertico, no workspaces, has used
    Claude Code in a terminal, installs from the README.
  - *Fleet*: eight or more agents on two hosts, judges by checks and the
    agent's reply more than by diffs, works in a narrow frame on a laptop.
  - *Evil*: Doom or evil-collection, normal state by default.
- **Journeys.** Take those the scope touches:
  1. The first hour: install, `roost-doctor`, first task, answer it, review,
     merge.
  2. A morning with five agents: notifications, `n`, the mode line, the
     sidebar, answering in terminals.
  3. Review and reply: `r`, notes with `;`, `@`, what changed since you
     looked.
  4. Finish: `m`, `u` and conflicts, `P` with checks and Copilot's threads,
     `x`.
  5. Coming back: after lunch, after a restart, on the other Mac.
  6. Something goes wrong: a host away, an agent crashed or out of quota,
     a merge that conflicts, a question left open in the minibuffer.
  7. Finding things: `/` search, `l`, the dashboard, `roost-workload`.

## 2. Gather evidence

Every finding needs a screenshot or the exact steps that show it. Leave
Clay's running Emacs, his Roost state and his tmux server alone.

- **`make qa`**, all of it, with nothing else running: two runs at once
  slow each other's GUI sweeps past their limit and make remote runs fail.
  Add `--remote --tuned --popular` for the remote and fleet personas. Then
  look at every screenshot of the journeys in scope: `report.html` maps
  each step to its shot. The checks miss what merely looks wrong.
- **Every state, as text**: `gallery.el` here draws the task panel (docked
  at 44 columns and in the main window), the sidebar, the dashboard and a
  draft for each state of the sweep's gallery, for states QA doesn't reach.
- **Real agents**: `live.md` here starts a scratch Emacs with Claude Code on
  Haiku, here and on claylien. Use it for what a fake agent can't show:
  real replies, startup and permission prompts, timing over SSH.
- **Edges**: a narrow frame (100 columns), light and dark themes, Emacs
  29.1 where a journey touches something version-sensitive.
- **Count**: keys and steps per journey, seconds waiting on a remote host,
  messages that went by unread.

## 3. Lenses

Hold each journey against these:

- **Orientation.** Which task am I on, what waits for me, why. Is the task
  you're on visible, marked, named the same in the sidebar, panel, mode line
  and tmux window?
- **Next step.** One obvious next action, its key named once. A line that
  repeats the next step is noise.
- **Discoverability.** Can the persona find it without the manual: the menu
  (`?`), the panel's next step, help-echo, `C-c ?` in a terminal.
- **Vocabulary.** One word for one thing in views, messages, menus and the
  manual (`seen` is not `looked`; `merges into`, not `integrates into`).
- **Signal and noise.** What fires so often it stops meaning anything, such
  as a line naming every task; what is absent looks different from what
  passed.
- **Recovery.** Errors say what happened and the way out; nothing does
  nothing silently; every view has a way back; nothing holds Emacs.
- **Keys.** Clashes with Evil, xah-fly-keys and Doom; the same key doing the
  same thing in every view; nothing only reachable with `M-x`.
- **Hierarchy.** What the eye lands on first; colour only when it means
  something; text fits the 30-column sidebar and the 44-column panel
  without cutting what tells things apart.
- **Roost's rules.** The agent's own terminal is the interface: no rebuilt
  agent menus, no Roost keys that answer or interrupt it. And "Where
  features stop" in CLAUDE.md.
- **Clay's taste.** Plain, short words about what you see and do; Emacs-
  native; no hype; polish an app would have.

## 4. Findings

For each:

- **What you see**, concretely: the screenshot's path or the steps.
- **Who it hurts, and when**: which persona, which journey, how often.
- **Why it matters**: the lens, in a sentence.
- **The smallest change** that fixes it, and what it costs or risks.
- **How sure** you are: seen once, seen every time, inferred.

Rank by how often it happens times how much it hurts. Keep bugs found along
the way apart: they go through the usual pull request flow. Findings are
Clay's to choose; ideas not taken go to `docs/roadmap.md`.

## 5. Deliver

- In chat: the scope in a line, then at most ten findings, two or three
  lines each, most important first, and what you'd do first. Offer the full
  write-up, with screenshots, as an artifact page.
- In `docs/validation.md`: a "UX review — DATE" entry with the scope,
  personas, journeys, what was found and what Clay chose. The next review
  starts from it.
