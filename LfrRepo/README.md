# LfrRepo tools

A small set of shell functions for working with Liferay git repos scattered
across more than one root directory. `lfrRepo` (short alias `lfrr`) jumps between
clones without typing full paths; `lfrWorktree` (short alias `lfrw`) spins up a
new worktree off `upstream/master`, wired to a bundle and database of its own,
and `lfrWorktreeRemove` (short alias `lfrwr`) takes all three away again.

Both load via the top-level `lfrTools.sh` aggregator (see the repo's top-level
README). They are shell functions, so they must be sourced, not executed: a
script runs in a subshell and its `cd` would not reach your interactive shell.

## Contents

| File | Purpose |
|---|---|
| `lfr-repo.sh` | Defines the `lfrRepo` switcher and its tab-completion. |
| `lfr-worktree.sh` | Defines the `lfrWorktree` creator and the `lfrWorktreeRemove` remover. |

The repo list, picker, and per-user config live in the shared module
`../LfrCommon/lfr-repo-list.sh` (config in `../LfrCommon/repos.local.conf`),
since `lfrCache` reuses the same picker.

## Setup

1. Source the top-level aggregator from your shell rc (it defines `lfrRepo`,
   `lfrWorktree`, and the other tools):

   ```bash
   source /path/to/liferay-tools/lfrTools.sh
   ```

2. Create your per-user config from the example and edit it (in `LfrCommon`):

   ```bash
   cp ../LfrCommon/repos.local.conf.example ../LfrCommon/repos.local.conf
   ```

   Set `LFR_REPO_ROOTS` (the directories scanned, in listing order),
   `LFR_REPO_PRIORITY` (name prefixes floated to the top of the picker), and the
   `LFR_WORKTREE_*` defaults. The file is gitignored, so your paths stay local.
   When it is missing, the scripts fall back to built-in defaults.

3. (Optional) Install `fzf` for the fuzzy picker. Without it, the numbered menu
   still works.

## Commands

### `lfrRepo`: jump between repos

Scans each directory in `LFR_REPO_ROOTS` for immediate subdirectories that
contain a `.git` entry, then `cd`s into the one you pick. When
[`fzf`](https://github.com/junegunn/fzf) is installed it drives an interactive
fuzzy picker; otherwise it falls back to a numbered `select` menu. Each entry
shows its root in parentheses, so repos that share a name across roots (such as
two `liferay-portal` clones) stay distinguishable.

| Invocation | Behavior |
|---|---|
| `lfrRepo` | Open the picker over every repo in all roots. |
| `lfrRepo <name>` | Jump straight to the only match; open the picker prefiltered by `<name>` when more than one matches. |
| `lfrRepo -l`, `lfrRepo --list` | List every repo and its root, without changing directory. |
| `lfrRepo <prefix><Tab>` | Tab-complete repo names. |

```bash
lfrRepo                 # pick interactively
lfrRepo portal          # filter to repos matching "portal"
lfrRepo -l              # just list, stay put
```

Repos whose names match a `LFR_REPO_PRIORITY` prefix float to the top of every
listing.

### `lfrWorktree`: create a worktree

Creates a new git worktree and branch, then `cd`s into it. Run it from inside
any `liferay-portal` clone. The worktree is created under `LFR_WORKTREE_ROOT`
as a sibling named `liferay-portal-<branch>`, branched off `LFR_WORKTREE_BASE`
(`upstream/master` by default). When the base ref is qualified as
`<remote>/<ref>`, that remote ref is fetched first so the branch starts current.

| Invocation | Behavior |
|---|---|
| `lfrWorktree <branch>` | Worktree + branch off `upstream/master` at `liferay-portal-<branch>`, then `cd` in. |
| `lfrWorktree <branch> <base-ref>` | Same, but branch off the given base ref instead. |

```bash
lfrWorktree LPD-12345                  # branch LPD-12345 off upstream/master
lfrWorktree LPD-12345 upstream/7.4.x   # branch off a different base
```

It refuses to run when no branch is given, when not inside a git repo, or when
the target directory already exists, leaving no half-made worktree behind.
Because the new directory is named `liferay-portal-*`, it shows up at the top
of `lfrRepo` alongside your other portal clones.

Whether the branch is new or already existed, the invoking clone's per-user
(gitignored) `*.${USER}.properties` are copied in with any bundle path repointed
to `bundles/liferay-bundle-<branch>`, so the worktree deploys to and tests
against its own bundle. That bundle directory is created too, with the invoking
bundle's `portal-ext.properties` copied in and its `jdbc.default.url` pointed at
`portal-<branch>`, lowercased, so the two bundles never share one database. The
database itself is not created: the first startup does that. Slashes in a branch
name become dashes in both the bundle directory and the database name.

### `lfrWorktreeRemove`: remove a worktree

Undoes an `lfrWorktree`: removes the worktree, deletes its branch, and deletes
the bundle directory that came with it. Run it from any other worktree of the
same repo.

| Invocation | Behavior |
|---|---|
| `lfrWorktreeRemove <branch>` | Remove the worktree, delete the branch, and delete the bundle when it holds nothing but the `portal-ext.properties` `lfrWorktree` created. |
| `lfrWorktreeRemove <branch> --force` | Same, but also when the worktree has changes or the branch is unmerged. |

```bash
lfrWorktreeRemove LPD-12345            # remove worktree, branch, unused bundle
lfrWorktreeRemove LPD-12345 --force    # discard changes and delete unmerged
```

All three deletions are destructive, so it is deliberately cautious. It finds
the worktree by the branch it has checked out rather than by guessing the path,
and refuses when a Tomcat is running out of that bundle, when the branch looks
like a `master` branch, or when the branch is the one checked out where you ran
it. A bundle holding more than that one properties file is kept and reported,
`--force` included, since a built bundle is work this command never did. The
database is always left alone, its name printed so you can drop it yourself:
dropping is `start-liferay.sh --reset-db`'s job.

## Configuration

All settings live in `../LfrCommon/repos.local.conf` (gitignored; copy the
`.example`). The shared module sources it, and the `LFR_WORKTREE_*` values also
honor an environment override when the config does not set them.

| Variable | Default | Override via env? | Purpose |
|---|---|---|---|
| `LFR_REPO_ROOTS` | `$HOME/liferay/repos` | no | Directories scanned for repos, in listing order. |
| `LFR_REPO_PRIORITY` | `liferay-portal` | no | Name prefixes floated to the top of the picker, in order. |
| `LFR_WORKTREE_ROOT` | `$HOME/liferay/repos` | yes | Where new worktrees are created. |
| `LFR_WORKTREE_BASE` | `upstream/master` | yes | Default base ref for new branches. |
