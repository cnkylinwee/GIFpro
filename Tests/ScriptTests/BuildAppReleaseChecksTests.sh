#!/bin/sh

set -eu

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
fixture_bin="$project_root/Tests/ScriptTests/Fixtures/failing-stat"
log_file="$(mktemp /tmp/gifpro-build-app-test.XXXXXX)"
linked_parent="$(mktemp -d '/tmp/gifpro path test.XXXXXX')"
linked_project="$linked_parent/GIFpro linked workspace"
stat_marker="$linked_parent/stat-marker"
ln -s "$project_root" "$linked_project"
cleanup() {
    rm -f "$log_file" "$stat_marker" "$linked_project"
    rmdir "$linked_parent" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15

if GIFPRO_FAILING_STAT_MARKER="$stat_marker" PATH="$fixture_bin:$PATH" \
    "$project_root/Scripts/build-app.sh" release >"$log_file" 2>&1; then
    echo "error: release build succeeded after injected stat failure" >&2
    cat "$log_file" >&2
    exit 1
fi
if [ ! -f "$stat_marker" ] || [ "$(cat "$stat_marker")" != "stat -f %z" ]; then
    echo "error: injected stat fixture was not reached with the size arguments" >&2
    cat "$log_file" >&2
    exit 1
fi
diagnostic_count="$(awk '
    $0 == "error: could not stat release app file" { count += 1 }
    END { print count + 0 }
' "$log_file")"
if [ "$diagnostic_count" -ne 1 ]; then
    echo "error: expected exactly one stat failure diagnostic" >&2
    cat "$log_file" >&2
    exit 1
fi
if grep -Fq 'Release verification:' "$log_file"; then
    echo "error: failed release printed a successful verification message" >&2
    cat "$log_file" >&2
    exit 1
fi

"$linked_project/Scripts/build-app.sh" release
