# lfr-term.sh - shared terminal helpers for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns _lfrClearScreen, used by the tools that
# take over the terminal for a long run (lfrAntAll), and _lfrConfirm, the yes/no
# prompt every tool asks through. start-liferay.sh carries its own copy of both,
# because it is a standalone script and sources nothing from here.

# Wipe the terminal, screen and scrollback both, so a long run starts on an empty
# window and nothing from the run before it is left anywhere. Call it where the
# run's own output begins: any later takes that output with it, any earlier wipes
# the screen for a run that then refuses to start.
#
# `clear` is the whole clear (\033[2J for the screen, \033[3J for the scrollback;
# `clear -x` keeps the scrollback, which leaves the previous run one PageUp away
# and reads as no clear at all), and going through the command rather than
# writing the escapes by hand lets terminfo answer for whatever TERM is in play.
#
# No-op off a TTY, and when LFR_CLEAR_SCREEN is set to 0 (in repos.local.conf,
# or exported for one shell).
_lfrClearScreen() {
	[ "${LFR_CLEAR_SCREEN:-1}" = 1 ] && [ -t 1 ] || return 0
	clear 2>/dev/null || printf '\033[H\033[2J\033[3J'
}

# Ask a yes/no question. Only y/yes and n/no are accepted and anything else asks again,
# since these questions decide whether something is stopped, reused, or moved aside and
# a mistyped answer must never decide that quietly. No answer is the default, a bare
# Enter included. Returns 0 for yes and 1 for no.
#
# Returns 1 without asking when there is no terminal, so a caller whose safe answer is
# yes checks for a terminal itself before calling. $1 is the question, without the [y/n]
# this adds.
_lfrConfirm() {
	local reply

	if [ ! -t 0 ]; then
		return 1
	fi

	while true; do
		if ! read -r -p "${1} [y/n] " reply; then
			echo "No input; taking that as n." >&2

			return 1
		fi

		case "${reply}" in
		[yY] | [yY][eE][sS])
			return 0
			;;
		[nN] | [nN][oO])
			return 1
			;;
		*)
			echo "Please answer y or n." >&2
			;;
		esac
	done
}

# A spinner with the step and the seconds, on the terminal (/dev/tty). It writes
# to /dev/tty and not to stderr, because a logged run (_lfrLogRun) sends stderr
# into tee, which is not a terminal. With no terminal, it shows nothing.
#
# The loop runs in its own process, started from a command substitution, so the
# shell prints no job lines. Ctrl-C goes to the job in the foreground, not to the
# loop. Thus the loop watches the shell: if the shell waits at its prompt (poll,
# select, or a tty read), the loop stops, so that the prompt stays clean. It also
# stops after one hour. _lfrPullsSpinStart in lfr-pulls.sh is the first copy of
# this loop.
_lfrSpinStart() {
	_lfrSpinStop
	{ : >/dev/tty; } 2>/dev/null || return 0
	_lfrSpinPid="$(bash -c '
		frames="|/-\\" i=0
		while [ "${SECONDS}" -lt 3600 ]; do
			case "$(cat "/proc/$2/wchan" 2>/dev/null || echo gone)" in
			gone | *poll* | *select* | *n_tty_read*) exit 0 ;;
			esac
			printf "\r\033[K%s %s (%ss)" "${frames:i%4:1}" "$1" "${SECONDS}"
			i=$((i + 1))
			sleep 0.15
		done' _lfrSpin "$1" "$$" </dev/null >/dev/tty 2>/dev/null & echo $!)"
}

# Stops the spinner and clears its line.
_lfrSpinStop() {
	[ -n "${_lfrSpinPid:-}" ] || return 0
	kill "${_lfrSpinPid}" 2>/dev/null
	while kill -0 "${_lfrSpinPid}" 2>/dev/null; do sleep 0.01; done
	_lfrSpinPid=""
	{ printf '\r\033[K' >/dev/tty; } 2>/dev/null
}

# Runs one step of a long command and shows "<label> (<seconds>s)" with a spinner
# while the step runs, so a step that waits (a push, a fetch, a 1Password
# approval) shows which step it is. The output of the step goes to a temporary
# file and prints when the step ends, because a line from the step would break
# the spinner line. Stderr prints with stdout. With no terminal, the step runs
# as is. Returns the exit code of the step. $1 is the label, the rest is the
# command (a function is fine).
_lfrStep() {
	local label="${1}" out rc
	shift
	if ! { : >/dev/tty; } 2>/dev/null; then
		"$@"
		return
	fi
	out="$(mktemp "${TMPDIR:-/tmp}/lfr-step.XXXXXX")" || {
		"$@"
		return
	}
	_lfrSpinStart "${label}"
	"$@" >"${out}" 2>&1
	rc=$?
	_lfrSpinStop
	cat "${out}"
	rm -f "${out}"
	return "${rc}"
}
