# job_log.sh — shared live-log setup for WebCore background workers.
# Root workers call job_log_init; game-user workers call job_log_init_as_user.
# Job dirs live under /home/<user>/jobs/<id>/ — files must be readable by Webmin
# (root) and writable by the worker without permission errors.

# Write one line immediately (bypasses block-buffered exec redirect for live polling).
job_log_line() {
    local job_dir="${1:?job_dir required}"
    shift
    printf '%s\n' "$*" >> "$job_dir/output"
}

job_log_init() {
    local job_dir="${1:?job_dir required}"
    local unix_user="${2:-}"
    rm -f "$job_dir/pgid" "$job_dir/output" 2>/dev/null || true
    echo $$ > "$job_dir/pgid"
    : > "$job_dir/output"
    if [[ -n "$unix_user" ]] && id "$unix_user" &>/dev/null; then
        chown "$unix_user:$unix_user" "$job_dir/pgid" "$job_dir/output" 2>/dev/null || true
        chmod 0640 "$job_dir/output" 2>/dev/null || true
    fi
    exec >> "$job_dir/output" 2>&1
    job_log_line "$job_dir" "=== Job log started (PID $$) ==="
}

job_log_init_as_user() {
    local job_dir="${1:?job_dir required}"
    rm -f "$job_dir/pgid" 2>/dev/null || true
    echo $$ > "$job_dir/pgid"
    if [ "${WEBCORE_APPEND_LOG:-0}" != "1" ]; then
        : > "$job_dir/output"
    fi
    exec >> "$job_dir/output" 2>&1
    if [ "${WEBCORE_APPEND_LOG:-0}" = "1" ]; then
        job_log_line "$job_dir" "=== Job phase continued (PID $$) ==="
    else
        job_log_line "$job_dir" "=== Job log started (PID $$) ==="
    fi
}

# Resume a failed job: append to existing output, do not truncate log.
job_log_resume_as_user() {
    local job_dir="${1:?job_dir required}"
    rm -f "$job_dir/pgid" 2>/dev/null || true
    echo $$ > "$job_dir/pgid"
    exec >> "$job_dir/output" 2>&1
    job_log_line "$job_dir" "=== Modpack import resumed (PID $$) ==="
}
