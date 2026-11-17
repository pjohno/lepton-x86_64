#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# `lepton start` makes a temporary /tmp/lepton-context.* folder. A launch that
# ends before teardown is set up (die, a failing command, Ctrl-C) must remove
# the folder it made, keep its exit status and message, and never remove an
# inherited prefix, one a container was given, or the persistent profile.
# Runs the real launcher from a copy with podman and the APK reader stubbed:
# no Android image, container or Steam needed.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
cleanup() {
    local p
    # Never leave test prefixes behind, even when an assertion fails.
    if [[ -f "$work/all-prefixes" ]]; then
        while read -r p; do
            [[ "$p" =~ ^/tmp/lepton-context\.[A-Za-z0-9]+$ && -d "$p" && ! -L "$p" ]] && rm -rf --one-file-system -- "$p"
        done < "$work/all-prefixes"
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ ! -f "$work/out" ]] || sed 's/^/  | /' "$work/out" >&2; exit 1; }

tool="$work/tool"
mkdir -p "$tool" "$work/bin" "$work/apks"
cp -r "$repo/compat_tool/lepton" "$repo/compat_tool/liblepton" "$tool/"
mkdir -p "$tool/liblepton/apk_extractor/bin"
# The APK reader records the prefix it was run under and can block, so a
# signal arrives while the launcher is still in early startup.
cat > "$tool/liblepton/apk_extractor/bin/apk-info-extractor" <<'EOF'
#!/bin/bash
echo "$LEPTON_PREFIX" | tee -a "$STUB_DIR/all-prefixes" >> "$STUB_DIR/prefixes"
if [[ -n "${STUB_BLOCK:-}" ]]; then touch "$STUB_DIR/blocked"; sleep 30; fi
case "$1" in
    --print-app-id) echo "${STUB_APP_ID:-}" ;;
    --print-activity-name) echo "${STUB_ACTIVITY:-}" ;;
esac
EOF
cat > "$work/bin/podman" <<'EOF'
#!/bin/bash
echo "podman $*" >> "$STUB_DIR/podman.log"
case "$1 ${2:-}" in
    "container exists")
        [[ -f "$STUB_DIR/exists-status" ]] && exit "$(cat "$STUB_DIR/exists-status")"
        exit 1 ;;
    "inspect -f") cat "$STUB_DIR/label" 2>/dev/null; exit $? ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$work/bin/systemctl"
chmod +x "$work/bin/"* "$tool/liblepton/apk_extractor/bin/apk-info-extractor"
echo 'not an apk' > "$work/apks/bad.apk"

home="$work/home"
mkdir -m 700 "$home"
profile="$home/.local/share/lepton/contexts/bad.apk/compatdata/bad.apk"
mkdir -p "$profile"
echo 'saved game' > "$profile/save.dat"

reset_stubs() {
    rm -f "$work/podman.log" "$work/exists-status" "$work/label" "$work/blocked" "$work/out"
    : > "$work/prefixes"
}
# A clean environment, so nothing from the caller (TMPDIR, Steam variables,
# an inherited LEPTON_PREFIX) changes what the launcher does.
lepton_env=(env -i "PATH=$work/bin:/usr/bin:/bin" "HOME=$home" TERM=dumb "STUB_DIR=$work")
run_start() { "${lepton_env[@]}" "$@" "$tool/lepton" start "$work/apks/bad.apk" > "$work/out" 2>&1; }
made_prefix() { head -n1 "$work/prefixes"; }
assert_gone() {
    local p; p="$(made_prefix)"
    [[ "$p" =~ ^/tmp/lepton-context\.[A-Za-z0-9]+$ ]] || fail "$1: launcher did not report a temporary prefix ($p)"
    [[ ! -e "$p" ]] || fail "$1: temporary prefix leaked: $p"
}
assert_profile() {
    [[ "$(cat "$profile/save.dat" 2>/dev/null)" == 'saved game' ]] || fail "$1: persistent profile data changed"
}

# 1. Invalid APK: die exits 1 with its message; the folder is removed.
reset_stubs
status=0; run_start || status=$?
[[ "$status" == 1 ]] || fail "invalid APK: exit status $status, expected 1"
grep -q "This file doesn't look like an Android app" "$work/out" || fail 'invalid APK: message missing'
assert_gone 'invalid APK'
assert_profile 'invalid APK'

# 2. A failing command under set -e (an unreadable APK cannot be copied).
#    The reader never runs, so compare /tmp before and after.
reset_stubs
before="$(compgen -G '/tmp/lepton-context.*' | sort || true)"
chmod 000 "$work/apks/bad.apk"
status=0; run_start || status=$?
chmod 644 "$work/apks/bad.apk"
after="$(compgen -G '/tmp/lepton-context.*' | sort || true)"
(( status != 0 )) || fail 'unreadable APK: launch succeeded'
grep -q 'Permission denied' "$work/out" || fail 'unreadable APK: no copy error shown'
new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
printf '%s\n' "$new" >> "$work/all-prefixes"
[[ -z "$new" ]] || fail "unreadable APK: temporary prefix leaked: $new"
assert_profile 'unreadable APK'

# 3. Ctrl-C (SIGINT) and Steam Stop (SIGTERM) to the launcher's process group
#    during early startup. Background jobs start with SIGINT ignored, so
#    restore the default first, as a terminal launch would have it.
for sig in INT TERM; do
    reset_stubs
    start=$SECONDS
    "${lepton_env[@]}" STUB_BLOCK=1 python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$tool/lepton" start "$work/apks/bad.apk" > "$work/out" 2>&1 &
    pid=$!
    for _ in $(seq 100); do [[ -e "$work/blocked" ]] && break; sleep 0.1; done
    [[ -e "$work/blocked" ]] || fail "SIG$sig: launcher never reached the APK reader"
    kill "-$sig" -- "-$pid"
    status=0; wait "$pid" || status=$?
    (( status != 0 )) || fail "SIG$sig: launch reported success"
    (( SECONDS - start < 20 )) || fail "SIG$sig: signal did not interrupt startup"
    assert_gone "SIG$sig"
    assert_profile "SIG$sig"
done

# 4. An inherited prefix is not ours, even with a launcher-like name.
reset_stubs
inherited="$(mktemp -d -p /tmp lepton-context.XXXXXXXXXX)"
echo keep > "$inherited/marker"
status=0; run_start "LEPTON_PREFIX=$inherited" || status=$?
[[ "$status" == 1 && -f "$inherited/marker" ]] || { rm -rf -- "$inherited"; fail 'inherited /tmp prefix removed'; }
rm -rf -- "$inherited"
# ... nor is a user-supplied directory.
reset_stubs
mkdir -p "$work/user-prefix"; echo keep > "$work/user-prefix/marker"
status=0; run_start "LEPTON_PREFIX=$work/user-prefix" || status=$?
[[ "$status" == 1 && -f "$work/user-prefix/marker" ]] || fail 'user-supplied prefix removed'
assert_profile 'supplied prefix'

# TMPDIR must not change the location of launcher-owned prefixes.
reset_stubs
mkdir -p "$work/alternate-tmp"
status=0; run_start "TMPDIR=$work/alternate-tmp" || status=$?
[[ "$status" == 1 ]] || fail 'TMPDIR: wrong exit status'
assert_gone 'TMPDIR'
[[ -z "$(ls -A "$work/alternate-tmp")" ]] || fail 'TMPDIR: unexpected files'

# An exported ownership claim cannot make an inherited prefix ours.
reset_stubs
inherited="$(mktemp -d -p /tmp lepton-context.XXXXXXXXXX)"
echo "$inherited" >> "$work/all-prefixes"
echo keep > "$inherited/marker"
status=0; run_start "LEPTON_PREFIX=$inherited" "LEPTON_PREFIX_OWNED=$inherited" || status=$?
[[ "$status" == 1 && -f "$inherited/marker" ]] || fail 'forged ownership: inherited prefix removed'

# 5. A container given this prefix may still use it: keep it. A container of
#    the same name with another prefix, or an unknown state, decide as below.
lib_fns() {
    for fn in println create_prefix profile_has_no_mounts remove_prefix remove_prefix_dir remove_owned_prefix; do
        sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/"*.sh
    done
}
check_exists_case() {
    local status="$1" label="$2" expect="$3" dir
    dir="$(mktemp -d -p /tmp lepton-context.XXXXXXXXXX)"; echo "$dir" >> "$work/all-prefixes"
    echo "$status" > "$work/exists-status"
    if [[ "$label" == same ]]; then echo "$dir" > "$work/label"; else echo "$label" > "$work/label"; fi
    [[ "$label" != inspection-failure ]] || rm -f "$work/label"
    "${lepton_env[@]}" LEPTON_CONTEXT=bad.apk LEPTON_PREFIX_OWNED="$dir" \
        bash -c "set -euo pipefail; print() { printf '%s' \"\$*\"; }; $(lib_fns); remove_owned_prefix" 2>> "$work/out"
    if [[ "$expect" == kept ]]; then [[ -d "$dir" ]] || fail "container status $status/$label: prefix removed"
    else [[ ! -e "$dir" ]] || fail "container status $status/$label: prefix kept"; fi
}
reset_stubs
check_exists_case 0 same kept
check_exists_case 0 '' kept
check_exists_case 0 '<no value>' kept
# No label file makes the inspect mock fail.
check_exists_case 0 inspection-failure kept
check_exists_case 0 /tmp/lepton-context.other removed
check_exists_case 125 '' kept
check_exists_case 1 '' removed

# Deletion requires ownership even when remove_prefix_dir is called directly.
reset_stubs
p="$(mktemp -d -p /tmp lepton-context.XXXXXXXXXX)"; echo "$p" >> "$work/all-prefixes"
"${lepton_env[@]}" LEPTON_CONTEXT=bad.apk LEPTON_PREFIX="$p" bash -c "set -euo pipefail; $(lib_fns); remove_prefix_dir \"\$LEPTON_PREFIX\""
[[ -d "$p" ]] || fail 'direct cleanup: unowned prefix removed'

# Failed allocation must not be hidden by the export builtin under set -e.
status=0
"${lepton_env[@]}" bash -c "set -euo pipefail; $(lib_fns); mktemp() { return 42; }; create_prefix; exit 99" || status=$?
[[ "$status" == 42 ]] || fail 'mktemp failure: status was hidden'

# Mount and symlink guards remain effective for owned directories.
for guard in mounted mount-error symlink noncanonical; do
    reset_stubs
    p="$(mktemp -d -p /tmp lepton-context.XXXXXXXXXX)"; echo "$p" >> "$work/all-prefixes"
    echo keep > "$p/marker"
    case "$guard" in
        mounted) mock='findmnt() { echo "$LEPTON_PREFIX overlay"; }' ;;
        mount-error) mock='findmnt() { return 1; }' ;;
        symlink)
            rm -- "$p/marker"
            rmdir "$p"
            ln -s "$work/user-prefix" "$p"; mock=':' ;;
        noncanonical) p="$p/../$(basename "$p")"; mock=':' ;;
    esac
    "${lepton_env[@]}" LEPTON_CONTEXT=bad.apk LEPTON_PREFIX="$p" LEPTON_PREFIX_OWNED="$p" bash -c "set -euo pipefail; print() { printf '%s' \"\$*\"; }; $(lib_fns); $mock; remove_baked_workdirs() { :; }; remove_prefix" 2>> "$work/out"
    [[ -e "$p/marker" ]] || fail "$guard: prefix guard failed"
    [[ "$guard" != symlink ]] || rm -- "$p"
done

# 6. Mocked successful launch: teardown (not the early-exit trap) removes the
#    prefix, exactly once; a start_container failure after the container was
#    created keeps the prefix that container was given.
cat >> "$tool/liblepton/liblepton.sh" <<'EOF'
# --- test doubles for the container lifecycle ---
autobake() { :; }; ensure_permissions_ok() { :; }; print_apk_info() { :; }
setup_container() { :; }; generate_app_launch_rc() { :; }; generate_zygote_launch_rc() { :; }
start_container() {
    echo 0 > "$STUB_DIR/exists-status"; echo "$LEPTON_PREFIX" > "$STUB_DIR/label"
    [[ -z "${STUB_START_FAILS:-}" ]]
}
app_install_needed() { return 1; }; auto_install_apps() { :; }
wait_for_container() { [[ -d "$LEPTON_PREFIX" ]] && echo 'prefix present while running' >> "$STUB_DIR/events"; }
kill_container() { :; }; cleanup_container() {
    [[ -n "${STUB_RETAIN_CONTAINER:-}" ]] || echo 1 > "$STUB_DIR/exists-status"
}
remove_baked_workdirs() { echo teardown >> "$STUB_DIR/events"; }
dump_logcat() { :; }; ndk_note_early_exit() { :; }
EOF
reset_stubs; rm -f "$work/events"
status=0; run_start STUB_APP_ID=com.example.game STUB_ACTIVITY=.Main || status=$?
[[ "$status" == 0 ]] || fail "mocked launch: exit status $status"
grep -qx 'prefix present while running' "$work/events" || fail 'mocked launch: prefix missing while running'
[[ "$(grep -c '^teardown$' "$work/events")" == 1 ]] || fail 'mocked launch: teardown did not run exactly once'
! grep -q 'prefix retained\|unrecognised prefix' "$work/out" || fail 'mocked launch: early-exit cleanup ran after handover'
assert_gone 'mocked launch'
assert_profile 'mocked launch'

reset_stubs
status=0; run_start "TMPDIR=$work/alternate-tmp" STUB_APP_ID=com.example.game STUB_ACTIVITY=.Main || status=$?
[[ "$status" == 0 ]] || fail 'successful TMPDIR launch failed'
assert_gone 'successful TMPDIR launch'

# Successful launches also preserve supplied prefixes, including forged ownership.
for supplied in "$inherited" "$work/user-prefix"; do
    reset_stubs
    status=0; run_start "LEPTON_PREFIX=$supplied" "LEPTON_PREFIX_OWNED=$supplied" STUB_APP_ID=com.example.game STUB_ACTIVITY=.Main || status=$?
    [[ "$status" == 0 && -f "$supplied/marker" ]] || fail 'successful launch: supplied prefix removed'
    assert_profile 'successful supplied prefix'
done

reset_stubs
status=0; run_start STUB_APP_ID=com.example.game STUB_ACTIVITY=.Main STUB_START_FAILS=1 || status=$?
(( status != 0 )) || fail 'failed container start: launch succeeded'
p="$(made_prefix)"
[[ -d "$p" ]] || fail 'failed container start: prefix of an existing container removed'
grep -q 'Temporary prefix retained' "$work/out" || fail 'failed container start: no retention message'

# Normal teardown must retain prefixes too when removal/inspection is uncertain.
for retained in 0 125; do
    reset_stubs
    status=0; run_start STUB_APP_ID=com.example.game STUB_ACTIVITY=.Main STUB_RETAIN_CONTAINER=1 || status=$?
    [[ "$status" == 0 && -d "$(made_prefix)" ]] || fail 'normal teardown: in-use prefix removed'
    # Exercise the same normal-teardown entry point with an inspection error.
    echo "$retained" > "$work/exists-status"
    p="$(made_prefix)"
    "${lepton_env[@]}" LEPTON_CONTEXT=bad.apk LEPTON_PREFIX="$p" LEPTON_PREFIX_OWNED="$p" bash -c "set -euo pipefail; print() { printf '%s' \"\$*\"; }; $(lib_fns); remove_baked_workdirs() { :; }; remove_prefix" 2>> "$work/out"
    [[ -d "$p" ]] || fail 'normal teardown: uncertain container prefix removed'
done

echo 'PASS: prefix ownership, allocation failure, TMPDIR, signals, successful/failed launch, container uncertainty, mount/symlink guards and profile preservation (mocked lifecycle)'
