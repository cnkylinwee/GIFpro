#!/bin/sh

set -eu

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
fixture_bin="$project_root/Tests/ScriptTests/Fixtures/failing-stat"
log_file="$(mktemp /tmp/gifpro-build-app-test.XXXXXX)"
linked_parent="$(mktemp -d '/tmp/gifpro path test.XXXXXX')"
linked_project="$linked_parent/GIFpro linked workspace"
ln -s "$project_root" "$linked_project"
cleanup() {
    rm -f "$log_file" "$linked_project"
    rmdir "$linked_parent" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15

if PATH="$fixture_bin:$PATH" "$project_root/Scripts/build-app.sh" release >"$log_file" 2>&1; then
    echo "error: release build succeeded after injected stat failure" >&2
    cat "$log_file" >&2
    exit 1
fi

"$linked_project/Scripts/build-app.sh" release
