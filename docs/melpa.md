# Submitting to MELPA

Roost depends on Ghostel, which is on MELPA, and ghostel-tmux, which is
not: Roost can go once ghostel-tmux is there. A submission is a pull request
to [melpa/melpa](https://github.com/melpa/melpa) adding one file under
`recipes/`.

## Recipe

`recipes/roost`:

```elisp
(roost :fetcher github :repo "csheaff/roost"
       :files (:defaults ("scripts" "scripts/roost_remote.py")))
```

The `:files` matter: Roost copies `scripts/roost_remote.py` to each host,
and finds it next to `roost.el`. The default file list includes only Emacs
Lisp (`roost.el` and `roost-ghostel-tmux.el`), so without it a MELPA
install would have no helper.

## Status (2026-10-16, for 0.9.0)

Roost was last checked for 0.9.0, when it had one Emacs Lisp file and
depended on another terminal package, so run the checks again before
submitting. The tools were package-lint 20260903.2119, checkdoc, and
[melpazoid](https://github.com/riscy/melpazoid) at 6200dec (2026-10-10), on
Emacs 30.2 and 32.0.50, which gave the same results. melpazoid's Emacs Lisp
checks ran outside its container, with native compilation off as in the
container, and its license and packaging checks on a copy of the
repository. MELPA's `package-build` built the recipe, with the helper in
the archive.

| Check | Result |
| --- | --- |
| `package-lint` | A dependency not on MELPA is "not installable", as ghostel-tmux is now; and that `with-eval-after-load` is for configurations, which `roost-watch-mode` uses to add Roost's sections to Magit once Magit, an optional package, loads |
| Byte compilation and loading | No warnings |
| `checkdoc` | None |
| melpazoid | Hints to avoid `ignore-errors` (25), around lookups and clean-ups allowed to fail, such as Git over TRAMP; and that `;; Author:` gives no address for `lm-authors` to read |
| License | GPL-3.0-or-later, in `LICENSE` and the headers of `roost.el` and the helper: without them melpazoid fails Roost |
| `check-declare` | Only optional packages not installed there (Magit, perspective.el, Evil), and `canvas-refresh`, which Emacs 32 has in C |

MELPA's pull request template asks whether LLMs wrote some of the code, and
if so for an `Assisted-by:` line under each file's `Author:` line, such as
`;; Assisted-by: Claude:claude-opus-5-5`
([CONTRIBUTING.org](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org#attribution-for-ai-generated-code)).
Roost's files have none yet.

## Before submitting

- Confirm that ghostel-tmux's recipe merged and that `M-x package-install`
  finds it.
- Run `package-lint`, checkdoc and melpazoid again, on `roost.el` and
  `roost-ghostel-tmux.el`; the dependency error should be gone.
- Add the `Assisted-by:` line to both Emacs Lisp files and the helper.
- MELPA builds from the default branch, and numbers each build from the
  latest tag, not the Version header: before `v0.9.0` was tagged, it called
  0.9.0 something like 0.8.1.0.20261016.182. Tags also feed MELPA Stable.
