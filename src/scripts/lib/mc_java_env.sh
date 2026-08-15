#!/bin/bash
# mc_java_env.sh — Apply Temurin JAVA_HOME from .mcprofile.json for LGSM start.
# Forge/NeoForge run.sh calls bare `java`; without this, system JDK 21 wins.
# shellcheck shell=bash
# Usage: . .../mc_java_env.sh; mc_java_env_apply "$SERVER_DIR"

mc_java_env_apply() {
    local server_dir="${1:-}"
    local profile java_home abs runsh
    [ -n "$server_dir" ] || return 0
    profile="$server_dir/.mcprofile.json"
    [ -f "$profile" ] || return 0

    java_home="$(perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $j = eval { decode_json(<$f>) } // {};
        print $j->{java_home} // "";
    ' "$profile" 2>/dev/null)" || return 0
    [ -n "$java_home" ] || return 0

    abs="$server_dir/$java_home"
    if [ ! -x "$abs/bin/java" ]; then
        echo "WARN: profile java missing at $abs/bin/java" >&2
        return 0
    fi

    export JAVA_HOME="$abs"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "=== MC JAVA_HOME=$JAVA_HOME ==="
    "$JAVA_HOME/bin/java" -version 2>&1 | head -n 1 || true

    # Pin absolute java in run.sh so tmux children do not pick system JDK 21.
    # NeoForge uses "exec java @args..."; Forge may use leading "java ".
    # Delimiter must NOT be | — pattern uses | for alternation.
    runsh="$server_dir/serverfiles/run.sh"
    if [ -f "$runsh" ] && grep -qE '(^|[[:space:]])java[[:space:]]' "$runsh"; then
        echo "=== Pinning $JAVA_HOME/bin/java into serverfiles/run.sh ==="
        sed -i -E 's#(^|[[:space:]])java([[:space:]])#\1'"$JAVA_HOME/bin/java"'\2#' "$runsh" || \
            echo "WARN: could not rewrite run.sh java path" >&2
    fi
    return 0
}
