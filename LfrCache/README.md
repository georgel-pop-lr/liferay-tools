# LfrCache

Share one Gradle build cache across Liferay repos and worktrees, so you build
master once and the others reuse its compiled modules instead of rebuilding.

Loaded as the `lfrCache` shell function (short alias `lfrc`) via the root
`lfrTools.sh`.

## How it works

Liferay's build runs Gradle with a per-repo Gradle home
(`-Dgradle.user.home=<repo>/.gradle`) and forces caching on, so by default each
repo caches to its own `<repo>/.gradle/caches/build-cache-1`, not shared.

`lfrCache on <repo>` drops a Gradle init script into `<repo>/.gradle/init.d/`
that sets `buildCache.local.directory` to a shared directory. That init script
is loaded by the Liferay build (Gradle reads `init.d` from its own Gradle home),
so every enabled repo reads and writes the one shared cache.

Only the Gradle (module) layer is cached. The `ant compile` portal core step
(`portal-impl`, `portal-kernel`) is not a Gradle task and is never cached.

Shared cache dir: `LFR_CACHE_DIR`, default
`/media/georgelpop/Data/liferay/gradle-build-cache`. Export it to override.

## Commands

For `[repo]`, pass a path (`.` for the current repo) to use it directly, or a
name to prefilter the picker. Omitted, `on`/`off`/`seed` open the picker,
`status` defaults to the current directory's repo, and `prune` covers every
sharing repo.

| Command | Effect |
| --- | --- |
| `lfrCache` (no args) | Picker listing each repo and its cache state; selecting one **toggles** it (ON to off, off to ON). Press Esc to cancel without changing anything. `lfrCache toggle` is a synonym. |
| `lfrCache on [repo]` | Share the cache: write the redirect init script into the repo and register it in `LfrCache/enabled-repos.txt` (the registry `status` and `prune` read). |
| `lfrCache off [repo]` | Stop sharing: remove the init script and deregister the repo (it falls back to its own local cache). |
| `lfrCache status [repo]` | Show whether the repo shares, all sharing repos, and the shared cache size and entry count. A bare name is not resolved here; pass a path. |
| `lfrCache list` (or `ls`) | List the cache folders on disk: the shared cache plus the local `build-cache-1` of each repo directly under `LFR_REPO_ROOTS`, with sizes and whether it is redirected (orphaned) or standalone. |
| `lfrCache seed [repo]` | Copy a repo's existing `build-cache-1` into the shared dir (preserve already-built entries). |
| `lfrCache prune [repo]` | Delete the orphaned per-repo cache of a sharing repo to reclaim space. With no repo it prunes **all** sharing repos. |

Any command also works with leading dashes (`-on`, `--status`, ...), and
`help`/`-h`/`--help` prints usage.

## How `seed` works

`seed` copies a repo's existing entries INTO the shared dir. It is one-way and
additive: source is `<repo>/.gradle/caches/build-cache-1`, target is the shared
dir, using a no-clobber copy. Entries are files named by a content hash, so an
entry already in the shared dir is skipped; only new ones are added. It never
modifies or replaces the repo's own cache, and it does not create a per-repo
folder. Use it to fold a build that happened BEFORE sharing was turned on into
the shared cache. After `on`, builds write to the shared dir directly, so `seed`
is only for capturing past builds.

## Verifying it is shared

During a build in an enabled repo, the shared dir's entry count should climb
while the repo's own `build-cache-1` stays flat (the build writes to the shared
dir, not the local one). In the Gradle output, reused tasks show `FROM-CACHE`,
and the final summary reports how many tasks came `from cache`.

## One cache, or several

A single build uses exactly one local cache directory. The `-1` in
`build-cache-1` is Gradle's cache format version, not a counter, so it does not
become `-2`/`-3`. You get separate caches by using different directories: repos
pointed at the same dir share; pointed at different dirs they are independent.
`lfrCache` currently uses one shared dir (`LFR_CACHE_DIR`) for everything listed.

## Cleanup

Gradle maintains the shared cache itself: it evicts entries by last-access time
(default `removeUnusedEntriesAfterDays = 7`), running after a build at most once
a day, so it does not grow unbounded. The orphaned per-repo caches left after
`on` are not touched by Gradle; use `lfrCache prune` to remove them.

## Caveats

- `<repo>/.gradle` is wiped by a hard `git clean -xdf` (`lfrGitClean`), which
  removes the init script. Re-run `lfrCache on <repo>` after such a clean.
- Hits only happen for an enabled repo building matching inputs (so a master
  build reuses heavily; a different branch reuses only its unchanged modules).
