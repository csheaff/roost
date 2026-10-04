# Submitting to MELPA

Roost depends on tmux-control, so tmux-control goes first; submit Roost once
tmux-control is on MELPA. Each submission is a pull request to
[melpa/melpa](https://github.com/melpa/melpa) adding one file under `recipes/`.

## Recipes

`recipes/tmux-control`:

```elisp
(tmux-control :fetcher github :repo "csheaff/tmux-control")
```

`recipes/roost`:

```elisp
(roost :fetcher github :repo "csheaff/roost"
       :files (:defaults ("scripts" "scripts/roost_remote.py")))
```

Roost's `:files` matter: Roost copies `scripts/roost_remote.py` to each host,
and finds it next to `roost.el`. The default file list includes only Emacs
Lisp, so without it a MELPA install would have no helper.

## Status (2026-10-04)

Both recipes were built with MELPA's `package-build`. The Roost archive holds
`roost.el` and `scripts/roost_remote.py`; the tmux-control archive holds
`tmux-control.el`, which needs no other file.

| Check | tmux-control | Roost |
| --- | --- | --- |
| `package-lint` | Clean after [tmux-control#153](https://github.com/csheaff/tmux-control/pull/153) moved `C-c x`, a key reserved for users | Only "tmux-control is not installable", which clears once tmux-control is on MELPA |
| Byte compilation | No warnings | No warnings |
| `checkdoc` | 73 advisory notes, mostly messages starting with "tmux-control:" and keys written into docstrings | 3, all false positives |
| Tests | 302 ERT, source and compiled, in CI | 85 ERT and 66 Python lifecycle tests |

MELPA's reviewers also run [melpazoid](https://github.com/riscy/melpazoid);
run it on each package before submitting, and expect requests about the
checkdoc notes.

## Before submitting Roost

- Confirm that tmux-control's recipe merged and that `M-x package-install`
  finds it.
- Re-run `package-lint` on `roost.el`; the dependency error should be gone.
- MELPA builds from the default branch. Tags (`v0.7.0`) feed MELPA Stable.
