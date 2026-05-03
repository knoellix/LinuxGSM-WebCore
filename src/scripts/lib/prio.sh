# LinuxGSM-WebCore — process priority helpers (sourced by worker scripts).
#
# Two priority classes:
#
#   PRIO_HIGH   For game-server runtime processes (screen + bash + wine + EXE).
#               Negative nice value (CPU priority boost) plus best-effort I/O
#               class with priority 0 — the game gets first dibs on CPU time
#               and disk bandwidth even while a SteamCMD download is in flight.
#
#   PRIO_LOW    For background workers (steamcmd_install, game install/update,
#               wine runtime setup, big rsync/copy operations). High nice
#               value plus idle I/O class — these only get scheduled when
#               nothing else needs the resources, so a download cannot
#               starve a running game.
#
# Both prefixes are SAFE to use as-is in front of any command:
#   $PRIO_HIGH some_command --args
#   $PRIO_LOW  some_command --args
#
# If `nice` or `ionice` is missing on the host, the missing knob is silently
# skipped. The command still runs, only with whatever knobs are available.
#
# IMPORTANT: This file MUST be sourced from a Bash shell that already runs as
# root. Negative nice values require CAP_SYS_NICE to *set* — inheriting them
# across su(1) is unrestricted, so the chain works:
#   (root) nice -n -5 su -c "wine ..." gameuser
#                                ^ wine inherits nice=-5, no caps needed.

# shellcheck shell=bash

if ! command -v nice >/dev/null 2>&1; then
    PRIO_HIGH=""
    PRIO_LOW=""
else
    PRIO_HIGH="nice -n -5"
    PRIO_LOW="nice -n 10"
fi

if command -v ionice >/dev/null 2>&1; then
    PRIO_HIGH="$PRIO_HIGH ionice -c 2 -n 0"
    PRIO_LOW="$PRIO_LOW ionice -c 3"
fi

# Trim leading/trailing spaces — purely cosmetic, but keeps logs readable
# when the prefix is the empty string on minimal systems.
PRIO_HIGH="${PRIO_HIGH#"${PRIO_HIGH%%[![:space:]]*}"}"
PRIO_HIGH="${PRIO_HIGH%"${PRIO_HIGH##*[![:space:]]}"}"
PRIO_LOW="${PRIO_LOW#"${PRIO_LOW%%[![:space:]]*}"}"
PRIO_LOW="${PRIO_LOW%"${PRIO_LOW##*[![:space:]]}"}"

export PRIO_HIGH PRIO_LOW
