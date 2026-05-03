# shellcheck shell=bash
# ports.sh — resolve game/query/beacon ports for an instance from its LGSM cfg.
#
# Multi-instance UE5 setups (Windrose etc.) MUST hand distinct ports to wine,
# otherwise the second instance silently fails to bind. The wizard only collects
# the game port today; queryport/beaconport are stored in the per-instance
# windrose.cfg by the config-fix flow. This helper consolidates the layered
# read so workers don't reinvent it.
#
# Inputs (caller-provided env):
#   SERVER_DIR           - absolute path to the instance directory
#
# Inputs (function args):
#   $1                   - script name (e.g. "windrose")
#
# Outputs (globals):
#   INSTANCE_GAME_PORT
#   INSTANCE_QUERY_PORT
#   INSTANCE_BEACON_PORT
#
# Defaults (UE5 standard, mirroring games_meta.json) are used when the cfg
# layers leave a key unset. Defaults are exported so callers can detect
# "still on default → multi-instance collision risk".

DEFAULT_GAME_PORT=${DEFAULT_GAME_PORT:-7777}
DEFAULT_QUERY_PORT=${DEFAULT_QUERY_PORT:-27015}
DEFAULT_BEACON_PORT=${DEFAULT_BEACON_PORT:-15000}

# Read a single key=value (or key="value") from an LGSM-style shell cfg.
# Stripped of surrounding quotes and trailing comments. Empty if missing.
_read_lgsm_cfg_value() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v k="$key" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            n=index(line, "=")
            if (n == 0) next
            lhs=substr(line, 1, n-1)
            rhs=substr(line, n+1)
            sub(/[[:space:]]+$/, "", lhs)
            if (lhs != k) next
            sub(/^[[:space:]]+/, "", rhs)
            sub(/[[:space:]]*#.*$/, "", rhs)
            sub(/[[:space:]]+$/, "", rhs)
            if (substr(rhs,1,1)=="\"" || substr(rhs,1,1)=="'\''") {
                rhs=substr(rhs, 2, length(rhs)-2)
            }
            print rhs
            exit
        }
    ' "$file"
}

# Resolve effective game/query/beacon port for the current instance.
# Layer order: per-instance cfg > common.cfg > built-in default.
_resolve_instance_ports() {
    local script_name="$1"
    local inst_cfg="$SERVER_DIR/lgsm/config-lgsm/$script_name/$script_name.cfg"
    local common_cfg="$SERVER_DIR/lgsm/config-lgsm/common.cfg"
    local v
    for key in port queryport beaconport; do
        v="$(_read_lgsm_cfg_value "$inst_cfg" "$key" 2>/dev/null || true)"
        if [ -z "$v" ]; then
            v="$(_read_lgsm_cfg_value "$common_cfg" "$key" 2>/dev/null || true)"
        fi
        case "$key" in
            port)        INSTANCE_GAME_PORT="${v:-$DEFAULT_GAME_PORT}" ;;
            queryport)   INSTANCE_QUERY_PORT="${v:-$DEFAULT_QUERY_PORT}" ;;
            beaconport)  INSTANCE_BEACON_PORT="${v:-$DEFAULT_BEACON_PORT}" ;;
        esac
    done
    INSTANCE_GAME_PORT="${INSTANCE_GAME_PORT//[^0-9]/}"
    INSTANCE_QUERY_PORT="${INSTANCE_QUERY_PORT//[^0-9]/}"
    INSTANCE_BEACON_PORT="${INSTANCE_BEACON_PORT//[^0-9]/}"
    : "${INSTANCE_GAME_PORT:=$DEFAULT_GAME_PORT}"
    : "${INSTANCE_QUERY_PORT:=$DEFAULT_QUERY_PORT}"
    : "${INSTANCE_BEACON_PORT:=$DEFAULT_BEACON_PORT}"
    export INSTANCE_GAME_PORT INSTANCE_QUERY_PORT INSTANCE_BEACON_PORT
}
