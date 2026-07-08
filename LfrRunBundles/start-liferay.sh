#!/usr/bin/env bash
#
# Starts a Liferay bundle, picking free ports if the defaults are taken.
# Modifies tomcat/conf/server.xml in place (with backup) so the bundle's
# stored config matches the running ports — useful for parallel bundles.
#
# Usage:
#   start-liferay.sh                              # opens the bundle picker (fzf)
#   start-liferay.sh /path/to/bundle              # explicit bundle path, skips the picker
#   start-liferay.sh --debug                      # picker, then debug mode
#   start-liferay.sh --debug /path/to/bundle      # explicit bundle, debug mode
#   start-liferay.sh --suspend                    # debug mode, wait for the debugger to attach
#   start-liferay.sh --pick                       # force the picker (same as no argument)
#   start-liferay.sh --jdk /path/to/jdk           # override the JDK
#   start-liferay.sh --clean                      # picker, then wipe state + reset DB
#   start-liferay.sh --clean --yes                # picker, clean without prompting, start
#   start-liferay.sh --clean --db-docker pg-db    # reset DB via docker exec, then start
#   start-liferay.sh --clean-cache                # picker, then clear caches only (no DB)
#
# DEBUG mode runs Tomcat via 'catalina.sh jpda run' so a remote debugger can
# attach. The JPDA port defaults to 8000, with the same auto-bump behaviour as
# the other ports if it's already in use. --suspend (or JPDA_SUSPEND=y in the
# conf) makes the JVM wait for the debugger before starting; the default is to
# start without waiting.
#
# The picker lists every Liferay-looking bundle under BUNDLES_DIRS and lets you
# select one interactively (fzf when available, numbered menu otherwise). It
# runs whenever no bundle path is given on the command line; --pick forces it.
#
# CLEAN mode (--clean / -c) wipes the resolved bundle's runtime state before
# starting: data, work, elasticsearch, logs, osgi/state, and tomcat
# logs/work/temp, then drops and recreates the database configured in the
# bundle's portal-ext.properties (PostgreSQL and MySQL/MariaDB). It prompts for
# confirmation first; pass --yes / -y to skip the prompt. Make sure the bundle
# is stopped, or the database drop will fail on active connections. The database
# is reset before any folder is deleted, so a failed reset aborts cleanly.
#
# CACHE-CLEAN mode (--clean-cache / -cc) is the light version: it removes only
# the OSGi state and the work/temp caches (osgi/state, work, tomcat work/temp)
# so the next boot rebuilds the module cache and recompiles JSPs. It keeps data,
# logs, the search index, and the database. When both flags are given, --clean
# (the full wipe) wins.
#
# Database location is handled in this order: a Docker DB that publishes its
# port to the host is reached by the normal host:port path; if that host reset
# fails, the script prints what portal-ext.properties expects plus the running
# containers and their ports, and lets you pick one to retry the reset inside
# via `docker exec`. Pass --db-docker <container> to target a container directly
# (and skip the prompt, e.g. together with --yes).
#
# JDK selection: by default the script picks a JDK based on the bundle name
# (Liferay version family) from the JDK_* paths in start-liferay.conf.
# Override per-run with --jdk <path> or by exporting JAVA_HOME before
# invoking the script.
#
# Configuration: machine-specific settings (bundle locations, default bundle,
# JDK paths) live in start-liferay.conf next to this script. The file is
# gitignored; copy start-liferay.conf.example to create yours.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Machine-specific defaults. Override them in start-liferay.conf next to this
# script (gitignored — copy start-liferay.conf.example to get started).
BUNDLES_DIRS=(
	"$HOME/liferay/bundles"
)
BUNDLE_DEFAULT=""

# Path to the JDK roots on this machine. Set them in start-liferay.conf.
JDK_8=""
JDK_11=""
JDK_17=""
JDK_21=""

CONF_FILE="$SCRIPT_DIR/start-liferay.conf"
if [ -f "$CONF_FILE" ]; then
	# shellcheck source=start-liferay.conf.example
	. "$CONF_FILE"
else
	echo "Note: no $CONF_FILE — using built-in defaults." >&2
	echo "      Copy start-liferay.conf.example to start-liferay.conf to configure bundle and JDK locations." >&2
fi

BUNDLE_DEFAULT="${BUNDLE_DEFAULT:-${BUNDLES_DIRS[0]}/liferay-bundle-master}"

DEBUG=0
JPDA_SUSPEND="${JPDA_SUSPEND:-n}"
PICK=0
CLEAN=0
CLEAN_CACHE=0
ASSUME_YES=0
BUNDLE=""
JDK_OVERRIDE=""
DB_DOCKER=""

# Manual two-pass parser so we can consume --jdk's value.
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
	arg="${args[$i]}"
	case "$arg" in
		--debug)
			DEBUG=1
			;;
		--suspend)
			DEBUG=1
			JPDA_SUSPEND=y
			;;
		--pick|--list)
			PICK=1
			;;
		--clean|-c)
			CLEAN=1
			;;
		--clean-cache|-cc)
			CLEAN_CACHE=1
			;;
		--yes|-y)
			ASSUME_YES=1
			;;
		--db-docker)
			i=$((i + 1))
			DB_DOCKER="${args[$i]:-}"
			if [ -z "$DB_DOCKER" ]; then
				echo "--db-docker requires a container name" >&2
				exit 1
			fi
			;;
		--db-docker=*)
			DB_DOCKER="${arg#--db-docker=}"
			;;
		--jdk)
			i=$((i + 1))
			JDK_OVERRIDE="${args[$i]:-}"
			if [ -z "$JDK_OVERRIDE" ]; then
				echo "--jdk requires a path argument" >&2
				exit 1
			fi
			;;
		--jdk=*)
			JDK_OVERRIDE="${arg#--jdk=}"
			;;
		*)
			if [ -z "$BUNDLE" ]; then
				BUNDLE="$arg"
			fi
			;;
	esac
	i=$((i + 1))
done

# Open the picker by default: with no bundle named on the command line, there
# is nothing to launch, so fall into selection rather than a hardcoded default.
if [ -z "$BUNDLE" ]; then
	PICK=1
fi

# Picker: list bundles under every BUNDLES_DIRS entry and prompt for a
# selection. Missing directories are silently skipped so this still works on
# machines where only a subset of the configured locations exists.
if [ "$PICK" = "1" ]; then
	bundles=()
	scanned=()

	for dir in "${BUNDLES_DIRS[@]}"; do
		if [ ! -d "$dir" ]; then
			continue
		fi

		scanned+=("$dir")

		for entry in "$dir"/*/; do
			entry="${entry%/}"
			# Accept any directory that has a tomcat folder we can find.
			for c in "$entry/tomcat" $entry/tomcat-* "$entry/liferay-dxp/tomcat" $entry/liferay-dxp/tomcat-*; do
				if [ -d "$c" ]; then
					bundles+=("$entry")
					break
				fi
			done
		done
	done

	if [ "${#scanned[@]}" -eq 0 ]; then
		echo "None of the configured bundles directories exist:" >&2
		printf "  %s\n" "${BUNDLES_DIRS[@]}" >&2
		exit 1
	fi

	if [ "${#bundles[@]}" -eq 0 ]; then
		echo "No Liferay bundles found under:" >&2
		printf "  %s\n" "${scanned[@]}" >&2
		exit 1
	fi

	# fzf when available (shows each bundle's parent root so duplicate names
	# across locations stay distinguishable); numbered menu otherwise.
	if command -v fzf >/dev/null 2>&1; then
		choice="$(
			for entry in "${bundles[@]}"; do
				printf '%s\t%s  (%s)\n' "$entry" "$(basename "$entry")" "$(dirname "$entry")"
			done | fzf \
				--delimiter=$'\t' \
				--height=40% \
				--prompt='bundle> ' \
				--reverse \
				--select-1 \
				--with-nth=2..
		)"
		[ -z "$choice" ] && exit 1
		BUNDLE="${choice%%$'\t'*}"
	else
		echo "Available bundles (from ${#scanned[@]} location(s)):"
		for dir in "${scanned[@]}"; do
			echo "  $dir"
		done
		echo

		PS3=$'\nPick a bundle (number, or Ctrl+C to abort): '

		select choice in "${bundles[@]}"; do
			if [ -n "$choice" ]; then
				BUNDLE="$choice"
				break
			fi
			echo "Invalid selection — try again." >&2
		done

		echo
	fi
fi

BUNDLE="${BUNDLE:-$BUNDLE_DEFAULT}"

if [ ! -d "$BUNDLE" ]; then
	echo "Bundle directory not found: $BUNDLE" >&2
	exit 1
fi

# Liferay bundles have either tomcat/ or tomcat-9.x.y/ — collect every match
# so we can prompt if a bundle has more than one (e.g. after an upgrade left
# the old tomcat-9.0.50 next to the new tomcat-9.0.60).
TOMCAT_CANDIDATES=()
seen_tomcat() {
	local t
	for t in "${TOMCAT_CANDIDATES[@]:-}"; do
		[ "$t" = "$1" ] && return 0
	done
	return 1
}
for candidate in "$BUNDLE/tomcat" $BUNDLE/tomcat-* "$BUNDLE/liferay-dxp/tomcat" $BUNDLE/liferay-dxp/tomcat-*; do
	if [ -d "$candidate" ] && ! seen_tomcat "$candidate"; then
		TOMCAT_CANDIDATES+=("$candidate")
	fi
done

if [ "${#TOMCAT_CANDIDATES[@]}" -eq 0 ]; then
	echo "No tomcat directory found under $BUNDLE" >&2
	exit 1
elif [ "${#TOMCAT_CANDIDATES[@]}" -eq 1 ]; then
	TOMCAT_DIR="${TOMCAT_CANDIDATES[0]}"
else
	echo "Multiple tomcat directories found under $BUNDLE:"
	TOMCAT_LABELS=()
	for t in "${TOMCAT_CANDIDATES[@]}"; do
		mtime=$(stat -c '%y' "$t" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
		TOMCAT_LABELS+=("$t  (modified $mtime)")
	done
	PS3=$'\nPick a tomcat (number, or Ctrl+C to abort): '
	select choice in "${TOMCAT_LABELS[@]}"; do
		if [ -n "$choice" ]; then
			TOMCAT_DIR="${TOMCAT_CANDIDATES[$((REPLY - 1))]}"
			break
		fi
		echo "Invalid selection — try again." >&2
	done
	echo
fi

SERVER_XML="$TOMCAT_DIR/conf/server.xml"
CATALINA="$TOMCAT_DIR/bin/catalina.sh"

if [ ! -f "$SERVER_XML" ] || [ ! -x "$CATALINA" ]; then
	echo "Tomcat layout looks wrong:" >&2
	echo "  server.xml : $SERVER_XML" >&2
	echo "  catalina.sh: $CATALINA" >&2
	exit 1
fi

echo "Bundle : $BUNDLE"
echo "Tomcat : $TOMCAT_DIR"
echo

# --clean: wipe runtime state (data, work, logs, elasticsearch, osgi/state,
# tomcat logs/work/temp) and reset the database read from portal-ext.properties.
# Runs only after the bundle and tomcat are resolved so we know exactly what to
# wipe, and prompts for confirmation unless --yes was passed.
confirm_or_abort() {
	[ "$ASSUME_YES" = "1" ] && return 0
	local reply
	read -r -p "$1 [y/N] " reply
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) echo "Aborted." >&2; exit 1 ;;
	esac
}

# Give up: print likely causes and abort. $1 is an optional context line.
_db_reset_failed() {
	[ -n "${1:-}" ] && echo "  $1" >&2
	echo "  Database reset FAILED. Check that the server is running, the bundle" >&2
	echo "  is stopped, and the credentials in portal-ext.properties are correct." >&2
	exit 1
}

# Run the drop/create. Uses engine/host/port/db/user/pass from the caller's
# scope (bash dynamic scoping). $1 empty = host client against host:port;
# otherwise a Docker container name to run the client inside via docker exec.
_run_reset() {
	local container="${1:-}"

	if [ "$engine" = postgres ]; then
		local terminate="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();"
		if [ -n "$container" ]; then
			docker exec -i -e PGPASSWORD="$pass" "$container" psql -U "$user" -d postgres -q -c "$terminate" >/dev/null 2>&1 || true
			docker exec -i -e PGPASSWORD="$pass" "$container" psql -U "$user" -d postgres -q -v ON_ERROR_STOP=1 \
				-c "DROP DATABASE IF EXISTS \"$db\";" -c "CREATE DATABASE \"$db\";"
		else
			PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres -q -c "$terminate" >/dev/null 2>&1 || true
			PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres -q -v ON_ERROR_STOP=1 \
				-c "DROP DATABASE IF EXISTS \"$db\";" -c "CREATE DATABASE \"$db\";"
		fi
	else
		local sql="DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
		if [ -n "$container" ]; then
			docker exec -i "$container" mysql -u "$user" ${pass:+-p"$pass"} -e "$sql"
		else
			mysql -h "$host" -P "$port" -u "$user" ${pass:+-p"$pass"} -e "$sql"
		fi
	fi
}

# Host reset failed: show what portal-ext.properties expects and the running
# containers with their ports, then let the user pick one to retry the reset
# inside via docker exec.
_recover_via_docker() {
	echo >&2
	echo "  Could not reach the database directly." >&2
	echo "  portal-ext.properties expects: $engine \"$db\" at $host:$port (user $user)." >&2

	if ! command -v docker >/dev/null 2>&1; then
		echo "  Docker is not available to try a container." >&2
		_db_reset_failed
	fi

	local lines=()
	mapfile -t lines < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
	if [ "${#lines[@]}" -eq 0 ]; then
		echo "  No running Docker containers to try." >&2
		_db_reset_failed
	fi

	echo "  Running Docker containers (the DB is usually the one publishing $port):" >&2
	local names=() i=1 line name ports
	for line in "${lines[@]}"; do
		name="${line%%$'\t'*}"
		ports="${line#*$'\t'}"
		names+=("$name")
		printf "    %2d) %-28s %s\n" "$i" "$name" "$ports" >&2
		i=$((i + 1))
	done

	if [ "$ASSUME_YES" = "1" ]; then
		echo "  (--yes given — not prompting. Re-run with --db-docker <container> to target one.)" >&2
		_db_reset_failed
	fi

	local choice
	read -r -p "  Reset the DB inside which container? (number, or Enter to abort): " choice
	if [ -z "$choice" ]; then
		echo "  Aborted — nothing was deleted." >&2
		exit 1
	fi
	if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
		echo "  Invalid selection — aborting." >&2
		exit 1
	fi

	local chosen="${names[$((choice - 1))]}"
	echo "  Retrying via docker exec $chosen ..."
	_run_reset "$chosen" || _db_reset_failed "Reset inside container $chosen failed."
	echo "  Database reset succeeded via container $chosen."
}

reset_database() {
	local portal_ext="$1"

	if [ ! -f "$portal_ext" ]; then
		echo "  No portal-ext.properties at $portal_ext — skipping database reset." >&2
		return 0
	fi

	local url user pass
	url="$(sed -nE 's/^[[:space:]]*jdbc\.default\.url=//p' "$portal_ext" | tail -n 1)"
	user="$(sed -nE 's/^[[:space:]]*jdbc\.default\.username=//p' "$portal_ext" | tail -n 1)"
	pass="$(sed -nE 's/^[[:space:]]*jdbc\.default\.password=//p' "$portal_ext" | tail -n 1)"

	if [ -z "$url" ]; then
		echo "  No jdbc.default.url in portal-ext.properties — skipping (data/ removal clears embedded DBs)." >&2
		return 0
	fi

	local base="${url%%\?*}"
	local engine hostport host rest port db

	if [[ "$base" == jdbc:postgresql://* ]]; then
		engine=postgres
		hostport="${base#jdbc:postgresql://}"
		port=5432
	elif [[ "$base" == jdbc:mysql://* || "$base" == jdbc:mariadb://* ]]; then
		engine=mysql
		hostport="${base#jdbc:*://}"
		port=3306
	else
		echo "  Unrecognized JDBC URL ($base) — skipping DB reset; data/ removal handles embedded DBs." >&2
		return 0
	fi

	host="${hostport%%[:/]*}"
	rest="${hostport#"$host"}"
	[[ "$rest" == :* ]] && { port="${rest#:}"; port="${port%%/*}"; }
	db="${base##*/}"

	# --db-docker forces the reset inside the named container.
	if [ -n "$DB_DOCKER" ]; then
		echo "  $engine via docker exec $DB_DOCKER: dropping and recreating \"$db\" (user $user)"
		_run_reset "$DB_DOCKER" || _db_reset_failed "Reset inside container $DB_DOCKER failed."
		return 0
	fi

	# Otherwise try the host client (also reaches a Docker DB that publishes its
	# port); on failure, fall into the interactive container picker.
	echo "  $engine: dropping and recreating \"$db\" on $host:$port (user $user)"
	if ! _run_reset ""; then
		_recover_via_docker
	fi
}

# Remove each existing path in the argument list, logging what went.
_remove_paths() {
	local target
	for target in "$@"; do
		if [ -e "$target" ]; then
			rm -rf "$target"
			echo "  removed $target"
		fi
	done
}

# Full clean: reset the database and wipe all runtime state.
clean_bundle() {
	local liferay_home
	liferay_home="$(dirname "$TOMCAT_DIR")"

	echo "About to CLEAN this bundle (full):"
	echo "  Liferay home : $liferay_home"
	echo "  Tomcat       : $TOMCAT_DIR"
	echo "  Removes      : data work elasticsearch logs osgi/state, tomcat logs/work/temp"
	echo "  Database     : reset from $liferay_home/portal-ext.properties"
	echo
	confirm_or_abort "This deletes data and DROPs the database. Proceed?"

	# Reset the database first: it is the step most likely to fail (bad
	# credentials, server down, Docker-only network), and it exits on failure.
	# Doing it before the folder wipe avoids leaving wiped folders next to an
	# un-reset database.
	echo "Resetting database:"
	reset_database "$liferay_home/portal-ext.properties"

	echo "Cleaning bundle state:"
	_remove_paths \
		"$liferay_home/data" \
		"$liferay_home/work" \
		"$liferay_home/elasticsearch" \
		"$liferay_home/logs" \
		"$liferay_home/osgi/state" \
		"$TOMCAT_DIR/logs" \
		"$TOMCAT_DIR/work" \
		"$TOMCAT_DIR/temp"
	echo
}

# Cache clean: drop the OSGi state and work/temp caches so the next boot
# rebuilds the module cache and recompiles JSPs. Keeps data, logs, the search
# index, and the database.
clean_cache() {
	local liferay_home
	liferay_home="$(dirname "$TOMCAT_DIR")"

	echo "About to CLEAN CACHE for this bundle:"
	echo "  Liferay home : $liferay_home"
	echo "  Tomcat       : $TOMCAT_DIR"
	echo "  Removes      : osgi/state work, tomcat work/temp"
	echo "  Keeps        : data, logs, search index, database"
	echo
	confirm_or_abort "Clear the OSGi state and work/temp caches?"

	echo "Cleaning caches:"
	_remove_paths \
		"$liferay_home/osgi/state" \
		"$liferay_home/work" \
		"$TOMCAT_DIR/work" \
		"$TOMCAT_DIR/temp"
	echo
}

# --clean (full wipe) takes precedence over --clean-cache when both are given.
if [ "$CLEAN" = "1" ]; then
	clean_bundle
elif [ "$CLEAN_CACHE" = "1" ]; then
	clean_cache
fi

# Write the Elasticsearch sidecar configuration into the bundle's osgi/configs
# so parallel bundles don't fight over its ports. The HTTP port stays
# sidecarHttpPort="AUTO" (Liferay finds a free one on boot); the transport port
# is a fixed default that ES itself will auto-increment, so it is pinned below
# to a free, per-instance value (like the shutdown/arquillian ports) and bound
# to loopback. The file is rewritten every run, so a reused bundle always gets
# current ports. The source file names next to this script only supply the PID
# (config filename).
#
# The PID must match the Elasticsearch module the bundle ships. Older bundles
# carry com.liferay.portal.search.elasticsearch7.impl.jar; newer ones (master,
# 2025.q1+) carry elasticsearch8. On an ES8 bundle the ES7 PID is only read by
# a one-shot migration upgrade step, so injecting the ES7 file there
# re-triggers that migration on every start and races the search components
# into "Elasticsearch connection not found" errors during startup — remove a
# previously injected ES7 copy and install the ES8 file instead.
ELASTIC_SOURCE_ES7="$SCRIPT_DIR/com.liferay.portal.search.elasticsearch7.configuration.ElasticsearchConfiguration.config"
ELASTIC_SOURCE_ES8="$SCRIPT_DIR/com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config"

# osgi/ lives directly under the Liferay home (the tomcat's parent), whichever
# bundle layout we resolved. Neither osgi/ nor its configs/ subdir is guaranteed
# to exist yet on a fresh bundle — the portal only creates configs/ on first
# boot — so create the path ourselves. Skipping it would silently drop the
# connector configs (Arquillian, DataGuard, Elasticsearch) and let the
# fixed-port clash they guard against fire.
LIFERAY_HOME="$(dirname "$TOMCAT_DIR")"
LIFERAY_OSGI_DIR="$LIFERAY_HOME/osgi"
ELASTIC_TARGET_DIR="$LIFERAY_OSGI_DIR/configs"
mkdir -p "$ELASTIC_TARGET_DIR"

bundle_has_elasticsearch7() {
	compgen -G "$LIFERAY_OSGI_DIR/portal/com.liferay.portal.search.elasticsearch7.impl.jar" >/dev/null 2>&1 ||
		compgen -G "$LIFERAY_OSGI_DIR/modules/com.liferay.portal.search.elasticsearch7.impl.jar" >/dev/null 2>&1
}

if [ -n "$ELASTIC_TARGET_DIR" ]; then
	if bundle_has_elasticsearch7; then
		ELASTIC_SOURCE="$ELASTIC_SOURCE_ES7"
	else
		ELASTIC_SOURCE="$ELASTIC_SOURCE_ES8"

		# A leftover ES7 config on an ES8 bundle causes the startup noise
		# described above — drop it before installing the right one.
		ELASTIC_STALE="$ELASTIC_TARGET_DIR/$(basename "$ELASTIC_SOURCE_ES7")"
		if [ -f "$ELASTIC_STALE" ]; then
			rm "$ELASTIC_STALE"
			echo "Stale Elasticsearch 7 config removed (bundle uses Elasticsearch 8): $ELASTIC_STALE"
		fi
	fi

	# Only the filename (the PID) is taken from the source path; the contents
	# are generated after the ports are chosen (see write_elasticsearch_config).
	ELASTIC_TARGET="$ELASTIC_TARGET_DIR/$(basename "$ELASTIC_SOURCE")"
fi

HTTP_DEFAULT=8080
SHUTDOWN_DEFAULT=8005
AJP_DEFAULT=8009
HTTPS_DEFAULT=8443
JPDA_DEFAULT=8000
OSGI_CONSOLE_DEFAULT=11311
ARQUILLIAN_DEFAULT=32763
DATA_GUARD_DEFAULT=42763
ES_TRANSPORT_DEFAULT=9301
GLOWROOT_DEFAULT=4000

is_port_free() {
	local port=$1
	if command -v ss >/dev/null 2>&1; then
		! ss -lnt "sport = :$port" 2>/dev/null | tail -n +2 | grep -q LISTEN
	elif command -v lsof >/dev/null 2>&1; then
		! lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1
	else
		! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$port$"
	fi
}

USED=()
already_chosen() {
	local port=$1
	local u
	for u in "${USED[@]:-}"; do
		[ "$u" = "$port" ] && return 0
	done
	return 1
}

choose_port() {
	local port=$1
	while already_chosen "$port" || ! is_port_free "$port"; do
		port=$((port + 1))
	done
	USED+=("$port")
	echo "$port"
}

HTTP_PORT=$(choose_port "$HTTP_DEFAULT")
# Tomcat's shutdown port (<Server port="...">) is bound only at the very END of
# startup, in StandardServer.await() — unlike the connectors, which bind
# immediately and stay bound. So when a sibling bundle is mid-boot, is_port_free
# reports 8005 as free even though that sibling will claim it seconds later, once
# both reach await(); the loser then dies with "Failed to create server shutdown
# socket ... Address already in use". The HTTP connector binds early and is a
# reliable per-instance discriminator, so derive the shutdown port's starting
# candidate from the HTTP offset instead of scanning 8005 independently. (Still
# run it through choose_port to handle a genuine, already-bound clash.)
SHUTDOWN_PORT=$(choose_port $((SHUTDOWN_DEFAULT + HTTP_PORT - HTTP_DEFAULT)))
AJP_PORT=$(choose_port "$AJP_DEFAULT")
HTTPS_PORT=$(choose_port "$HTTPS_DEFAULT")

JPDA_PORT=""
if [ "$DEBUG" = "1" ]; then
	JPDA_PORT=$(choose_port "$JPDA_DEFAULT")
fi

# Developer mode (portal-developer.properties) opens the OSGi Gogo telnet
# console on module.framework.properties.osgi.console=localhost:11311. A
# second bundle would fail to bind it ("Port 11311 already in use"), so pick a
# free port and override the portal property through Liferay's env-var
# mechanism. Harmless on bundles that don't run in developer mode.
OSGI_CONSOLE_PORT=$(choose_port "$OSGI_CONSOLE_DEFAULT")
export LIFERAY_MODULE_PERIOD_FRAMEWORK_PERIOD_PROPERTIES_PERIOD_OSGI_PERIOD_CONSOLE="localhost:$OSGI_CONSOLE_PORT"

# The Arquillian and DataGuard test connectors ship in osgi/modules, so they
# start on every boot — not only under test — and each binds a FIXED port
# (32763 and 42763). Unlike a Tomcat port clash, a bind failure here is fatal:
# the connector logs "Shutting down now." and calls System.exit(-10), taking the
# whole portal JVM down — so a second bundle on the same host kills itself (or
# its neighbor) on startup. Pick free ports and pin each through its component's
# OSGi config; these are ConfigAdmin component properties, so a .config file is
# the only way to override them (no framework or env-var equivalent). Rewritten
# every run so a standalone start falls back to the defaults the test harness
# expects on the client side (liferay.arquillian.port, default 32763).
#
# These bind late in OSGi startup (well after the HTTP connector), so scanning
# from the default races a still-booting sibling exactly like the shutdown port
# does: it reports 32763/42763 free, both bundles pick them, and the fatal
# System.exit(-10) fires when the second binds. Seed the candidate from the HTTP
# offset instead, so a second bundle deterministically lands elsewhere no matter
# the boot timing. (Still run through choose_port for a genuine already-bound clash.)
ARQUILLIAN_PORT=$(choose_port $((ARQUILLIAN_DEFAULT + HTTP_PORT - HTTP_DEFAULT)))
DATA_GUARD_PORT=$(choose_port $((DATA_GUARD_DEFAULT + HTTP_PORT - HTTP_DEFAULT)))

# The embedded Elasticsearch sidecar binds a transport port (default 9300) late
# in OSGi startup, so — like the shutdown/arquillian ports — scanning it
# independently races a still-booting sibling. Seed from the HTTP offset only
# when we have an osgi/configs dir to write the value into.
ES_TRANSPORT_PORT=""
if [ -n "${ELASTIC_TARGET:-}" ]; then
	ES_TRANSPORT_PORT=$(choose_port $((ES_TRANSPORT_DEFAULT + HTTP_PORT - HTTP_DEFAULT)))
fi

# Glowroot's embedded UI binds its web port (default 4000) when the agent is
# present. Only bundles that actually ship glowroot/admin.json need remapping;
# skip the rest so we don't reserve a port for nothing.
GLOWROOT_ADMIN="$LIFERAY_HOME/glowroot/admin.json"
GLOWROOT_PORT=""
if [ -f "$GLOWROOT_ADMIN" ]; then
	GLOWROOT_PORT=$(choose_port $((GLOWROOT_DEFAULT + HTTP_PORT - HTTP_DEFAULT)))
fi

write_port_config() {
	local pid=$1
	local port=$2
	[ -n "$ELASTIC_TARGET_DIR" ] || return 0
	printf 'port="%s"\n' "$port" >"$ELASTIC_TARGET_DIR/$pid.config"
}

write_port_config \
	"com.liferay.arquillian.extension.junit.bridge.connector.ArquillianConnector" \
	"$ARQUILLIAN_PORT"
write_port_config \
	"com.liferay.data.guard.connector.DataGuardConnector" "$DATA_GUARD_PORT"

# (Re)write the Elasticsearch sidecar config with the chosen transport port,
# every run, so a reused bundle never keeps a stale or colliding value.
if [ -n "$ES_TRANSPORT_PORT" ]; then
	cat >"$ELASTIC_TARGET" <<EOF
sidecarHttpPort="AUTO"
transportTcpPort="$ES_TRANSPORT_PORT"
networkBindHost="127.0.0.1"
networkPublishHost="127.0.0.1"
EOF
	echo "Elasticsearch config written: $ELASTIC_TARGET (http AUTO, transport $ES_TRANSPORT_PORT)"
	echo
fi

# Remap the Glowroot web port in place (jq only; skip with a note otherwise).
if [ -n "$GLOWROOT_PORT" ]; then
	if command -v jq >/dev/null 2>&1; then
		_gr_tmp="$GLOWROOT_ADMIN.tmp"
		if jq ".web.port = $GLOWROOT_PORT" "$GLOWROOT_ADMIN" >"$_gr_tmp"; then
			mv "$_gr_tmp" "$GLOWROOT_ADMIN"
			echo "Glowroot web port set to $GLOWROOT_PORT in $GLOWROOT_ADMIN"
			echo
		else
			rm -f "$_gr_tmp"
			echo "Could not rewrite $GLOWROOT_ADMIN — leaving Glowroot port unchanged." >&2
		fi
	else
		echo "glowroot/admin.json present but jq is not installed — leaving Glowroot port unchanged." >&2
	fi
fi

# The portal's own inet socket address defaults to :8080; on a non-default HTTP
# port that mismatch breaks features that resolve the instance's web address.
# Pin it to the resolved port every run — always, not just when non-default —
# so a run that lands back on 8080 overwrites a stale value from an earlier run.
set_portal_ext_prop() {
	local file=$1 key=$2 value=$3
	touch "$file"
	local escaped="${key//./\\.}"
	sed -i -E "/^[[:space:]]*${escaped}=/d" "$file"
	[ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo "" >>"$file"
	echo "${key}=${value}" >>"$file"
}

set_portal_ext_prop "$LIFERAY_HOME/portal-ext.properties" \
	portal.instance.inet.socket.address "localhost:$HTTP_PORT"
echo "portal.instance.inet.socket.address set to localhost:$HTTP_PORT"
echo

print_port() {
	local label=$1
	local resolved=$2
	local default=$3
	if [ "$resolved" = "$default" ]; then
		printf "  %-10s %s\n" "$label" "$resolved"
	else
		printf "  %-10s %s   (default %s was busy)\n" "$label" "$resolved" "$default"
	fi
}

echo "Selected ports:"
print_port "HTTP" "$HTTP_PORT" "$HTTP_DEFAULT"
print_port "SHUTDOWN" "$SHUTDOWN_PORT" "$SHUTDOWN_DEFAULT"
print_port "AJP" "$AJP_PORT" "$AJP_DEFAULT"
print_port "HTTPS" "$HTTPS_PORT" "$HTTPS_DEFAULT"
print_port "OSGI" "$OSGI_CONSOLE_PORT" "$OSGI_CONSOLE_DEFAULT"
print_port "ARQUILLIAN" "$ARQUILLIAN_PORT" "$ARQUILLIAN_DEFAULT"
print_port "DATAGUARD" "$DATA_GUARD_PORT" "$DATA_GUARD_DEFAULT"
if [ -n "$ES_TRANSPORT_PORT" ]; then
	print_port "ES-TRANS" "$ES_TRANSPORT_PORT" "$ES_TRANSPORT_DEFAULT"
fi
if [ -n "$GLOWROOT_PORT" ]; then
	print_port "GLOWROOT" "$GLOWROOT_PORT" "$GLOWROOT_DEFAULT"
fi
if [ -n "$JPDA_PORT" ]; then
	print_port "JPDA" "$JPDA_PORT" "$JPDA_DEFAULT"
fi
echo

# Read current ports out of server.xml so we know whether we need to write.
read_port() {
	local pattern=$1
	grep -oE "$pattern" "$SERVER_XML" | head -n 1 | grep -oE 'port="[0-9]+"' | grep -oE '[0-9]+' || true
}

CURRENT_SHUTDOWN=$(grep -oE '<Server port="[0-9]+"' "$SERVER_XML" | head -n 1 | grep -oE '[0-9]+' || true)
CURRENT_HTTP=$(read_port '<Connector[^>]*port="[0-9]+"[^>]*protocol="HTTP/1\.1"')
CURRENT_AJP=$(read_port '<Connector[^>]*port="[0-9]+"[^>]*protocol="AJP/1\.3"')
CURRENT_AJP_ALT=$(read_port 'protocol="AJP/1\.3"[^>]*port="[0-9]+"')
CURRENT_HTTPS=$(grep -oE 'redirectPort="[0-9]+"' "$SERVER_XML" | head -n 1 | grep -oE '[0-9]+' || true)

# AJP block in Liferay can have port="" before or after protocol="" — try both.
if [ -z "$CURRENT_AJP" ] && [ -n "$CURRENT_AJP_ALT" ]; then
	CURRENT_AJP="$CURRENT_AJP_ALT"
fi

needs_update=false
[ "$CURRENT_SHUTDOWN" != "$SHUTDOWN_PORT" ] && needs_update=true
[ "$CURRENT_HTTP" != "$HTTP_PORT" ] && needs_update=true
[ "$CURRENT_AJP" != "$AJP_PORT" ] && needs_update=true
[ "$CURRENT_HTTPS" != "$HTTPS_PORT" ] && needs_update=true

if $needs_update; then
	BACKUP="$SERVER_XML.bak.$(date +%Y%m%d-%H%M%S)"
	cp "$SERVER_XML" "$BACKUP"
	echo "server.xml backed up to $BACKUP"

	# Shutdown port — <Server port="..."
	if [ -n "$CURRENT_SHUTDOWN" ]; then
		sed -i -E "s|(<Server[[:space:]]+port=\")[0-9]+(\")|\1$SHUTDOWN_PORT\2|" "$SERVER_XML"
	fi

	# HTTP port — Connector with protocol="HTTP/1.1"
	if [ -n "$CURRENT_HTTP" ]; then
		# Replace every Connector that declares protocol="HTTP/1.1"
		# in case there are two (Liferay sometimes ships a commented-out
		# alternative with the same port).
		sed -i -E "/protocol=\"HTTP\/1\.1\"/{s|port=\"$CURRENT_HTTP\"|port=\"$HTTP_PORT\"|}" "$SERVER_XML"
	fi

	# AJP port — Connector with protocol="AJP/1.3"
	if [ -n "$CURRENT_AJP" ]; then
		sed -i -E "/protocol=\"AJP\/1\.3\"/{s|port=\"$CURRENT_AJP\"|port=\"$AJP_PORT\"|}" "$SERVER_XML"
	fi

	# HTTPS / redirectPort — referenced from HTTP and AJP connectors.
	if [ -n "$CURRENT_HTTPS" ]; then
		sed -i -E "s|redirectPort=\"$CURRENT_HTTPS\"|redirectPort=\"$HTTPS_PORT\"|g" "$SERVER_XML"
		# Also patch the HTTPS connector(s) themselves if their port differed.
		sed -i -E "/protocol=\"org\.apache\.coyote\.http11\.Http11(Nio|Apr)Protocol\"/{s|port=\"$CURRENT_HTTPS\"|port=\"$HTTPS_PORT\"|}" "$SERVER_XML"
	fi

	echo "server.xml updated."
fi

# Decide which JDK to run with — explicit --jdk wins, then JAVA_HOME from the
# shell, then a heuristic based on the bundle name.
choose_jdk() {
	local bundle_name
	bundle_name="$(basename "$BUNDLE")"

	# Strip a trailing /liferay-dxp on inner-folder calls.
	if [ "$bundle_name" = "liferay-dxp" ]; then
		bundle_name="$(basename "$(dirname "$BUNDLE")")"
	fi

	case "$bundle_name" in
		liferay-portal-6.*|liferay-dxp-digital-enterprise-7.0.*|liferay-dxp-7.0.*|liferay-dxp-7.1.*)
			echo "$JDK_8"
			;;
		liferay-dxp-7.2.*|liferay-dxp-7.3.*|liferay-dxp-tomcat-7.3.*)
			echo "$JDK_11"
			;;
		liferay-dxp-7.4.*|liferay-dxp-tomcat-7.4.*|liferay-dxp-tomcat-2023.*|liferay-dxp-tomcat-2024.*)
			echo "$JDK_11"
			;;
		liferay-dxp-tomcat-2025.*|liferay-dxp-tomcat-2026.*)
			echo "$JDK_17"
			;;
		*)
			# Unknown — fall back to JDK 17 (best for current LTS).
			echo "$JDK_17"
			;;
	esac
}

if [ -n "$JDK_OVERRIDE" ]; then
	JDK_PATH="$JDK_OVERRIDE"
	JDK_SOURCE="(--jdk override)"
elif [ -n "${JAVA_HOME:-}" ]; then
	JDK_PATH="$JAVA_HOME"
	JDK_SOURCE="(JAVA_HOME)"
else
	JDK_PATH="$(choose_jdk)"
	JDK_SOURCE="(auto-detected for $(basename "$BUNDLE"))"
fi

if [ ! -x "$JDK_PATH/bin/java" ]; then
	echo "Selected JDK has no bin/java: $JDK_PATH" >&2
	echo "Pass --jdk /path/to/jdk or export JAVA_HOME to choose another." >&2
	exit 1
fi

export JAVA_HOME="$JDK_PATH"
export JRE_HOME="$JDK_PATH"
export PATH="$JDK_PATH/bin:$PATH"

echo
echo "Starting Liferay (Ctrl+C to stop)."
echo "  Editor / portal: http://localhost:$HTTP_PORT/"
echo "  Logs           : $TOMCAT_DIR/logs/catalina.out"
echo "  JDK            : $JDK_PATH $JDK_SOURCE"

if [ "$DEBUG" = "1" ]; then
	# Bind the JPDA listener to all interfaces (the asterisk) so a remote
	# debugger can attach. JPDA_SUSPEND=y makes the JVM wait for a debugger
	# before continuing startup; n (the default) starts without waiting.
	#
	# Export the full JPDA_OPTS rather than JPDA_ADDRESS: catalina.sh sources
	# the bundle's setenv.sh after our environment, and Liferay setenv.sh
	# files hardcode JPDA_ADDRESS="8000" — which would override our chosen
	# port and collide with an already-running bundle. catalina.sh leaves a
	# non-empty JPDA_OPTS untouched.
	export JPDA_OPTS="-agentlib:jdwp=transport=dt_socket,address=*:$JPDA_PORT,server=y,suspend=$JPDA_SUSPEND"

	echo "  Debug attach   : localhost:$JPDA_PORT (transport=dt_socket, suspend=$JPDA_SUSPEND)"
	echo

	exec "$CATALINA" jpda run
fi

echo

exec "$CATALINA" run
