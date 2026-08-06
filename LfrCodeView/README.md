# LfrCodeView

Read the code of a change without copying hashes around: `lfrCodeView` lists what
there is to look at in a picker and diffs whatever you select.

Loaded as the `lfrCodeView` shell function (short alias `lfrcv`) via the root
`lfrTools.sh`.

## Commands

| Command | Effect |
| --- | --- |
| `lfrCodeView` | Everything about the current branch: your uncommitted changes, the branch against its base, and one line per commit it adds. |
| `lfrCodeView -a [ticket]` | That ticket's commits on **every** ref instead: the copy on master, the backports on release branches. The ticket defaults to the one in the branch name (`LPD-12345-fix` -> `LPD-12345`). `--all` is the long form; `-h`/`--help` prints usage. |

On a ticket branch that is what you want by default:

```
$ lfrcv
view> local   uncommitted         2 file(s), untracked included
      branch  vs upstream/master  4 commit(s) on top of it
      57a2c45  2026-07-29  LPD-99541 Baseline
      a41e18c  2026-07-29  LPD-99541 Test the language selector renders localized URLs
      3d170e7  2026-07-29  LPD-99541 Link the language selector to final localized URLs
      edd7a01  2026-07-29  LPD-99541 Add a getAlternateURLs overload that keeps the i18n path
```

## What the picker offers

The same picker `lfrRepo` uses (`fzf`, or a numbered menu when `fzf` is missing),
with the highlighted entry previewed in the side pane: a diffstat for a commit
or the branch range, `git status --short` for the local entry. With exactly one
entry, `fzf` auto-selects it and its diff opens without showing the list:

| Entry | Shows |
| --- | --- |
| `local uncommitted` | `git diff HEAD`, then each untracked file as a diff against nothing (`git diff HEAD` cannot see those) |
| `branch vs <base>` | `git diff <base>...HEAD`: everything the branch adds |
| `<sha> <date> <subject>` | `git show <sha>` for one commit, 50 listed at most |

Rows that do not apply are left out, so on a clean worktree you get just the
commits.

## The loop and its toolbar

Both views carry their keys on the bottom line, so there is nothing to remember:

| Where | Toolbar | Keys |
| --- | --- | --- |
| the list | on the picker's bottom border | `↑` `↓` move, `→` or `enter` view the highlighted entry, `←` or `esc` quit |
| a diff | on the pager's bottom line | `←` or `b` back to the list, `q` quit |

The arrows drive the whole thing (right goes in, left comes back out) and the
letters still work, so use whichever you reach for. One `lfrCodeView` reads as
many diffs as you want, in a loop, until you close it. Nothing is written: no
index, stash, or checkout is touched.

Coming back does not lose your place: the list reopens with the cursor on the
entry you just read, not at the top (`fzf --sync --bind start:pos(N)`, with the
line resolved from the entry's value; the numbered fallback has no cursor to
restore). So reading a branch commit by commit is just left, down, right.

Going back works inside the diff itself, without leaving the pager first: `less`
is started with a `LESSKEYIN` file that rebinds `b` and the left arrow to quit
with an exit status of their own (98), which the loop reads as "back to the list"
while `q` still means quit. That needs `less` 582 or newer (`LESSKEYIN` in source
form), which is the pager unless `GIT_PAGER` or `PAGER` says otherwise; with any
other pager the same choice is asked as a one-key prompt right after it exits
(`←`, `b`, or a bare Enter go back; anything else quits; with no interactive
stdin the loop just ends).

Rebinding the left arrow costs only left horizontal scrolling, which wrapped
diffs do not use, and `ESC-(` still does it.

On the `less`-582 path the pager runs without `-F` on purpose, so a diff that
fits on one screen still waits, and without `-X`, so closing it clears the diff
and the list comes back on a clean screen. The fallback default is `less -FRX`,
where a one-screen diff exits immediately and stays on screen.

The list keys and the preview are `fzf`'s. Without `fzf` the list is the numbered
menu `lfrRepo` falls back to, answered with a number; the diff keys work either
way.

There is no ticket filter on the branch listing, on purpose: every commit the
branch adds on top of its base is the change, so the range already says it. The
ticket only matters for `-a`, which has to search all of history.

## Base ref

The branch is compared against the first of these that exists:
`LFR_CODE_VIEW_BASE`, `LFR_WORKTREE_BASE` (from `LfrCommon/repos.local.conf`),
`upstream/master`, `origin/master`, `master`, `origin/main`, `main`. Keep it
fetched (for example with `lfrGitUpdateMaster`) or the commit list drifts.
