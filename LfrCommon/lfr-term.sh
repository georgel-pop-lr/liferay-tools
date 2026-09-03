# lfr-term.sh — shared terminal helpers for the Liferay tools.
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
