# lfr-term.sh — shared terminal helpers for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns _lfrClearScreen, used by the tools that
# take over the terminal for a long run (lfrAntAll; lfrBundle gets it through
# start-liferay.sh, which carries its own copy because it is a standalone script
# and sources nothing from here).

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
