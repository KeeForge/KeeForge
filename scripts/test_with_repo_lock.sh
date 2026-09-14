#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly REPO_ROOT
readonly LOCK_SCRIPT="$REPO_ROOT/scripts/with-repo-lock.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-repo-lock.XXXXXX")"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'test_with_repo_lock: %s\n' "$1" >&2
    exit 1
}

make_repo() {
    local path="$1"
    mkdir -p "$path"
    git -C "$path" init -q
}

run_in_repo() {
    local path="$1"
    shift
    (
        cd "$path"
        "$LOCK_SCRIPT" "$@"
    )
}

normal_repo="$TEST_ROOT/normal"
make_repo "$normal_repo"
run_in_repo "$normal_repo" xcode -- /usr/bin/true
[ ! -e "$normal_repo/.git/keeforge-locks/xcode.lock" ] || fail "normal run leaked its lock"
run_in_repo "$normal_repo" acquire --max-hold 30 xcode >/dev/null
[ -d "$normal_repo/.git/keeforge-locks/xcode.lock" ] || fail "acquire did not create its lock"
run_in_repo "$normal_repo" release xcode >/dev/null
[ ! -e "$normal_repo/.git/keeforge-locks/xcode.lock" ] || fail "release did not remove its lock"

held_repo="$TEST_ROOT/held"
make_repo "$held_repo"
held_dir="$held_repo/.git/keeforge-locks/xcode.lock"
mkdir -p "$held_dir"
cat > "$held_dir/info" <<EOF
pid=$$
mode=running
host=$(hostname -s)
started=test
label=
command=test
EOF
if run_in_repo "$held_repo" --timeout 0 xcode -- /usr/bin/true >"$TEST_ROOT/held.out" 2>&1; then
    fail "held lock unexpectedly ran the command"
else
    status=$?
fi
[ "$status" -eq 75 ] || fail "held lock exited $status, expected 75"
rg -q 'timed out after 0s waiting for "xcode"' "$TEST_ROOT/held.out" || \
    fail "held lock did not report its holder"

race_repo="$TEST_ROOT/race"
make_repo "$race_repo"
stub_bin="$TEST_ROOT/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/mkdir" <<EOF
#!/bin/bash
if [ "\$1" = "-p" ]; then
    exec /bin/mkdir "\$@"
fi
count_file="$TEST_ROOT/race-mkdir-count"
count=0
[ -f "\$count_file" ] && count=\$(cat "\$count_file")
count=\$((count + 1))
printf '%s' "\$count" > "\$count_file"
if [ "\$count" -eq 1 ]; then
    printf 'mkdir: %s: File exists\\n' "\$1" >&2
    exit 1
fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$stub_bin/mkdir"
(
    cd "$race_repo"
    PATH="$stub_bin:$PATH" "$LOCK_SCRIPT" xcode -- /usr/bin/true
)
[ "$(cat "$TEST_ROOT/race-mkdir-count")" -eq 2 ] || \
    fail "missing-directory race was not reconciled"

denied_repo="$TEST_ROOT/denied"
make_repo "$denied_repo"
cat > "$stub_bin/mkdir" <<EOF
#!/bin/bash
if [ "\$1" = "-p" ]; then
    exec /bin/mkdir "\$@"
fi
printf 'mkdir: %s: Permission denied\\n' "\$1" >&2
exit 1
EOF
chmod +x "$stub_bin/mkdir"
if (
    cd "$denied_repo"
    PATH="$stub_bin:$PATH" "$LOCK_SCRIPT" --timeout 5400 xcode -- /usr/bin/true
) >"$TEST_ROOT/denied.out" 2>&1; then
    fail "denied lock path unexpectedly ran the command"
else
    status=$?
fi
[ "$status" -eq 73 ] || fail "denied lock path exited $status, expected 73"
rg -q 'cannot create lock directory.*no lock holder exists' "$TEST_ROOT/denied.out" || \
    fail "denied lock path did not explain the missing holder"
rg -q 'mkdir exited 1' "$TEST_ROOT/denied.out" || \
    fail "denied lock path did not retain mkdir's exit status"
rg -q 'Permission denied' "$TEST_ROOT/denied.out" || \
    fail "denied lock path did not retain mkdir's error"

printf 'with-repo-lock fixtures passed\n'
