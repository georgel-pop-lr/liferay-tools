# Run bundles

Launcher for Liferay DXP bundles that picks free ports if the defaults are
busy and writes a known-good Elasticsearch configuration on every run.
Useful when you keep several bundles on the same machine and want to start
one without manually editing `server.xml` or hunting for a free port.

## Contents

| File | Purpose |
|---|---|
| `start-liferay.sh` | Launches a bundle with auto-port selection. Rewrites `tomcat/conf/server.xml` in place when the resolved ports differ from what the file holds, after backing it up. |
| `lfr-bundle.sh` | Defines `lfrBundle` (alias `lfrb`): toggles a bundle (start if stopped, stop if running) via a picker or by name, plus `status`, `stop-all`, `cd` (jump to a bundle without starting it), and `upgrade` (run its database upgrade tool). `lfrRunBundle` / `lfrrb` remain as back-compat aliases. |
| `com.liferay.portal.search.elasticsearch7.configuration.ElasticsearchConfiguration.config` | Embedded-Elasticsearch configuration for ES7-era bundles. Regenerated into the bundle's `osgi/configs/` directory on every run (with a per-instance transport port), so search works out of the box without an external Elasticsearch server. |
| `com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config` | Same, for ES8-era bundles. The launcher picks the right one based on the bundle's Elasticsearch sidecar version. |
| `start-liferay.conf` | Machine-specific config (bundle roots and JDK paths). Gitignored — yours alone. |

The config files are referenced relative to the script, so as long as they sit
together you can move the folder freely.

## Setup

1. Clone this repo somewhere on your machine:

   ```bash
   git clone https://github.com/georgel-pop-lr/liferay-tools.git
   cd liferay-tools/LfrBundle
   ```

2. Create your machine config by copying the tracked example, then edit it
   (see [Configuration](#configuration) for the keys):

   ```bash
   cp start-liferay.conf.example start-liferay.conf
   ```

3. Source the Liferay Tools aggregator from your shell rc (see the top-level
   README). That defines `lfrBundle` (short alias `lfrb`; `lfrRunBundle`/`lfrrb`
   are back-compat aliases for it), so you can call it from anywhere:

   ```bash
   source /path/to/liferay-tools/lfrTools.sh
   ```

4. (Only needed for `--clean`) Install a database client on the host — `psql`
   for PostgreSQL or `mysql` for MySQL/MariaDB — so the launcher can drop and
   recreate the database. `docker` is optional and only used as a fallback when
   the database runs inside a container. `jq` is optional too, used only to
   remap Glowroot's web port when the bundle ships `glowroot/admin.json`.

## Configuration

Machine-specific paths live in `start-liferay.conf`, next to the script. It is
**gitignored**, so your local paths never enter the repository — copy the
tracked `start-liferay.conf.example` to create it. The file is sourced as a
bash script, so any bash syntax works; when it is missing the launcher falls
back to built-in defaults and prints a hint.

| Key | Purpose |
|---|---|
| `BUNDLES_DIRS` | Array of directories that hold your Liferay bundles. `start-liferay.sh`'s own picker scans all of them; missing directories are silently skipped. Note: the `lfrBundle` picker uses a separate list, `LFR_BUNDLES_DIRS` from `LfrCommon` (override it in `LfrCommon/repos.local.conf`), so keep the two in sync if you change either. |
| `JDK_8` / `JDK_11` / `JDK_17` | JDK roots by major version. The launcher picks one from the bundle name (see [JDK selection](#jdk-selection-older-bundles-need-older-jdks)); leave a version empty if you never run that family. |
| `JDK_21` | JDK root usable via `--jdk`/`JAVA_HOME` only; the name-based detection never selects it. |
| `JPDA_SUSPEND` | Set to `y` to make `--debug` wait for the debugger before starting (same as `--suspend`). |
| `BUNDLE_DEFAULT` | Optional. A fallback bundle path — largely vestigial now that a bare invocation opens the picker; leave it empty. |

Example:

```bash
BUNDLES_DIRS=(
	"$HOME/liferay/bundles"
	"/media/$USER/Data/liferay/bundles"
)

JDK_8="$HOME/liferay/tools/jvm/jdk1.8.0_251"
JDK_11="$HOME/liferay/tools/jvm/jdk-11.0.22"
JDK_17="$HOME/liferay/tools/jvm/zulu17.x"
JDK_21="$HOME/liferay/tools/jvm/msopenjdk-21-amd64"
```

## Usage

### Pick a bundle interactively (default)

With no bundle path, the launcher opens an interactive picker over every
Liferay-looking bundle across the directories configured in `BUNDLES_DIRS`. It
shows each bundle's parent directory, so bundles that share a name across
locations stay distinguishable:

```bash
./start-liferay.sh           # picker
./start-liferay.sh --pick    # same thing, forced explicitly
./start-liferay.sh --debug   # picker, then debug mode
```

(This is the launcher's own picker. `lfrBundle`/`lfrRunBundle` open the
state-labelled *toggle* picker instead; see
[the `lfrBundle` command](#running-and-stopping-the-lfrbundle-command).)

When [`fzf`](https://github.com/junegunn/fzf) is installed it drives a fuzzy
picker (type to filter, `Enter` to choose); otherwise the launcher falls back
to a numbered menu:

```
bundle> master
  liferay-bundle-master  (/home/me/liferay/bundles)
  liferay-bundle-master  (/media/me/Data/liferay/bundles)
```

The launcher only lists directories that actually contain a Tomcat folder
(top-level `tomcat/`/`tomcat-9.x.y/` or nested `liferay-dxp/tomcat/`), so
half-extracted or non-Liferay folders are skipped. The selected bundle goes
through the same port-resolution and launch path as a manually-passed argument.

`--list` and `-p` are accepted as aliases for `--pick`.

### Run a specific bundle

Pass the bundle path as the first argument:

```bash
./start-liferay.sh /path/to/another/liferay-bundle
```

The path can point at either the bundle root (`liferay-dxp-tomcat-...`) or
its inner `liferay-dxp/` directory — the script auto-detects the Tomcat
folder regardless. Both of the following are equivalent:

```bash
# Bundle root
./start-liferay.sh ${HOME}/liferay/bundles/liferay-dxp-tomcat-2025.q1.14-lts-1748919610

# Inner liferay-dxp/ directly
./start-liferay.sh ${HOME}/liferay/bundles/liferay-dxp-tomcat-2025.q1.14-lts-1748919610/liferay-dxp
```

### Run in debug mode (remote debugger)

Pass `--debug` to start Tomcat with the JVM's JPDA debug agent enabled, so
IntelliJ / Eclipse / VS Code can attach to it:

```bash
lfrBundle <name> -d
./start-liferay.sh --debug /path/to/another/liferay-bundle
```

JPDA listens on port `8000` by default. If `8000` is already taken, the
script bumps to the next free port — same behaviour as the other ports — and
prints the resolved value:

```
Starting Liferay (Ctrl+C to stop; then press f to force-kill if it hangs).
  Editor / portal: http://<LAN-IP>:8080/ (reachable from this machine and other devices on the network)
  Logs           : .../tomcat/logs/catalina.out
  JDK            : .../zulu17...
  Debug attach   : localhost:8000 (transport=dt_socket, suspend=n)

Selected ports:
  HTTP       8080
  SHUTDOWN   8005
  AJP        8009
  HTTPS      8443
  OSGI       11311
  ES-TRANS   9301
  JPDA       8000
```

By default the JVM does **not** suspend on startup (`suspend=n`), so the portal
boots whether a debugger is attached or not. Pass `--suspend` (or set
`JPDA_SUSPEND=y` in `start-liferay.conf`) to make it wait for the debugger
before starting:

```bash
lfrBundle <name> -s
```

Attach from your IDE using:

- Host: `localhost`
- Port: whatever the script reports next to `Debug attach`
- Transport: `dt_socket`

### Running from anywhere

Once you source the Liferay Tools aggregator (`lfrTools.sh`) from your shell rc,
`lfrBundle` (and its back-compat alias `lfrRunBundle`) is available from any
directory:

```bash
lfrBundle
lfrBundle <name> -d
lfrBundle /path/to/bundle
```

These are the toggle (defined in `lfr-bundle.sh`): a stopped bundle is started
through `start-liferay.sh`, a running one is stopped, and flags are forwarded
only on the start path. The launcher resolves its own location internally, so
the bundled Elasticsearch config is still found regardless of where you call
it from.

### Running and stopping: the `lfrBundle` command

`lfrBundle` (alias `lfrb`) is the single entry point, and it toggles: it starts
a stopped bundle or stops a running one, so you never blindly start a second
copy (a bundle cannot run twice safely, since a second instance shares the same
`catalina.base`, database, and OSGi state). A running bundle is a java process
started with `catalina.sh run` (so it carries `-Dcatalina.base=`); that is how
the tool finds running bundles and shows each one's PID, full bundle path (so
same-named bundles across roots stay distinguishable), and the TCP ports it is
listening on (read from `ss`, so auto-picked ports show their real value).

```bash
lfrBundle                # picker over every known bundle with its state; selecting one toggles it. Esc cancels
lfrBundle <name>         # toggle that bundle directly, no picker
lfrBundle <name> -c      # start-flags (here --clean) are forwarded to start-liferay.sh, but only when starting
lfrBundle <name> -t      # start as a testIntegration target (exposes the test connectors)
lfrBundle status         # list running bundles, their ports, and how each was launched

Each running bundle also gets a `run` line naming the flags it was started with,
the JDK it resolved to, and how long it has been up:

```
  PID 1008717 ports: 8005 8080 11311 32763 42763 /media/.../liferay-bundle-LPD-104387
      <- liferay-portal-LPD-104387@LPD-104387
      run -t -c, jdk zulu17.54.21-ca-jdk17.0.13-linux_x64, up 02:05:01
```

That comes from the launcher shell, not from anything written to disk. `catalina.sh`
execs java, so the JVM keeps the pid `start-liferay.sh` backgrounded and the launcher
stays its parent for the life of the bundle, still holding the arguments in its own
command line. Only `--debug` survives into the JVM itself, as `-agentlib:jdwp`, so the
parent is the only place the rest of them exist. A bundle started outside
`start-liferay.sh` has no such parent and gets no `run` line.
lfrBundle stop-all       # stop every running bundle (asks to confirm)
lfrBundle cd [<name>]    # cd to a bundle's Liferay home; never starts or stops anything
lfrBundle upgrade [<name>] [args]   # run a stopped bundle's database upgrade tool
```

`lfrBundle cd` jumps into the bundle to edit `portal-ext.properties`, read
logs, or run a tool by hand. It lands in the Liferay home: the bundle
directory itself, or the nested `liferay-dxp/` of a packaged DXP bundle. With
no name it opens the same state-labelled picker as the toggle.

`lfrBundle upgrade` runs the bundle's
`tools/portal-tools-db-upgrade-client/db_upgrade_client.sh` in the foreground,
so its output streams to your terminal and its interactive shell works; extra
args are passed through to the client. It refuses while that bundle is
running, since the upgrade needs the database to itself.

Start flags are passed through to `start-liferay.sh` when a stopped bundle is
started, and ignored when a running bundle is stopped. Each has a short alias:
`-c` (`--clean`), `-cc` (`--clean-cache`), `-d` (`--debug`), `-s` (`--suspend`),
`-t` (`--test`), `-y` (`--yes`), `-nc` (`--no-clear`), `-j` (`--jdk <path>`),
and `-dbd` (`--db-docker <container>`). Do not forward `--pick`/`-p`: it opens the
launcher's own second picker, whose choice replaces the bundle you just
toggled. Stopping sends `SIGTERM` for a clean JVM shutdown, waits up to 10s,
then `SIGKILL`s anything still alive. The picker lists the launchable Tomcat
bundles under `LFR_BUNDLES_DIRS` (needs `LfrCommon` loaded, with
`LFR_BUNDLES_PRIORITY` names floated to the top); give a path to toggle a
bundle outside those roots. `status`/`ls`, `stop-all`/`stopall`, and
`help`/`-h`/`--help` are synonyms. `lfrRunBundle` / `lfrrb` remain as
back-compat aliases (they now toggle, like `lfrBundle`).

Every entry names the checkouts that deploy into it and the branch each one has
checked out, as `<- <repo>@<branch>`, so you can tell what a bundle is for
without remembering which worktree built it:

```
liferay-bundle-master  (/media/.../bundles)  [RUNNING pid 2977484, ports: 8005 8080 11311 32763 42763]  <- liferay-portal@LPD-102542
liferay-bundle-7.4.x   (/home/.../bundles)   [stopped]  <- liferay-portal-7.4.x@82daaa19f1c91, liferay-portal-ee@master-brian
```

A repo counts as pointing at a bundle when its
`app.server.<user>.properties` resolves `app.server.parent.dir` there, so a
bundle repointed with [lfrShare](../LfrShare/README.md) shows the sharing repo
and is marked `(shared)`: you can see a bundle is someone else's deploy target
before you stop it. A detached HEAD shows the short sha instead of a branch, and
a bundle no repo points at (the downloaded `liferay-dxp-tomcat-*` ones) just
shows its run state. `lfrBundle status` prints the same `<- ` line under each
running bundle.

### JDK selection (older bundles need older JDKs)

Liferay needs the right JDK for its version. If the wrong one is used the
portal crashes on startup with a `NoSuchFieldException: modifiers` (under
JDK 12+) or similar reflection error.

The launcher picks a JDK automatically based on the bundle's name:

| Bundle name pattern | JDK chosen |
|---|---|
| `liferay-portal-6.*`, `liferay-dxp-digital-enterprise-7.0.*`, `liferay-dxp-7.0.*`, `liferay-dxp-7.1.*` | JDK 8 |
| `liferay-dxp-7.2.*`, `liferay-dxp(-tomcat)-7.3.*` | JDK 11 |
| `liferay-dxp(-tomcat)-7.4.*`, `liferay-dxp-tomcat-2023.*`, `liferay-dxp-tomcat-2024.*` | JDK 11 |
| `liferay-dxp-tomcat-2025.*`, `liferay-dxp-tomcat-2026.*` | JDK 17 |
| anything else (dev bundles like `liferay-bundle-master`) | JDK 17 |

The JDK paths come from `start-liferay.conf` (`JDK_8`, `JDK_11`, `JDK_17`,
`JDK_21`); edit that file if your machine keeps JDKs in different locations.
`JDK_21` is never chosen by name detection, only via `--jdk` or `JAVA_HOME`.

To override the detection per-run, use `--jdk`:

```bash
lfrBundle <name> -j ${HOME}/liferay/tools/jvm/jdk-11
./start-liferay.sh --jdk=/path/to/jdk /path/to/bundle
```

Or export `JAVA_HOME` before invoking:

```bash
JAVA_HOME=${HOME}/liferay/tools/jvm/jdk-11 ./start-liferay.sh --pick
```

The launcher logs the chosen JDK and where it came from:

```
Starting Liferay (Ctrl+C to stop; then press f to force-kill if it hangs).
  Editor / portal: http://<LAN-IP>:8081/ (reachable from this machine and other devices on the network)
  Logs           : .../tomcat/logs/catalina.out
  JDK            : /home/.../jdk-11.0.22 (auto-detected for liferay-dxp-7.3.10.u27)
```

### Test mode (`--test`): testIntegration against a live bundle

Pass `--test` / `-t` to turn a bundle into a target for `testIntegration` against
the running server (instead of a managed one the test boots itself):

```bash
lfrBundle <name> -t
```

The test-support bundles (`com.liferay.portal.test`, which exports
`com.liferay.portal.kernel.test`, the `*.test.util` jars, and the Arquillian and
DataGuard connectors) all ship in `osgi/test`, which a normal launcher boot never
scans, so on a bundle that has never had `--test` none of them start. With `--test`
the launcher adds `osgi/test` to `module.framework.auto.deploy.dirs` (via
`portal-ext.properties`) so the whole set is scanned **in place** — exactly what a
managed `testIntegration` boot does. Each connector's `.config` is seeded with a
**per-instance port derived from the HTTP offset**, on every launch, with or without
`--test`:

| HTTP | Arquillian | DataGuard |
|---|---|---|
| 8080 | 32763 | 42763 |
| 8081 | 32804 | 42804 |
| 8090 | 32813 | 42813 |

Because the default 8080 bundle stays on the default `32763`, a managed
`testIntegration` (which targets `32763` unless told otherwise) still works, while
every other bundle lands a whole block higher (`TEST_CONNECTOR_BLOCK`, 40), so
**two live test bundles never clash** on the fixed connector ports. The resolved
port is shown in the startup banner and the ports table, and a
`>>> Arquillian connector listening on port <port>` line is printed once the socket
binds (it binds late in boot).

The block is what keeps the seeded ports out of the **client's** range. A test JVM
listens for results on `32764` upwards (`SocketState._START_PORT`), so the old
`+1` mapping put an 8081 bundle's connector on the very port the client of a run
against the 8080 bundle had already taken, and it died on startup with:

```
ERROR [ArquillianConnector:47] Encountered a problem while using 127.0.0.1:32764.
Shutting down now.
java.net.BindException: Address already in use
```

Run the tests against the printed port:

```bash
gradlew testIntegration --tests <Class> -Dliferay.arquillian.port=32804
```

Without `--test` the launch is lean: the `osgi/test` scan override is removed, so a
plain boot does not add the test infra (nothing is lost, everything stays in
`osgi/test`). The seeded connector ports stay in place though, and dropping them is
what the launcher used to do wrong. Once `--test` has installed the connector, it
lives in the framework state cache (`osgi/state`) and starts on later boots even
without the scan: File Install only uninstalls a bundle whose file went away, and
the jar is still in `osgi/test`. With its config deleted, Declarative Services then
activated it with no properties, i.e. on the hardcoded
`ArquillianConnector._DEFAULT_PORT` (`32763`), which the 8080 bundle already holds,
and the connector's catch runs `System.exit(-10)`. So forgetting `--test` on a
parallel bundle killed its JVM during boot with the same `BindException` shown
above. Keeping the port pinned always makes that leftover connector bind harmlessly
on this bundle's own port.

So `--test` is still the flag that puts the test infra on a bundle: pass it the first
time, and again after `--clean` / `--clean-cache`, both of which wipe `osgi/state`
and take the installed test bundles with it. In between, the state cache carries them
across plain launches, but that is a side effect rather than something to rely on, so
the simple rule is to always pass `-t` on a bundle you run tests against. It is
idempotent.

The connectors are **not** copied into `osgi/modules`. Once `osgi/test` is scanned,
a second copy of the same bundle in another scanned dir is a duplicate (same
symbolic name and version) that fails Declarative Services with `Component
descriptor entry ... not found`. Seeding the `.config` is enough, since
`osgi/configs` is always scanned. For the same reason, `--test` clears any
`osgi/test` jar left behind in `osgi/modules` (from a prior copy-based `--test` or
a manual copy) before boot, keeping a single authoritative copy in `osgi/test`.

### Clean start

There are two levels of clean, both prompting for confirmation. The prompt takes
only `y` or `n` (anything else, including a bare Enter, re-asks, so a stray key
never triggers a wipe): `y` cleans, `n` skips just the clean and still starts the
bundle. With no interactive stdin the prompt answers `n` by itself. Pass
`--yes` / `-y` to skip the prompt and clean:

| Flag | What it does |
|---|---|
| `--clean` / `-c` | **Full wipe** — resets the database and deletes all runtime state. Use for a fresh install. |
| `--clean-cache` / `-cc` | **Caches only** — clears the OSGi state and work/temp, keeps everything else. Use when modules or JSPs are stale but you want to keep your data. |

When both are given, `--clean` wins.

#### Full clean (`--clean`)

```bash
lfrBundle <name> -c
lfrBundle <name> -c -y      # skip the confirmation prompt
```

After confirmation it:

- **resets the database** read from the bundle's `portal-ext.properties`
  (`jdbc.default.url` / `username` / `password`) — drops and recreates it, for
  PostgreSQL and MySQL/MariaDB; and
- **deletes** `data`, `work`, `elasticsearch`, `logs`, `osgi/state`, and the
  Tomcat `logs` / `work` / `temp` directories.

The database is reset **before** any folder is deleted, so a failed reset
aborts with nothing removed. Stop the bundle first, or the drop fails on active
connections.

#### Cache clean (`--clean-cache`)

```bash
lfrBundle <name> -cc
```

The light version: it removes only `osgi/state`, `work`, and the Tomcat
`work` / `temp` directories, so the next boot rebuilds the module cache and
recompiles JSPs. It **keeps** `data`, `logs`, the search index, and the
database — no database connection is touched.

**Docker databases.** A containerized database that publishes its port to the
host is reset through the normal path. If the database is only reachable inside
a container's network, the launcher prints what `portal-ext.properties` expects
plus the running containers and their ports, and lets you pick one to reset
inside via `docker exec`. Under `--yes` that picker is skipped and the run
aborts instead, telling you to re-run with `--db-docker`. To target a container
directly (and skip the prompt), pass `--db-docker <container>`:

```bash
lfrBundle <name> -c -dbd pg-db
```

### A clean terminal for each launch (`--no-clear`)

The terminal is wiped, screen and scrollback both, once the bundle and its
Tomcat are resolved and before the launch prints anything of its own. What the
window then holds, and what a PageUp reaches, is this launch and nothing before
it: the resolved bundle, the clean, the port table, and the whole boot log after
them.

**Where the wipe happens is the whole point.** Wiping any later would take this
launch's own header with it, which is what makes a screen that starts at Java's
`NOTE: Picked up JDK_JAVA_OPTIONS` line and never says which bundle it belongs
to. Wiping any earlier would leave the picker and the `--clean` prompt on the
old screen.

Two details keep it from losing anything:

- **The status bar puts the cursor back where the output was.** Setting a scroll
  region homes the cursor by definition, so the bar has to restore the row, and
  it asks the terminal for it (DSR, `ESC[6n`) rather than jumping to a fixed one.
  A fixed jump to the region's last row is what opened the boot on the bottom row
  under a screenful of blank lines. The row is clamped into the region, since a
  cursor left on a panel row would write over the panel and never scroll, and it
  falls back to the region's last row when no terminal answers.
- **Lines that scroll off still bank in the scrollback**, even though the status
  bar keeps a scroll region set the whole time the bundle runs. Measured on VTE
  2.91 (Terminator): of 60 lines pushed through a 24-row window with the region
  in place, all 60 were still in the buffer, the first included.

Pass `--no-clear` / `-nc` to leave the terminal alone for a single run, or set
`CLEAR_SCREEN=0` in `start-liferay.conf` to keep it that way. Piped or
redirected output is never touched, since the wipe is TTY-only.

### Stopping the server

`Ctrl+C` stops the server: it sends `SIGTERM` for a clean shutdown and waits for
Tomcat to exit. That is all `Ctrl+C` ever does (pressing it again just re-shows
the hint), so an accidental double-tap can never hard-kill a still-shutting-down
JVM. If Tomcat genuinely hangs during that shutdown, press the `f` key to
force-kill the whole process tree (the JVM plus the Elasticsearch sidecar) with
`SIGKILL`; `f` only works after `Ctrl+C`, never during a normal run. No
background processes are left behind.

(On a TTY the script runs `catalina.sh run` in the background and waits, so it
can pin the status bar, redraw on resize, and handle `Ctrl+C` as above; piped or
redirected, it just `exec`s Tomcat.)

## What happens on launch

1. **Locates the Tomcat directory** inside the bundle. Handles all common
   layouts (`<bundle>/tomcat/`, `<bundle>/tomcat-9.x.y/`,
   `<bundle>/liferay-dxp/tomcat/`, …). If a bundle has more than one Tomcat
   version (e.g. an upgrade left `tomcat-10.1.55` next to `tomcat-10.1.57`), it
   prompts you to pick one, then offers to delete the version(s) you did not
   pick and any matching `tomcat-*.zip`. The delete offer is interactive only,
   defaults to keeping them, and is skipped under `--yes`.
2. **Writes the Elasticsearch sidecar config** into `<bundle>/.../osgi/configs/`
   every run: `sidecarHttpPort="AUTO"` plus a per-instance `transportTcpPort`
   (seeded from the HTTP offset) bound to loopback, so parallel bundles don't
   fight over the Elasticsearch ports. Picks the ES7 or ES8 PID to match the
   module the bundle ships.
3. **Resolves the service ports** — HTTP `8080`, shutdown `8005`, AJP `8009`,
   HTTPS `8443`, the OSGi console `11311`, the Elasticsearch transport port
   `9301`, and Glowroot `4000` when the bundle ships it (plus JPDA `8000` in
   debug mode) — using `ss`, `lsof` or `netstat`. Picks the next free port if a
   default is busy, avoiding self-collisions. The shutdown and ES ports bind late
   and can take the JVM down on a clash, so their candidates are seeded from the
   HTTP offset (deterministic) rather than scanned — this is what lets two bundles
   run at once. Also sets `portal.instance.inet.socket.address` to the resolved
   HTTP port, and remaps Glowroot's web port in `glowroot/admin.json` if present.
   Each test connector is seeded a per-instance port from the HTTP offset on every
   launch (`32763`/`42763` at 8080, `32804`/`42804` at 8081, a block clear of the
   ports the test JVM itself listens on), so one left installed by an earlier
   `--test` run can never fall back onto the default port and exit the JVM. Adding
   `osgi/test` to the module scan is what `--test` alone does (see
   [Test mode](#test-mode---test-testintegration-against-a-live-bundle)); without
   the flag a launch is lean, since the scan override is removed.
4. **Backs up `tomcat/conf/server.xml`** to
   `server.xml.bak.<yyyymmdd-hhmmss>` and rewrites the connector ports —
   only when at least one port differs from what's already in the file.
   Re-running on the same setup leaves `server.xml` untouched.
5. **Starts Tomcat**, prints the resolved HTTP URL and the `catalina.out` path,
   and on a TTY pins a two-row status panel to the bottom (ports on the upper
   row, the editor URL and full bundle path on the lower row) that stays put
   while the logs scroll.

### Sample output (defaults free)

```
Bundle : ${HOME}/liferay/bundles/liferay-dxp-tomcat-2025.q1.14-lts-1748919610
Tomcat : .../liferay-dxp/tomcat

Elasticsearch config written: .../osgi/configs/...elasticsearch8...config (http AUTO, transport 9301)
portal.instance.inet.socket.address set to localhost:8080

Starting Liferay (Ctrl+C to stop; then press f to force-kill if it hangs).
  Editor / portal: http://<LAN-IP>:8080/ (reachable from this machine and other devices on the network)
  Logs           : .../tomcat/logs/catalina.out
  JDK            : .../zulu17...

Selected ports:
  HTTP       8080
  SHUTDOWN   8005
  AJP        8009
  HTTPS      8443
  OSGI       11311
  ES-TRANS   9301
```

### Sample output (8080 + 8005 already taken)

```
Selected ports:
  HTTP       8081   (default 8080 was busy)
  SHUTDOWN   8006   (default 8005 was busy)
  AJP        8009
  HTTPS      8443
  OSGI       11312   (default 11311 was busy)
  ES-TRANS   9302   (default 9301 was busy)

server.xml backed up to .../server.xml.bak.20260505-113412
server.xml updated.

Starting Liferay (Ctrl+C to stop; then press f to force-kill if it hangs).
  Editor / portal: http://<LAN-IP>:8081/ (reachable from this machine and other devices on the network)
  ...
```

## Restoring original ports

If you want to roll a bundle back to its original ports, the most recent
backup file is in the same directory:

```bash
cp .../tomcat/conf/server.xml.bak.<latest> .../tomcat/conf/server.xml
```

The Elasticsearch config is computed and rewritten on every run, so there is
no original to restore: deleting the deployed copy and re-running just
regenerates the same file. Delete it only if you are retiring the bundle or
switching to an external Elasticsearch.

## Notes

- On a plain launch the script touches: `server.xml` (only when the resolved
  ports differ from the file), the Elasticsearch `.config` in `osgi/configs/`
  (rewritten every run), the `portal.instance.inet.socket.address` line in
  `portal-ext.properties` (every run), `glowroot/admin.json` when present, the test
  connector `.config`s in `osgi/configs/` (also every run), and it pre-creates
  `osgi/war`/`osgi/portal-war`. `--test` adds the
  `module.framework.auto.deploy.dirs` line (removed again by a non-test launch).
  Only `--clean` touches the database or the data folders.
- It does **not** set `web.server.http.port`. If you need URL generation to
  use the resolved HTTP port (for example when running behind a reverse
  proxy), set it separately.
- Multiple bundles can be launched in parallel by calling the script with
  different bundle paths. Each call picks its own non-conflicting port
  set; the per-bundle `server.xml` keeps its own assigned ports between
  runs.
- `set -euo pipefail` is enabled in the script — it will exit non-zero
  on any unexpected failure (missing bundle, missing `catalina.sh`,
  etc.) before reaching the start phase.
