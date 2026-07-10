# LfrGit

Liferay git helpers: a safe `git clean`, fork sync from upstream, keeping your
master mirror current, and a quick interactive rebase. Loaded as shell functions
via the root `lfrTools.sh`.

## Per-user config

Copy the example and set your team's fork org (gitignored, so it stays local):

```bash
cp lfr-git.local.conf.example lfr-git.local.conf
# edit LFR_GIT_FORK_ORG
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `LFR_GIT_FORK_ORG` | Your team's fork org on GitHub | (required for sync) |
| `LFR_GIT_UPSTREAM_ORG` | Upstream org to sync from | `liferay` |

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrGitCleanDry` | `lfrgcd` | Preview what `git clean` would remove. Run this first. |
| `lfrGitClean` | `lfrgc` | Remove untracked and ignored files, keeping `*.iml`, `.idea`, and `app.server/build/test.$USER.properties`. |
| `lfrGitSync [org]` | `lfrgs` | `gh repo sync <org>/liferay-portal --source <upstream>/liferay-portal`. `org` defaults to `LFR_GIT_FORK_ORG`. |
| `lfrGitSyncEE [org]` | `lfrgse` | Same for `liferay-portal-ee` master. |
| `lfrGitRebase [N]` | `lfrgr` | `git rebase -i HEAD~N` (N defaults to 20). |
| `lfrGitUpdateMaster [-r] [-f] [-p] [remote]` | `lfrgum` | Update your fork's master from `<remote>/master`, keep your local master current (without checking it out), and sync the team fork; `-r` rebases your current branch onto the fresh master (only when it moved), `-f` forces that rebase, `-p` then force-pushes that branch. |

`lfrGitSync`/`lfrGitSyncEE` take an optional fork org to sync a different fork
than the configured `LFR_GIT_FORK_ORG`, e.g. `lfrGitSync my-other-org`.

`lfrGitUpdateMaster` automates the whole after-master-update routine:

1. Fetch `<remote>/master` (the tracking ref only, no tags). It never fetches
   into the local `master` branch, so it works even when `master` is checked out
   in a worktree.
2. Push that commit to your fork's master (its configured push remote, e.g.
   `origin`). If the fork rejects it as non-fast-forward, force-update it with
   `--force-with-lease` (upstream rewrote master, so the fork's copy is stale).
3. Sync the team fork: `lfrGitSync`, or `lfrGitSyncEE` when the repo's remotes
   point at `liferay-portal-ee` (detected by remote, not folder name, so an
   EE worktree named `liferay-portal-7.4.x` is still handled).
4. Update your local `master` to `<remote>/master` too — creating or resetting
   it as needed, which heals a mirror stranded by an upstream master rewrite —
   unless `master` is checked out in a worktree, in which case it says so and
   leaves it (never checking it out).
5. With `-r`/`--rebase`, rebase your current branch onto `<remote>/master` (run
   last, so a rebase conflict does not block the sync). The rebase is skipped
   when master did not move, so a no-op rebase never churns commit dates;
   `-f`/`--force-rebase` (implies `-r`) runs that rebase anyway.
6. With `-p`/`--push` (implies `-r`), force-push the rebased branch to its fork
   with `--force-with-lease`, to update your PR. Skipped if the rebase stops on
   a conflict.

Rebase is off by default, so a plain run just keeps your master mirror current.
The local branch it updates is the `master*` branch that tracks `<remote>/master`
(plain `master` for the default `upstream`). To mirror a different remote, e.g.
`lfrGitUpdateMaster brian`, a local `master*` branch must already track
`brian/master`; set one up first with `git branch --set-upstream-to=brian/master
masterBrian`. Without such a branch the tool falls back to plain `master` and
would overwrite it, so do not run it against a non-default remote until the
mirror branch is tracking that remote. The remote-side branch is always
`master`.

`lfrGitClean` and `lfrGitCleanDry` accept extra `git clean` arguments, e.g.
`lfrGitClean modules/apps/some-app`.
