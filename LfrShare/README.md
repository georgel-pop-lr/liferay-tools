# LfrShare

Point a worktree at a shared, already-built bundle, so several worktrees can use
one bundle instead of each building and keeping its own.

Loaded as the `lfrShare` shell function (short alias `lfrs`) via the root
`lfrTools.sh`.

## Why no build is needed to switch

A built bundle is self-contained (Tomcat + the deployed `ROOT` war and
`osgi/modules`). `app.server.$USER.properties` (`app.server.parent.dir`) is just
a pointer telling a repo which bundle to use. `lfrShare` only rewrites that
pointer, so switching is instant:

- Switch the pointer and start the server: no build.
- To run a specific worktree's code, `gradlew deploy` only its changed modules
  into the bundle (incremental, not a full `ant all`).

## Commands

You pick both the bundle and the repo. With no argument each opens the same
picker `lfrRepo` uses (`fzf`, or a numbered menu); pass a name to prefilter or a
path to skip the picker.

| Command | Effect |
| --- | --- |
| `lfrShare` (no args) | Picker listing each `liferay-portal*` repo and its share state; selecting one **toggles** it: a shared repo is reset, an unshared one is shared (then pick a bundle). Press Esc to cancel without changing anything. |
| `lfrShare share [bundle] [repo]` | Pick a bundle and a repo, point the repo at the bundle. |
| `lfrShare <bundle> [repo]` | Shorthand: bundle by path/name, repo from picker if omitted. |
| `lfrShare status [repo]` | Show which bundle each repo points at. With no repo it lists only `liferay-portal*` repos (the ones that have a bundle); pass a path for any other repo. |
| `lfrShare reset [repo]` | Restore the repo's original bundle config (from the backup made on first share). |

Bundles are discovered/resolved under `LFR_BUNDLES_DIRS` (default
`~/liferay/bundles` and `/media/$USER/Data/liferay/bundles`); export to override.

## How it writes

On first `share` of a repo it backs up `app.server.$USER.properties` to
`app.server.$USER.lfrshare-bak.properties`, then sets an absolute
`app.server.parent.dir`. `reset` restores that backup. The backup is named to
match the portal repo's `app.server.*.properties` ignore rule, so it stays out
of `git status` and Liferay does not read it (it only reads
`app.server.$USER.properties`).

It also repoints the **Gradle** deploy target. The running server uses
`app.server.parent.dir`, but `gradlew deploy` copies into `liferay.home`, which
lives in the generated (git-ignored) `.gradle/gradle.properties`. Setting only
the Ant side leaves that stale, so the server runs the shared bundle while
`gradlew deploy` silently writes into the checkout's own `../../bundles`. So
`share` also rewrites `liferay.home` (saving the original to
`.gradle/gradle.properties.lfrshare-bak`) and `reset` restores it. `ant
setup-sdk` regenerates `.gradle/gradle.properties` and would revert the line;
re-run `lfrShare share` after a setup-sdk. If the file does not exist yet,
nothing is written: a later setup-sdk derives `liferay.home` from the
already-repointed `app.server.parent.dir`.

## Caveats

A shared bundle runs **one server at a time** (same ports) and holds **one**
database, search index, and OSGi state. Use it for branches of the same schema
(a feature branch off master); switching across different DXP versions risks
schema/upgrade mismatches. Deploying from one worktree overwrites whatever code
was in the bundle.
