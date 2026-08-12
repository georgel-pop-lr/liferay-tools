# LfrGit

Liferay git helpers: a safe `git clean`, fork sync from upstream, keeping your
master mirrors current, and rebasing your branch onto one of them without
dragging the other's history along. Loaded as shell functions via the root
`lfrTools.sh`.

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
| `LFR_GIT_UPSTREAM_REMOTE` | Remote `lfrGitUpdateBranch` and `lfrGitCheckoutTag` take release branches and patch tags from | `upstream` |
| `LFR_GIT_MASTER_MIRRORS` | Master mirrors `lfrGitUpdateMaster` keeps current, as `branch:remote` pairs | `("master:upstream")` |
| `LFR_GIT_REBASE_MAX` | Most commits a rebase may replay before it is refused | `50` |

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrGitCleanDry` | `lfrgcd` | Preview what `git clean` would remove. Run this first. |
| `lfrGitClean` | `lfrgc` | Remove untracked and ignored files, keeping `*.iml`, `.idea`, and your `app.server.$USER.properties`, `build.$USER.properties`, and `test.$USER.properties`. |
| `lfrGitSync [org]` | `lfrgs` | `gh repo sync <org>/liferay-portal --source <upstream>/liferay-portal`. `org` defaults to `LFR_GIT_FORK_ORG`. |
| `lfrGitSyncEE [org]` | `lfrgse` | Same for `liferay-portal-ee` master. |
| `lfrGitRebase [N]` | `lfrgr` | `git rebase -i HEAD~N` (N defaults to 20). |
| `lfrGitRebaseOnto [target]` | `lfrgro` | Replay only the current branch's own commits onto `target` (default `upstream/master`), dropping the mirror history it was rebased onto in between. The fix for a branch that ended up on `masterBrian` and belongs on `master`. Updates no mirror and syncs no fork. |
| `lfrGitUpdateMaster [-r] [-f] [-o] [-p] [rebase-target]` | `lfrgum` | Update each mirror configured in `LFR_GIT_MASTER_MIRRORS` from its `<remote>/master` (e.g. `master` from upstream, `masterBrian` from brian) and sync the team fork; `-r` rebases the current branch onto a target (default `upstream/master`, or pass a remote/branch), `-f` forces the rebase (implies `-r`), `-o` cuts at the branch's own fork point (implies `-r`), `-p` force-pushes it after (implies `-r`). A target without `-r` is an error. |
| `lfrGitUpdateBranch [branch] [-n]` | `lfrgub` | Update one branch (e.g. `release-2026.q1`) from upstream and push it to your fork. The branch defaults to the one you are on, and is created locally when you do not have it. `-n` skips the push. |
| `lfrGitCheckoutTag <tag> [branch] [-n]` | `lfrgct` | Check out a tag (e.g. `2026.q1.8`, `fix-pack-de-85-7010`) on a local branch: fetch the tag from upstream, branch off it, push the branch to your fork. The branch defaults to the tag's name and is reused when it exists. `-n` skips the push. |

`lfrGitSync`/`lfrGitSyncEE` take an optional fork org to sync a different fork
than the configured `LFR_GIT_FORK_ORG`, e.g. `lfrGitSync my-other-org`.

`lfrGitUpdateMaster` keeps your master mirrors current in one run. The mirrors
are the `branch:remote` pairs in `LFR_GIT_MASTER_MIRRORS` (default
`("master:upstream")`), so `("master:upstream" "masterBrian:brian")` maintains
both `master` and `masterBrian`.

1. For each configured `branch:remote` pair (e.g. `master:upstream`,
   `masterBrian:brian`): fetch `<remote>/master` (no tags), push it to the
   branch's push remote (its `@{push}` remote, falling back to `origin`) under
   `<branch>` (creating the branch on the fork if missing, and forcing with
   `--force-with-lease` if the fork diverged because the source rewrote master),
   and update the local `<branch>` to it, wherever it is checked out:
   - not checked out anywhere: the ref is moved straight to the target, even
     when it has diverged (a mirror is a pure copy, so a divergence is the
     source's own rewritten history, and it is reset to the target).
   - checked out here: fast-forwarded in place, so your files move with it.
   - checked out in another worktree: the fast-forward runs *inside* that
     worktree (`git -C <worktree> merge --ff-only`), so its ref, index, and files
     move together. Moving the ref from here instead would leave that worktree's
     HEAD on the new commit with the old files, i.e. every changed file showing up
     as a local modification, which is why git refuses it outright.

   So a mirror ends up current no matter which worktree you run from. Two cases
   are still left for you, both reported, and only where the mirror is checked
   out: the source rewrote master (the checked-out mirror has diverged, and only
   a `reset --hard` fixes it, which drops commits), and a fast-forward git itself
   refuses because local changes in that worktree are in the way. Unrelated
   local edits there are fine and are carried across.
2. Sync the team fork: `lfrGitSync`, or `lfrGitSyncEE` when the repo's remotes
   point at `liferay-portal-ee` (detected by remote, not folder name).
3. With `-r`/`--rebase`, rebase the current branch onto a target, skipped when you
   are on a `master*` mirror. The target defaults to `upstream/master`; pass a
   remote (e.g. `lfrGitUpdateMaster -r brian` -> `brian/master`) or a branch (e.g.
   `lfrGitUpdateMaster -r masterBrian`) to rebase onto Brian's line instead. The
   rebase is skipped when the branch already sits on the latest target;
   `-f`/`--force-rebase` forces it, and `-p`/`--push` (implies `-r`) then
   force-pushes the rebased branch with `--force-with-lease`.

## Release branches and patch tags

The two refs a backport is built on, each in one command instead of the fetch
plus checkout dance, and neither one needing you to have the ref locally first:

```bash
lfrgub release-2026.q1        # update the release branch, push it to your fork
lfrgct 2026.q1.8              # branch off the patch tag and check it out
lfrgct fix-pack-de-85-7010 LPD-94368-fix-pack-de-85-7010
```

`lfrGitUpdateBranch` is `lfrGitUpdateMaster` for one ordinary branch: it fetches
`upstream/<branch>` (no tags), moves the local branch to it wherever that branch
is checked out, and pushes the fetched commit to your fork. Without an argument
it takes the branch you are standing on; a `master*` mirror is refused and sent
to `lfrGitUpdateMaster`, which also syncs the fork and can rebase. A branch you
do not have locally is created from upstream, which is the usual case the first
time you touch a release branch.

It treats the branch as a pure mirror, so a local `release-*` that has diverged
is reset to upstream. Keep your own commits on a branch of their own.

`lfrGitCheckoutTag` fetches the one tag ref into `FETCH_HEAD` (writing no local
tag), branches off it, and pushes that branch to your fork with `-u`, so a later
plain `git push` lands in the right place. The branch is named after the tag
unless you name it. An existing branch of that name is checked out as it is,
never moved, since by then it carries the commits you cherry-picked; when it is
no longer at the tag you get told, with the `git reset --hard <sha>` that would
put it back.

Both refuse a missing ref (`upstream has no branch release-nope`), and `-n` /
`--no-push` does the local half only.

Every ref inside `lfrGitCheckoutTag` is spelled `refs/heads/<branch>`, and it
switches with `git switch` rather than `git checkout`, because the branch is
normally named after the tag and the tag is already in the repo (79313 of them
in `liferay-portal-ee`). A bare name resolves to the tag first, since
`git rev-parse` tries `refs/tags` before `refs/heads`: that made `git push -u
origin <name>` fail outright with "matches more than one", and made
`git checkout <name>` warn that the refname is ambiguous.

## Only your own commits ever move

`git rebase <target>` always cuts at `merge-base(target, HEAD)`, and that is the
wrong cut for a branch you once rebased onto a different mirror. `masterBrian`
runs hundreds of commits ahead of `upstream/master`, so a branch built on it has
all of those sitting between `upstream/master` and your work:

- `-r` alone saw `upstream/master` was already an ancestor and reported
  `nothing to rebase`, leaving the branch on Brian's line.
- `-r -f` took the same cut and replayed *every* commit after it, rewriting
  hundreds of other people's commits under your name.

So the rebase now finds where the branch really forked: the fork point among all
configured mirrors that leaves the fewest commits to replay. When that differs
from `merge-base(target, HEAD)`, it cuts there with `--onto`, and only your own
commits land on the target. `-o`/`--rebase-onto` forces that cut, and
`lfrGitRebaseOnto` does it on its own without touching the mirrors.

As a backstop, a rebase that would replay more than `LFR_GIT_REBASE_MAX` commits
(default 50) is refused with the command to inspect them: no branch owns that
many, so it means the fork point is wrong. Raise the variable for a run that
genuinely needs it.

List your mirrors in `LFR_GIT_MASTER_MIRRORS`; each is created if missing (locally,
tracking `<remote>/master`, and on your fork), so a fresh clone just needs the
config. A pair whose fetch fails (missing remote, network) is skipped with a
note, as is a malformed pair (anything not `branch:remote`).

Every command accepts `-h`/`--help` and prints this module's usage.

`lfrGitClean` and `lfrGitCleanDry` accept extra `git clean` arguments, e.g.
`lfrGitClean modules/apps/some-app`.
