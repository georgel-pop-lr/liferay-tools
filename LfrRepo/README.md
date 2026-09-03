# LfrRepo tools

A small set of shell functions for working with Liferay git repos scattered
across more than one root directory. `lfrRepo` (short alias `lfrr`) jumps between
clones without typing full paths; `lfrWorktree` (short alias `lfrw`) spins up a
worktree for a branch (new off a base ref, or an existing one checked out),
wired to a bundle and database of its own, and `lfrWorktreeRemove` (short alias
`lfrwr`) takes all three away again, IntelliJ's project state included.

Both load via the top-level `lfrTools.sh` aggregator (see the repo's top-level
README). They are shell functions, so they must be sourced, not executed: a
script runs in a subshell and its `cd` would not reach your interactive shell.

## Contents

| File | Purpose |
|---|---|
| `lfr-repo.sh` | Defines the `lfrRepo` switcher and its tab-completion. |
| `lfr-worktree.sh` | Defines the `lfrWorktree` creator, the `lfrWorktreeRemove` remover, `lfrWorktreeIdeaClean` for IntelliJ leftovers, and `lfrWorktreeIdeaInit` for giving a worktree an IntelliJ project. |

The repo list, picker, and per-user config live in the shared module
`../LfrCommon/lfr-repo-list.sh` (config in `../LfrCommon/repos.local.conf`),
since `lfrCache` reuses the same picker. `lfr-worktree.sh` also uses
`_lfrRepoBundleDir` from `../LfrBuild/lfr-ant.sh` to resolve a worktree's
bundle, so LfrBuild must be loaded too (the aggregator loads everything).

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
shows the branch it has checked out and its root in parentheses, so repos that
share a name across roots (such as two `liferay-portal` clones) stay
distinguishable, and a worktree sitting on a branch other than the one its
directory is named after is visible before you jump into it.

```
liferay-portal-LPD-98055    @LPD-100568   (/media/georgelpop/Data/liferay/repos)
```

The branch is part of what the picker searches, so `lfrRepo LPD-100568` finds
the checkout above. A query that matches exactly one repo *name* still wins
outright, so `lfrRepo master` goes to the `masterBrian` clone rather than
opening a picker over every repo parked on `master`.

| Invocation | Behavior |
|---|---|
| `lfrRepo` | Open the picker over every repo in all roots. |
| `lfrRepo <name>` | Jump straight to the only match; with more than one match, open the picker prefiltered by `<name>` (fzf; the numbered fallback lists everything). |
| `lfrRepo -l`, `lfrRepo --list` | List every repo with its branch and its root, without changing directory. |
| `lfrRepo <prefix><Tab>` | Tab-complete repo names. |

```bash
lfrRepo                 # pick interactively
lfrRepo portal          # filter to repos matching "portal"
lfrRepo -l              # just list, stay put
```

Repos whose names match a `LFR_REPO_PRIORITY` prefix float to the top of every
listing.

### `lfrWorktree`: create a worktree

Creates a git worktree for a branch, then `cd`s into it. Run it from inside
any `liferay-portal` clone. The worktree goes under `LFR_WORKTREE_ROOT`
(created if missing) as `liferay-portal-<branch>`.

| Invocation | Behavior |
|---|---|
| `lfrWorktree <branch>` | New branch off `LFR_WORKTREE_BASE` (`upstream/master` by default) at `liferay-portal-<branch>`, then `cd` in. If the branch already exists it is checked out instead, and any base argument is ignored. |
| `lfrWorktree <branch> <base-ref>` | Same, but branch off the given base ref: a local branch, a `<remote>/<ref>`, or a sha. |

```bash
lfrWorktree LPD-12345                  # branch LPD-12345 off upstream/master
lfrWorktree LPD-12345 upstream/7.4.x   # branch off a different base
```

A `<remote>/<ref>` base is fetched first so the branch starts current, but only
when the leading segment is a real configured remote; otherwise the whole value
is treated as a local ref (so a branch literally named `feature/x` works) and
must resolve.

It refuses to run when no branch is given, when not inside a git repo, when
the target directory already exists, or when the base ref does not resolve,
leaving no half-made worktree behind; an existing branch already checked out
elsewhere is refused by git itself. Because the new directory is named
`liferay-portal-*`, it shows up at the top of `lfrRepo` alongside your other
portal clones.

Whether the branch is new or already existed, the invoking clone's per-user
(gitignored) `*.${USER}.properties` are copied in with any
`bundles/liferay-bundle-<x>` path repointed to `bundles/liferay-bundle-<branch>`
(a path not matching that pattern is copied unchanged), so the worktree deploys
to and tests against its own bundle. That bundle directory is created too, with
the invoking bundle's `portal-ext.properties` copied in and its
`jdbc.default.url` pointed at `portal-<branch>`, lowercased, so the two bundles
never share one database. The PostgreSQL database itself is created for you when
`psql` can reach the server (UTF8, from `template0`); with a non-Postgres URL,
no `psql`, or an unreachable server it prints a note and leaves it to the first
startup. Slashes in a branch name become dashes in both the bundle directory
and the database name.

A bundle directory already sitting at that path is what an
`lfrWorktreeRemove --keep-bundle` leaves behind, and it used to be adopted in
silence: its `portal-ext.properties` was left alone however stale it had become,
and its database was reused with the previous incarnation's data in it, so the
fresh checkout booted on old data. It is now reported and put to you:

```
lfrWorktree: /media/.../bundles/liferay-bundle-LPD-12345 already holds a bundle from an earlier worktree
  Size     : 3,4G, built (tomcat-10.1.57)
  Config   : portal-ext.properties written 2026-08-11 09:12, differs from /home/.../liferay-bundle-master in 3 properties
  Database : portal-lpd-12345, still holding that bundle's data
lfrWorktree: reuse it as it is? (n moves it aside and wires a fresh one) [y/n]
```

The drift count compares the two `portal-ext.properties` files sorted and
without the two properties that are meant to differ per bundle,
`jdbc.default.url` and `portal.instance.inet.socket.address`, and counts by
property, so one whose value changed counts once. Answer `y` and it is reused as
before. Answer `n` and it is moved to `<dir>.old-<timestamp>`, so nothing is
deleted, and a fresh bundle is wired in its place; the database keeps that name
and its data, so reset it with `lfrBundle -c` or drop it with `dropdb`. Only
`y` and `n` are accepted and anything else asks again, through the shared
`_lfrConfirm`. With no terminal to ask
at it is reused, which is what every run before the prompt did, and the lines
above are printed as the warning that was missing.

Last, once you are standing in the worktree, it offers `lfrWorktreeIdeaInit`:

```
lfrWorktree: create the IntelliJ project too, with the debug profiles (about 17s)? [y/n]
```

The copy stays a command of its own because a worktree you only build from
should not pay those seconds, so the question is asked rather than answered
either way. Set `LFR_WORKTREE_IDEA=1` to always run it and `0` to never ask,
which is also what a scripted run needs, since with no terminal the prompt is
skipped and the command is named instead.

### `lfrWorktreeRemove`: remove a worktree

Undoes an `lfrWorktree`: removes the worktree, deletes its branch, deletes the
bundle directory that came with it, and makes IntelliJ forget the project. Run
it from any other worktree of the same repo.

| Invocation | Behavior |
|---|---|
| `lfrWorktreeRemove <branch>` | Remove the worktree, delete the branch, and delete the bundle when it is empty or holds nothing but the `portal-ext.properties` `lfrWorktree` created. |
| `lfrWorktreeRemove <branch> --force` | Same, but also when the worktree has changes or the branch is unmerged. |

```bash
lfrWorktreeRemove LPD-12345            # remove worktree, branch, unused bundle
lfrWorktreeRemove LPD-12345 --force    # discard changes and delete unmerged
```

Every deletion here is destructive, so it is deliberately cautious. It finds
the worktree by the branch it has checked out rather than by guessing the path,
and refuses when a Tomcat is running out of that bundle, when the branch looks
like a `master` branch, or when the branch is the one checked out where you ran
it. A bundle holding more than that one properties file is kept and reported,
`--force` included, since a built bundle is work this command never did. The
database is always left alone, its name printed so you can drop it yourself
(e.g. `dropdb portal-<branch>`).

### `lfrWorktreeIdeaClean`: forget worktree projects that are gone

A worktree's `.idea` and `*.iml` go with the directory, but IntelliJ keeps the
rest of a project's state elsewhere, so removing a worktree used to leave it
behind: the Welcome screen kept offering a path that no longer exists, and about
26 MB of caches per Liferay worktree stayed on disk. `lfrWorktreeRemove` now
clears all of it per IDE version. From the config: the `recentProjects.xml`
entry, the `trusted-paths.xml` entry, the `workspace/<id>.xml` that entry names,
the path's line in `other.xml`'s `file.chooser.recent.files` (the Open File
dialog's own history), and the `tasks/<name>.{tasks,contexts}.zip` pair.

A cache is found by hash, not by name: the hash is Java's `String.hashCode` of
the project's absolute path in hex, and every per-project cache carries it in its
own name whatever directory it sits in. Two projects can share a name (a
`liferay-portal` clone plus another one on a second drive), and only the hash
tells their caches apart. Matching on the hash rather than on a list of
directories is also what stopped this missing the ones nobody had thought to
list: `projects`, `compiler`, `editor`, `fileHistory`, `conversion`,
`frameworks/detection`, `index/index-file-filters` (3.5 MB a project, the largest
of them), `index/dirty-file-queues`, `log/indexing-diagnostic`, `Maven/Projects`,
`semantic-search`, `testHistory`, `vcs-log` and `vcs-users` are all covered by
the one rule, along with whatever a later IDE version adds.

The task state is the exception, keyed by the project's directory name with every
non-alphanumeric turned into an underscore, so it is addressable by neither the
path nor the hash.

A running IntelliJ is the one thing that stops either command, because it rewrites
its options from memory on exit and would put the entry straight back. Both now offer
to close it rather than only refusing:

```
lfrWorktreeRemove: IntelliJ is running and would write the projects back on exit. Close it now? [y/n]
```

Answer yes and it sends SIGTERM, never SIGKILL, so the IDE shuts down the way its own
menu item does and saves open files, then waits for the process to actually disappear.
That wait is the real barrier, since the options are written before the exit. It gives
up after 60 seconds, which usually means the IDE is asking about unsaved work.

Answer no and nothing of IntelliJ's is touched; `lfrWorktreeRemove` still removes the
worktree, the branch and the bundle, and `lfrWorktreeIdeaClean` finishes the other half
whenever you close the IDE. Only `y` and `n` count, so a bare Enter or a typo asks
again rather than deciding for you. With no terminal to ask at, a script or a pipe,
there is no prompt and both fall back to refusing.

`lfrWorktreeRemove` asks before it removes anything, since the useful answer can be
"let me close it myself first" and being asked that once the worktree is gone is no
use.

Worth knowing why this is new: the check used to look for `com.intellij.idea.Main` in
the process list, and from 2024.2 the IDE is a native launcher that loads the JVM
in-process, so that string never appears. The guard was dead on 2024.3 and every
removal quietly had its work undone on the next IDE exit.

| Invocation | Behavior |
|---|---|
| `lfrWorktreeIdeaCleanDry` | List every worktree project IntelliJ still offers whose directory is gone. Deletes nothing. |
| `lfrWorktreeIdeaClean` | Clear the state of those projects. Offers to close IntelliJ first when it is running. |

```bash
lfrWorktreeIdeaCleanDry                # preview the leftovers
lfrWorktreeIdeaClean                   # clear them
```

A missing directory alone is not enough to call a project a leftover, so three
things have to hold. It sits directly in `LFR_WORKTREE_ROOT`, where `lfrWorktree`
puts every worktree, so a deleted clone kept elsewhere is none of this command's
business. Its name is one `lfrWorktree` makes (`liferay-portal-<branch>`), never a
clone itself. And that root is mounted: with the Data drive unmounted every
project on it is missing, and forgetting all of them over an unmounted drive is
the one failure this command must not have.

### `lfrWorktreeIdeaInit`: give a worktree the IntelliJ project a clone has

The mirror of the command above. A fresh worktree opens in IntelliJ as a bare
directory, because almost none of the project model is tracked: of the 3862
`.iml` files a configured `liferay-portal` carries, 10 are in git, and `/.idea`
is gitignored outright. This copies the model across from a clone that already
has one, so the worktree opens configured.

What travels is path-independent, which is why this works at all: `modules.xml`
is written in `$PROJECT_DIR$` terms, the `.iml` files in `$MODULE_DIR$` ones, the
libraries point at the shared `~/.gradle` caches, and a `Remote` debug
configuration holds nothing but a host and a port.

| Invocation | Behavior |
|---|---|
| `lfrWorktreeIdeaInit` | Set up the worktree you are in. |
| `lfrWorktreeIdeaInit <branch\|dir>` | Set up that worktree. |
| `lfrWorktreeIdeaInit <branch\|dir> <src>` | Copy the project from that clone instead. |
| `lfrWorktreeIdeaInit <branch\|dir> --redo` | Replace the project it already has. Without this it refuses rather than write over one. |

```bash
lfrWorktree LPD-12345                  # create the worktree
lfrWorktreeIdeaInit                    # and give it the project
```

The run configurations are written to `.idea/runConfigurations`, one file each,
which is IntelliJ's shared form: it reads them from there and shows them in the
picker, so nothing has to be written into the `workspace.xml` the IDE owns and
rewrites from memory. The `Debugg portal 8000` profile is the one to attach with,
8000 being the JPDA port `start-liferay.sh --debug` takes first.

Left out on purpose: the data sources and their cached schema, which point at the
source bundle's database and are most of the size (38 MB against the 6.6 MB the
model itself takes); the shelf, which holds the source clone's own shelved
changes; a template or throwaway run configuration; and any run configuration
bound to a registered application server (the Tomcat ones), since that
registration names the source clone's bundle and would start the wrong one.
The files the target tracks in git keep the branch's own version, and every other
`.iml` the source has is overwritten, so a `--redo` off a different clone really
replaces the project instead of merging the two. An `.iml` only the previous
source had is left where it is, unreferenced by the new `modules.xml` and ignored.
IntelliJ still indexes the project the first time it opens it.

The source defaults to `LFR_IDEA_TEMPLATE`, else `liferay-portal` in the worktree
root. Set `LFR_IDEA_TEMPLATE` whenever the clone sitting in that root is not the
one carrying your run configurations, which is the whole point of the copy: with
`LFR_WORKTREE_ROOT` on a second drive the fallback picks that drive's clone, and a
clone you have never set run configurations up in copies none.

The `.iml` scan takes the best part of a minute on a Liferay tree, so the command
says what it is doing before each slow step rather than going silent.

All five commands accept `-h`/`--help`.

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
| `LFR_IDEA_TEMPLATE` | `liferay-portal` in `LFR_WORKTREE_ROOT` | yes | The clone `lfrWorktreeIdeaInit` copies the IntelliJ project from. |
