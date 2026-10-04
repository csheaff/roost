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
| `package-lint` | Clean since 0.7.1 ([tmux-control#153](https://github.com/csheaff/tmux-control/pull/153) moved `C-c x`, a key reserved for users, to `C-c C-x`) | Only "tmux-control is not installable", which clears once tmux-control is on MELPA |
| Byte compilation | No warnings | No warnings |
| `checkdoc` | 42 advisory notes since [tmux-control#154](https://github.com/csheaff/tmux-control/pull/154): messages starting with "tmux-control:", keys written into docstrings, and wording-mood suggestions | 3, all false positives |
| melpazoid | Since 0.7.2 ([tmux-control#155](https://github.com/csheaff/tmux-control/pull/155)), no hooks are added at load, and `tmux-control-unload-function` undoes the five top-level `advice-add` calls on Eat, which melpazoid still lists because its check is a pattern | Clean apart from the dependency note |
| Tests | 304 ERT, source and compiled, and 32 live integration scenarios, in CI | 88 ERT and 67 Python lifecycle tests, in CI on Emacs 29.1 and 30.1 |

MELPA's reviewers run [melpazoid](https://github.com/riscy/melpazoid); its
Emacs Lisp checks were run locally for the table above. Run it again before
submitting.

## Before submitting Roost

- Confirm that tmux-control's recipe merged and that `M-x package-install`
  finds it.
- Re-run `package-lint` on `roost.el`; the dependency error should be gone.
- MELPA builds from the default branch. Tags (`v0.7.0`) feed MELPA Stable.
