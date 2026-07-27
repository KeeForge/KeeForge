#!/bin/bash
#
# with-repo-lock.sh — repo-wide, cross-worktree mutex for build/test and CI operations.
#
# Purpose
#   Serialize the local Xcode operations that must not overlap between concurrent
#   agent sessions: builds, unit and UI tests, iOS Simulator work, and macOS app
#   tests. All of them contend for the same toolchain, simulators, and (for macOS
#   UI tests) the physical screen and input focus.
#
# Why it works across worktrees
#   The lock directory lives under the *common* git dir (`git rev-parse
#   --git-common-dir`), which every linked worktree shares with the main checkout.
#   A lock taken in `.claude/worktrees/foo` therefore blocks one taken in the main
#   repo, and vice versa.
#
# Usage
#   with-repo-lock.sh [options] <lock-name> -- <command> [args...]   # wrap one command
#   with-repo-lock.sh acquire [options] <lock-name>                  # hold across turns
#   with-repo-lock.sh release <lock-name>
#   with-repo-lock.sh --status [<lock-name>]
#
# Options
#   --timeout SECONDS   How long to wait for the lock. Default 5400 (90 min).
#                       0 = fail immediately if held; 'none' = wait forever.
#   --label TEXT        Human-readable note recorded in the lock metadata.
#   --max-hold SECONDS  (acquire only) Safety expiry for a held lock. Default 10800
#                       (3h); after that the lock goes stale and is reclaimable.
#   --force-break       Remove an existing lock before acquiring (last resort).
#
# Exit codes
#   64          usage error
#   75          timed out waiting for the lock (EX_TEMPFAIL)
#   otherwise   the wrapped command's own exit status
#
# Notes
#   - A lock whose holder process is gone (same host) is stale and gets broken
#     automatically, so a crashed agent never wedges the repo.
#   - Re-entrant: if this process tree already holds the named lock (tracked via
#     KEEFORGE_HELD_LOCKS), the wrapped command runs directly instead of deadlocking.

set -uo pipefail

readonly DEFAULT_TIMEOUT=5400
readonly DEFAULT_MAX_HOLD=10800
readonly POLL_INTERVAL=5
readonly PROGRESS_INTERVAL=60

usage() {
    cat <<'EOF'
Repo-wide, cross-worktree mutex for build/test and CI operations.

Usage:
  with-repo-lock.sh [options] <lock-name> -- <command> [args...]   wrap one command
  with-repo-lock.sh acquire [options] <lock-name>                  hold across turns
  with-repo-lock.sh release <lock-name>
  with-repo-lock.sh --status [<lock-name>]

Options:
  --timeout SECONDS   Wait this long for the lock (default 5400; 0 = fail fast;
                      'none' = wait forever). Exits 75 on timeout.
  --label TEXT        Human-readable note recorded in the lock metadata.
  --max-hold SECONDS  acquire only: safety expiry for the hold (default 10800).
  --force-break       Remove an existing lock before acquiring (last resort).

Conventional lock name: 'xcode' — every local build, test, iOS Simulator run, and
macOS app test takes it, so only one such operation runs on this Mac at a time.
EOF
}

die() {
    printf 'with-repo-lock: %s\n' "$1" >&2
    exit "${2:-64}"
}

lock_root() {
    local common_dir
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || \
        die "not inside a git repository"
    # --git-common-dir may be relative to the current directory.
    case "$common_dir" in
        /*) ;;
        *) common_dir="$PWD/$common_dir" ;;
    esac
    # Resolve without requiring realpath's -m/--canonicalize-missing.
    common_dir=$(cd "$common_dir" && pwd -P) || die "cannot resolve git common dir"
    printf '%s/keeforge-locks' "$common_dir"
}

meta() {
    sed -n "s/^$2=//p" "$1/info" 2>/dev/null
}

holder_line() {
    local dir="$1" label
    [ -f "$dir/info" ] || { printf 'unknown holder\n'; return; }
    label=$(meta "$dir" label)
    printf 'pid %s on %s, since %s\n  worktree: %s\n  command:  %s\n' \
        "$(meta "$dir" pid)" "$(meta "$dir" host)" "$(meta "$dir" started)" \
        "$(meta "$dir" worktree)" "$(meta "$dir" command)"
    [ -n "$label" ] && printf '  label:    %s\n' "$label"
    return 0
}

# Returns 0 if the lock directory belongs to a process that is gone.
is_stale() {
    local dir="$1" pid host
    if [ ! -f "$dir/info" ]; then
        # Either the holder is mid-acquisition (info not written yet) or it died in
        # that window. Only call it stale once the gap is implausibly long.
        [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ] && return 0
        return 1
    fi
    pid=$(meta "$dir" pid)
    host=$(meta "$dir" host)
    [ -n "$pid" ] || return 0
    # Only judge liveness for locks taken on this machine.
    [ "$host" = "$(hostname -s)" ] || return 1
    kill -0 "$pid" 2>/dev/null && return 1
    return 0
}

write_info() {
    local dir="$1" pid="$2" mode="$3" label="$4" command="$5"
    {
        printf 'pid=%s\n' "$pid"
        printf 'mode=%s\n' "$mode"
        printf 'host=%s\n' "$(hostname -s)"
        printf 'worktree=%s\n' "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
        printf 'branch=%s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        printf 'started=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'label=%s\n' "$label"
        printf 'command=%s\n' "$command"
    } > "$dir/info"
}

# Spin until the lock directory is ours. Sets CLAIM_WAITED; returns 75 on timeout.
# Never call this in a command substitution — the caller must see the return status.
CLAIM_WAITED=0
claim_dir() {
    local dir="$1" name="$2" timeout="$3"
    local waited=0 announced=0
    CLAIM_WAITED=0
    while ! mkdir "$dir" 2>/dev/null; do
        if is_stale "$dir"; then
            printf 'with-repo-lock: breaking stale lock "%s" (holder process gone)\n' \
                "$name" >&2
            rm -rf "$dir"
            continue
        fi
        if [ "$timeout" != "none" ] && [ "$waited" -ge "$timeout" ]; then
            printf 'with-repo-lock: timed out after %ss waiting for "%s".\nHeld by %s' \
                "$timeout" "$name" "$(holder_line "$dir")" >&2
            printf '\n' >&2
            return 75
        fi
        if [ "$announced" -eq 0 ] || [ $((waited % PROGRESS_INTERVAL)) -eq 0 ]; then
            printf 'with-repo-lock: waiting for "%s" (%ss elapsed). Held by %s' \
                "$name" "$waited" "$(holder_line "$dir")" >&2
            printf '\n' >&2
            announced=1
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    CLAIM_WAITED="$waited"
    return 0
}

validate_name() {
    case "$1" in
        '') die "missing <lock-name>" ;;
        *[!a-zA-Z0-9._-]*) die "lock name must be [A-Za-z0-9._-]: $1" ;;
    esac
}

validate_timeout() {
    [ "$1" = "none" ] && return 0
    case "$1" in
        ''|*[!0-9]*) die "--timeout must be a non-negative integer or 'none'" ;;
    esac
}

print_status() {
    local root filter="${1:-}" dir name found=0
    root=$(lock_root) || exit $?
    [ -d "$root" ] || { printf 'No locks held (%s).\n' "$root"; return 0; }
    for dir in "$root"/*.lock; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir" .lock)
        [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
        found=1
        if is_stale "$dir"; then
            printf '%s: STALE (holder gone, reclaimable) — %s' "$name" "$(holder_line "$dir")"
        else
            printf '%s: HELD (%s) — %s' "$name" "$(meta "$dir" mode)" "$(holder_line "$dir")"
        fi
        printf '\n'
    done
    [ "$found" -eq 0 ] && printf 'No locks held (%s).\n' "$root"
    return 0
}

# `acquire`: take the lock and keep it after this process exits, so an agent can hold
# it across several turns. A detached sleeper process stands in as the holder, which
# keeps the existing pid-liveness staleness check working.
do_acquire() {
    local timeout="$DEFAULT_TIMEOUT" label="" max_hold="$DEFAULT_MAX_HOLD"
    local force_break=0 name="" root dir waited sleeper_pid

    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift 2 ;;
            --timeout=*) timeout="${1#--timeout=}"; shift ;;
            --label) [ $# -ge 2 ] || die "--label needs a value"; label="$2"; shift 2 ;;
            --label=*) label="${1#--label=}"; shift ;;
            --max-hold) [ $# -ge 2 ] || die "--max-hold needs a value"; max_hold="$2"; shift 2 ;;
            --max-hold=*) max_hold="${1#--max-hold=}"; shift ;;
            --force-break) force_break=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
        esac
    done

    validate_name "$name"
    validate_timeout "$timeout"
    case "$max_hold" in ''|*[!0-9]*) die "--max-hold must be a positive integer" ;; esac

    root=$(lock_root) || exit $?
    mkdir -p "$root" || die "cannot create lock root: $root"
    dir="$root/$name.lock"

    if [ "$force_break" -eq 1 ] && [ -d "$dir" ]; then
        printf 'with-repo-lock: force-breaking "%s"\n' "$name" >&2
        rm -rf "$dir"
    fi

    claim_dir "$dir" "$name" "$timeout" || exit $?
    waited="$CLAIM_WAITED"
    nohup sleep "$max_hold" >/dev/null 2>&1 &
    sleeper_pid=$!
    disown "$sleeper_pid" 2>/dev/null
    write_info "$dir" "$sleeper_pid" "held" "$label" \
        "(held by agent; expires in ${max_hold}s unless released)"

    printf 'with-repo-lock: acquired "%s"%s (expires in %ss if not released).\n' \
        "$name" "$([ "$waited" -gt 0 ] && printf ' after %ss' "$waited")" "$max_hold"
    printf 'While you hold it, either run commands directly, or pass the hold through\n'
    printf 'so a wrapped run does not block on your own lock:\n'
    printf '  KEEFORGE_HELD_LOCKS=%s %s %s -- <command>\n' "$name" "$0" "$name"
    printf 'Release it with:\n  %s release %s\n' "$0" "$name"
}

do_release() {
    local name="${1:-}" root dir pid
    validate_name "$name"
    [ $# -le 1 ] || die "release takes only <lock-name>"

    root=$(lock_root) || exit $?
    dir="$root/$name.lock"
    [ -d "$dir" ] || { printf 'with-repo-lock: "%s" is not held.\n' "$name"; return 0; }

    pid=$(meta "$dir" pid)
    if [ "$(meta "$dir" mode)" = "held" ] && [ -n "$pid" ] && \
       [ "$(meta "$dir" host)" = "$(hostname -s)" ]; then
        kill "$pid" 2>/dev/null
    fi
    rm -rf "$dir"
    printf 'with-repo-lock: released "%s".\n' "$name"
}

do_run() {
    local timeout="$DEFAULT_TIMEOUT" label="" force_break=0 name="" root dir waited

    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift 2 ;;
            --timeout=*) timeout="${1#--timeout=}"; shift ;;
            --label) [ $# -ge 2 ] || die "--label needs a value"; label="$2"; shift 2 ;;
            --label=*) label="${1#--label=}"; shift ;;
            --force-break) force_break=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) die "unknown option: $1" ;;
            *)
                [ -z "$name" ] || die "unexpected argument: $1 (did you forget '--'?)"
                name="$1"; shift ;;
        esac
    done

    validate_name "$name"
    validate_timeout "$timeout"
    [ $# -gt 0 ] || die "missing command after '--'"

    # Re-entrancy: this process tree already holds the lock.
    case ":${KEEFORGE_HELD_LOCKS:-}:" in
        *":$name:"*) "$@"; exit $? ;;
    esac

    root=$(lock_root) || exit $?
    mkdir -p "$root" || die "cannot create lock root: $root"
    dir="$root/$name.lock"

    if [ "$force_break" -eq 1 ] && [ -d "$dir" ]; then
        printf 'with-repo-lock: force-breaking "%s"\n' "$name" >&2
        rm -rf "$dir"
    fi

    claim_dir "$dir" "$name" "$timeout" || exit $?
    waited="$CLAIM_WAITED"

    # shellcheck disable=SC2064  # expand $dir now, not at trap time
    trap "rm -rf '$dir'" EXIT INT TERM HUP
    write_info "$dir" "$$" "running" "$label" "$*"

    [ "$waited" -gt 0 ] && \
        printf 'with-repo-lock: acquired "%s" after %ss.\n' "$name" "$waited" >&2

    KEEFORGE_HELD_LOCKS="${KEEFORGE_HELD_LOCKS:+$KEEFORGE_HELD_LOCKS:}$name" "$@"
    exit $?
}

case "${1:-}" in
    '') usage >&2; exit 64 ;;
    acquire) shift; do_acquire "$@" ;;
    release) shift; do_release "$@" ;;
    --status) shift; print_status "${1:-}" ;;
    -h|--help) usage ;;
    *) do_run "$@" ;;
esac
