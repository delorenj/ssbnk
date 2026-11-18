#!/usr/bin/env bash
# Isolated command shims exercise the shortcut contract; this is not a desktop test.
set -euo pipefail
root=$(mktemp -d "${TMPDIR:?}/ssbnk-paste-test.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/state" "$root/hosted"
script="$(cd "$(dirname "$0")" && pwd)/paste-image.sh"
export SSBNK_STATE_DIR="$root/state" SSBNK_HOSTED_DIR="$root/hosted"
export SSBNK_TEST_ROOT="$root" PATH="$root/bin:$PATH"
printf 'original URL' > "$root/clipboard"
printf 'image bytes' > "$root/hosted/shot.png"
printf 'shot.png\n' > "$root/state/last-screenshot"

for command in wl-copy wl-paste ydotool notify-send sleep; do
    ln -s "$root/bin/shim" "$root/bin/$command"
done
cat > "$root/bin/shim" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
root=$SSBNK_TEST_ROOT
case "${0##*/}" in
    wl-paste)
        printf 'wl-paste %s %s\n' "${WAYLAND_DISPLAY:-unset}" "${XDG_RUNTIME_DIR:-unset}" >> "$root/calls"
        if [ -f "$root/fail-read" ]; then exit 1; fi
        cat "$root/clipboard" ;;
    wl-copy)
        printf 'wl-copy %s\n' "$*" >> "$root/calls"
        cat > "$root/clipboard" ;;
    ydotool)
        printf 'ydotool %s\n' "$*" >> "$root/calls"
        if [ -f "$root/fail-key" ]; then exit 1; fi ;;
    notify-send) printf 'notify %s\n' "$*" >> "$root/calls" ;;
    sleep) : ;;
esac
SHIM
chmod +x "$root/bin/shim"

assert_failure() {
    local expected=$1
    : > "$root/calls"
    if env -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR bash "$script"; then
        printf 'expected failure: %s\n' "$expected" >&2; exit 1
    fi
    test "$(<"$root/clipboard")" = 'original URL'
    grep -q "notify ssbnk $expected" "$root/calls"
    if grep -q '^wl-copy' "$root/calls"; then
        printf 'unexpected clipboard mutation\n' >&2; exit 1
    fi
}

rm "$root/state/last-screenshot"
assert_failure 'No recent screenshot'
printf 'missing.png\n' > "$root/state/last-screenshot"
assert_failure 'Screenshot file not found:'
printf '../shot.png\n' > "$root/state/last-screenshot"
assert_failure 'Invalid screenshot marker'
printf 'shot.png\n' > "$root/state/last-screenshot"
touch "$root/fail-read"
assert_failure 'Could not read text clipboard'
rm "$root/fail-read"
: > "$root/calls"
env -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR bash "$script"
test "$(<"$root/clipboard")" = 'original URL'
grep -q '^wl-paste wayland-0 /run/user/' "$root/calls"
grep -q '^wl-copy --type image/png$' "$root/calls"
grep -q '^ydotool key 29:1 47:1 47:0 29:0$' "$root/calls"
grep -q '^wl-copy --type text/plain;charset=utf-8$' "$root/calls" || {
    printf 'restore call missing; calls:\n' >&2
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$root/calls"
    exit 1
}
# Even a failed key injection restores the clipboard instead of leaving image data.
touch "$root/fail-key"
if bash "$script"; then
    printf 'expected key injection failure\n' >&2; exit 1
fi
test "$(<"$root/clipboard")" = 'original URL'
printf 'paste-image shell contract passed\n'
