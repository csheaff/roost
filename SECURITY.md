# Security policy

## Reporting a vulnerability

Please report security issues privately, with the
[**Report a vulnerability**](https://github.com/csheaff/roost/security/advisories/new)
button on the repository's Security tab, rather than in a public issue.
Roost has one maintainer, so replies are best effort, but security reports
come first.

## Supported versions

Fixes land on `main`, and in the next release. Please check against
`main` before reporting.

## What Roost is not

Roost is not a sandbox. Each agent runs as you, in its task's worktree,
with your permissions and credentials on its host. What it may do without
asking is what its own permission prompts allow, as when you run it
yourself, and Roost never answers those prompts. A remote host you add is
trusted as any SSH login is: Roost runs its helper there, and its agents
can do there what you can.

The manual's [Security](docs/manual.md#security) section lists what Roost
runs and where, the files it keeps, what it reaches over the network, and
what it never does, each a claim you can check against the code.

## Threat model / what to look for

These are the inputs that someone else could shape, and so the places most
worth scrutiny:

- **A repository you open.** Roost reads two values from its
  `.dir-locals.el`, `roost-setup-command` and `roost-teardown-command`,
  both shell commands, which Emacs counts as risky and asks about. It runs
  Git there, so the repository's Git hooks run as they would for you, and
  it copies the ignored files that the repository's `.worktreeinclude`
  lists into each new worktree. Branch and task names become Git refs,
  folder names and tmux window names.
- **What a remote host's helper returns.** Emacs parses the helper's JSON
  replies and shows what they hold. A host should not be able to run code
  in your Emacs or reach files on this machine.
- **What agents report.** Hook payloads, and the transcripts the helper
  reads for an agent's latest reply and what it asks, are written by the
  agent, and through it by anything it read.
- **What GitHub says.** Pull request titles, checks and review comments,
  and issues, come from `gh`. An issue's text becomes a task's prompt as
  written; Roost shows it in the draft before the agent gets it.
- **Pane content.** An agent's terminal output reaches Emacs through
  [tmux-control](https://github.com/csheaff/tmux-control) and the Eat
  terminal emulator.

In scope: a way for any of these to run code, inject a command or its
arguments, read or write files they shouldn't, send data off the machine,
delete commits or uncommitted work without the typed confirmation that
discarding asks for, or crash or hang Emacs. What an agent does with the permissions you give it
is for its own prompts and settings.

## Automated checks

CI runs with a read-only token, and its actions are pinned to commit SHAs.
Dependabot keeps those actions current, OpenSSF Scorecard scores the
repository each week, and GitHub's secret scanning blocks a push that
holds a secret it recognises. `main` takes changes only through pull
requests that pass CI with every review thread resolved, and can't be
force-pushed or deleted.
