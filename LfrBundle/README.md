# Run bundles

Launcher for Liferay DXP bundles that picks free ports if the defaults are
busy and drops in a known-good Elasticsearch configuration on the first run.
Useful when you keep several bundles on the same machine and want to start
one without manually editing `server.xml` or hunting for a free port.

## Contents

| File | Purpose |
|---|---|
| `start-liferay.sh` | Launches a bundle with auto-port selection. Modifies `tomcat/conf/server.xml` in place if any default port is busy, after backing it up. |
| `lfr-bundle.sh` | Defines `lfrBundle` (alias `lfrb`): toggles a bundle (start if stopped, stop if running) via a picker or by name, plus `status` and `stop-all`. `lfrRunBundle` / `lfrrb` remain as back-compat aliases. |
| `com.liferay.portal.search.elasticsearch7.configuration.ElasticsearchConfiguration.config` | Embedded-Elasticsearch configuration for ES7-era bundles. Copied into the bundle's `osgi/configs/` directory on first run, so search works out of the box without an external Elasticsearch server. |
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
   the database runs inside a container.

## Configuration

Machine-specific paths live in `start-liferay.conf`, next to the script. It is
**gitignored**, so your local paths never enter the repository — copy the
tracked `start-liferay.conf.example` to create it. The file is sourced as a
bash script, so any bash syntax works; when it is missing the launcher falls
back to built-in defaults and prints a hint.

| Key | Purpose |
|---|---|
| `BUNDLES_DIRS` | Array of directories that hold your Liferay bundles. The picker scans all of them; missing directories are silently skipped. |
| `JDK_8` / `JDK_11` / `JDK_17` / `JDK_21` | JDK roots by major version. The launcher picks one from the bundle name (see [JDK selection](#jdk-selection-older-bundles-need-older-jdks)); leave a version empty if you never run that family. |
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
lfrRunBundle                 # picker
lfrRunBundle --pick          # same thing, forced explicitly
lfrRunBundle --debug         # picker, then debug mode
```

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

`--list` is accepted as an alias for `--pick`.

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
lfrRunBundle --debug
lfrRunBundle --debug /path/to/another/liferay-bundle
```

JPDA listens on port `8000` by default. If `8000` is already taken, the
script bumps to the next free port — same behaviour as the other ports — and
prints the resolved value:

```
Starting Liferay (Ctrl+C to stop).
  Editor / portal: http://localhost:8080/
  Logs           : .../tomcat/logs/catalina.out
  JDK            : .../zulu17...
  Debug attach   : localhost:8000 (transport=dt_socket, suspend=n)

Selected ports:
  HTTP       8080
  SHUTDOWN   8005
  AJP        8009
  HTTPS      8443
  OSGI       11311
  ARQUILLIAN 32763
  DATAGUARD  42763
  ES-TRANS   9301
  JPDA       8000
```

By default the JVM does **not** suspend on startup (`suspend=n`), so the portal
boots whether a debugger is attached or not. Pass `--suspend` (or set
`JPDA_SUSPEND=y` in `start-liferay.conf`) to make it wait for the debugger
before starting:

```bash
lfrRunBundle --suspend
```

Attach from your IDE using:

- Host: `localhost`
- Port: whatever the script reports next to `Debug attach`
- Transport: `dt_socket`

### Running from anywhere

Once you source the Liferay Tools aggregator (`lfrTools.sh`) from your shell rc,
`lfrRunBundle` is available from any directory:

```bash
lfrRunBundle
lfrRunBundle --debug
lfrRunBundle --suspend
lfrRunBundle /path/to/bundle
```

`lfrRunBundle` is a thin wrapper around `start-liferay.sh` (defined in
`lfr-run.sh`). The script resolves its own location internally, so the bundled
Elasticsearch config is still found regardless of where you call it from.

### Running and stopping: the `lfrBundle` command

`lfrBundle` (alias `lfrb`) is the single entry point, and it toggles: it starts
a stopped bundle or stops a running one, so you never blindly start a second
copy (a bundle cannot run twice safely, since a second instance shares the same
`catalina.base`, database, and OSGi state). A running bundle is a java process
started with `catalina.sh run` (so it carries `-Dcatalina.base=`); that is how
the tool finds running bundles and shows each one's PID, bundle name, and the
TCP ports it is listening on (read from `ss`, so auto-picked ports show their
real value).

```bash
lfrBundle                # picker over every known bundle with its state; selecting one toggles it. Esc cancels
lfrBundle <name>         # toggle that bundle directly, no picker
lfrBundle <name> -c      # start-flags (here --clean) are forwarded to start-liferay.sh, but only when starting
lfrBundle status         # just list running bundles and their ports
lfrBundle stop-all       # stop every running bundle (asks to confirm)
```

Start flags (`-c`, `--clean-cache`, `--debug`, `--suspend`, `--jdk`, ...) are
passed through to `start-liferay.sh` when a stopped bundle is started, and
ignored when a running bundle is stopped. Stopping sends `SIGTERM` for a clean
JVM shutdown, waits up to 10s, then `SIGKILL`s anything still alive. The picker
lists bundles under `LFR_BUNDLES_DIRS`; give a path to toggle a bundle outside
those roots. `lfrRunBundle` / `lfrrb` remain as back-compat aliases (they now
toggle, like `lfrBundle`).

### JDK selection (older bundles need older JDKs)

Liferay needs the right JDK for its version. If the wrong one is used the
portal crashes on startup with a `NoSuchFieldException: modifiers` (under
JDK 12+) or similar reflection error.

The launcher picks a JDK automatically based on the bundle's name:

| Bundle name pattern | JDK chosen |
|---|---|
| `liferay-portal-6.*`, `liferay-dxp-7.0.*`, `liferay-dxp-7.1.*` | JDK 8 |
| `liferay-dxp-7.2.*`, `liferay-dxp-7.3.*` | JDK 11 |
| `liferay-dxp-7.4.*`, `liferay-dxp-tomcat-2023.*`, `liferay-dxp-tomcat-2024.*` | JDK 11 |
| `liferay-dxp-tomcat-2025.*`, `liferay-dxp-tomcat-2026.*` | JDK 17 |

The actual JDK paths are constants near the top of `start-liferay.sh`
(`JDK_8`, `JDK_11`, `JDK_17`, `JDK_21`). Edit them if your machine keeps
JDKs in different locations.

To override the detection per-run, use `--jdk`:

```bash
lfrRunBundle --pick --jdk ${HOME}/liferay/tools/jvm/jdk-11
lfrRunBundle --jdk=/path/to/jdk /path/to/bundle
```

Or export `JAVA_HOME` before invoking:

```bash
JAVA_HOME=${HOME}/liferay/tools/jvm/jdk-11 lfrRunBundle --pick
```

The launcher logs the chosen JDK and where it came from:

```
Starting Liferay (Ctrl+C to stop).
  Editor / portal: http://localhost:8081/
  Logs           : .../tomcat/logs/catalina.out
  JDK            : /home/.../jdk-11.0.22 (auto-detected for liferay-dxp-7.3.10.u27)
```

### Clean start

There are two levels of clean, both prompting for confirmation. The prompt takes
only `y` or `n` (anything else, including a bare Enter, re-asks, so a stray key
never triggers a wipe): `y` cleans, `n` skips just the clean and still starts the
bundle. Pass `--yes` / `-y` to skip the prompt and clean:

| Flag | What it does |
|---|---|
| `--clean` / `-c` | **Full wipe** — resets the database and deletes all runtime state. Use for a fresh install. |
| `--clean-cache` / `-cc` | **Caches only** — clears the OSGi state and work/temp, keeps everything else. Use when modules or JSPs are stale but you want to keep your data. |

When both are given, `--clean` wins.

#### Full clean (`--clean`)

```bash
lfrRunBundle --clean
lfrRunBundle --clean --yes         # skip the confirmation prompt
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
lfrRunBundle --clean-cache
```

The light version: it removes only `osgi/state`, `work`, and the Tomcat
`work` / `temp` directories, so the next boot rebuilds the module cache and
recompiles JSPs. It **keeps** `data`, `logs`, the search index, and the
database — no database connection is touched.

**Docker databases.** A containerized database that publishes its port to the
host is reset through the normal path. If the database is only reachable inside
a container's network, the launcher prints what `portal-ext.properties` expects
plus the running containers and their ports, and lets you pick one to reset
inside via `docker exec`. To target a container directly (and skip the prompt),
pass `--db-docker <container>`:

```bash
lfrRunBundle --clean --db-docker pg-db
```

### Stopping the server

`Ctrl+C` stops the server. The first press sends `SIGTERM` for a clean shutdown;
if Tomcat hangs, pressing `Ctrl+C` again after a few seconds force-kills the
whole process tree (the JVM plus the Elasticsearch sidecar). An accidental
double-tap within that grace window only sends `SIGTERM`, so you can't force-kill
by reflex. No background processes are left behind.

(On a TTY the script runs `catalina.sh run` in the background and waits, so it
can pin the status bar, redraw on resize, and handle `Ctrl+C` as above; piped or
redirected, it just `exec`s Tomcat.)

## What happens on launch

1. **Locates the Tomcat directory** inside the bundle. Handles all common
   layouts (`<bundle>/tomcat/`, `<bundle>/tomcat-9.x.y/`,
   `<bundle>/liferay-dxp/tomcat/`, …).
2. **Writes the Elasticsearch sidecar config** into `<bundle>/.../osgi/configs/`
   every run: `sidecarHttpPort="AUTO"` plus a per-instance `transportTcpPort`
   (seeded from the HTTP offset) bound to loopback, so parallel bundles don't
   fight over the Elasticsearch ports. Picks the ES7 or ES8 PID to match the
   module the bundle ships.
3. **Resolves the service ports** — HTTP `8080`, shutdown `8005`, AJP `8009`,
   HTTPS `8443`, the OSGi console `11311`, the Arquillian `32763` / DataGuard
   `42763` test connectors, the Elasticsearch transport port `9301`, and Glowroot
   `4000` when the bundle ships it (plus JPDA `8000` in debug mode) — using `ss`,
   `lsof` or `netstat`. Picks the next free port if a default is busy, avoiding
   self-collisions. The Arquillian, DataGuard and ES connectors bind their ports
   late and `System.exit` the JVM on a clash, so their candidates are seeded from
   the HTTP offset (deterministic) rather than scanned, and pinned through
   `osgi/configs/*.config` (rewritten each run) — this is what lets two bundles
   run at once. Also sets `portal.instance.inet.socket.address` to the resolved
   HTTP port, and remaps Glowroot's web port in `glowroot/admin.json` if present.
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

Starting Liferay (Ctrl+C to stop).
  Editor / portal: http://localhost:8080/
  Logs           : .../tomcat/logs/catalina.out
  JDK            : .../zulu17...

Selected ports:
  HTTP       8080
  SHUTDOWN   8005
  AJP        8009
  HTTPS      8443
  OSGI       11311
  ARQUILLIAN 32763
  DATAGUARD  42763
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
  ARQUILLIAN 32764   (default 32763 was busy)
  DATAGUARD  42764   (default 42763 was busy)
  ES-TRANS   9302   (default 9301 was busy)

server.xml backed up to .../server.xml.bak.20260505-113412
server.xml updated.

Starting Liferay (Ctrl+C to stop).
  Editor / portal: http://localhost:8081/
  ...
```

## Restoring original ports

If you want to roll a bundle back to its original ports, the most recent
backup file is in the same directory:

```bash
cp .../tomcat/conf/server.xml.bak.<latest> .../tomcat/conf/server.xml
```

The Elasticsearch config can be reset by deleting the deployed copy and
re-running the launcher:

```bash
rm <bundle>/.../osgi/configs/com.liferay.portal.search.elasticsearch7.configuration.ElasticsearchConfiguration.config
./start-liferay.sh
```

## Notes

- The script only modifies `server.xml` and writes one file into
  `osgi/configs/` on first run. It never touches the database, deploy
  folder, or anything else inside the bundle.
- It does **not** rewrite `portal-ext.properties` or `portal.properties`.
  If you need URL generation to use the resolved HTTP port (for example
  when running behind a reverse proxy), set `web.server.http.port`
  separately.
- Multiple bundles can be launched in parallel by calling the script with
  different bundle paths. Each call picks its own non-conflicting port
  set; the per-bundle `server.xml` keeps its own assigned ports between
  runs.
- `set -euo pipefail` is enabled in the script — it will exit non-zero
  on any unexpected failure (missing bundle, missing `catalina.sh`,
  etc.) before reaching the start phase.
