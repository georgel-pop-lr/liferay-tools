# LfrCommon

Shared internals for the Liferay tools. Not a command of its own; it is loaded
by the root `lfrTools.sh` and used by `lfrRepo`, `lfrWorktree`, `lfrCache`,
`lfrShare`, `lfrBundle`, and `lfrCodeView`.

## Contents

| File | Purpose |
|---|---|
| `lfr-repo-list.sh` | Sources `repos.local.conf` and sets the `LFR_REPO_*`/`LFR_WORKTREE_*` defaults; owns the shared helpers `_lfrPick` (generic fzf/numbered picker over `value<TAB>label` lines, taking a prompt plus optional prefilter query, preview command, bottom toolbar, and start-cursor value — the last three are fzf-only), `_lfrRepoEntries` (list git repos under the configured roots, labelling each with its checked-out branch when passed `--branch`), and `_lfrRepoPick` (pick a repo). `_lfrPick` is also reused by `lfrShare`, `lfrBundle`, `lfrCache`, and `lfrCodeView`. |
| `lfr-bundle-list.sh` | Owns `LFR_BUNDLES_DIRS`, `LFR_BUNDLES_PRIORITY`, and `_lfrBundleEntries` (list the launchable Tomcat bundles under those roots — empty shells and Wildfly/JBoss bundles are skipped, priority prefixes float to the top), shared by `lfrShare`'s bundle picker and `lfrBundle`'s run/stop toggle. Also owns `_lfrBundleRepoBranches`, which reads every repo's `app.server.<user>.properties` once and emits `<bundle>\t<repo>\t<branch>\t<shared>`, so `lfrBundle` can label each bundle with the checkouts that deploy into it. |
| `repos.local.conf` | Your machine-specific repo roots and worktree settings. Gitignored. |
| `repos.local.conf.example` | Tracked template; copy it to `repos.local.conf`. |

## Per-user config

```bash
cp repos.local.conf.example repos.local.conf
# edit the variables below
```

| Variable | Default | Purpose |
|---|---|---|
| `LFR_REPO_ROOTS` | `$HOME/liferay/repos` | Directories scanned for repos, in listing order. |
| `LFR_REPO_PRIORITY` | `liferay-portal` | Repo-name prefixes floated to the top of the picker. |
| `LFR_WORKTREE_ROOT` | `$HOME/liferay/repos` | Where `lfrWorktree` creates new worktrees. |
| `LFR_WORKTREE_BASE` | `upstream/master` | Default base ref for new branches (also `lfrCodeView`'s default compare base). |
| `LFR_BUNDLES_DIRS` | `$HOME/liferay/bundles`, `/media/$USER/Data/liferay/bundles` | Directories scanned for bundles (`lfrShare`, `lfrBundle`). |
| `LFR_BUNDLES_PRIORITY` | `liferay-bundle-master`, `liferay-bundle` | Bundle-name prefixes floated to the top of the bundle picker. |

`LFR_WORKTREE_ROOT` and `LFR_WORKTREE_BASE` also honor an exported environment
value when the config does not set them; the four array variables are
config-file-only.
