#!/bin/sh

set -eu

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
fixture_bin="$project_root/Tests/ScriptTests/Fixtures/failing-stat"
log_file="$(mktemp /tmp/gifpro-build-app-test.XXXXXX)"
linked_parent="$(mktemp -d '/tmp/gifpro path test.XXXXXX')"
linked_project="$linked_parent/GIFpro linked workspace"
fixture_resources="$(mktemp -d /tmp/gifpro-control-assets.XXXXXX)"
stat_marker="$linked_parent/stat-marker"
ln -s "$project_root" "$linked_project"
cleanup() {
    rm -f "$log_file" "$stat_marker" "$linked_project"
    rm -rf "$fixture_resources"
    rmdir "$linked_parent" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15

assert_single_diagnostic() {
    expected_diagnostic="$1"
    actual_count="$(awk -v expected="$expected_diagnostic" '
        $0 == expected { count += 1 }
        END { print count + 0 }
    ' "$log_file")"
    if [ "$actual_count" -ne 1 ]; then
        echo "error: expected exactly one diagnostic: $expected_diagnostic" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

assert_bundle_assets() {
    configuration="$1"
    bundled_resources="$project_root/.build/app/GIFpro.app/Contents/Resources"
    resource_file_list="$fixture_resources/bundle-resource-files"
    if ! find "$bundled_resources" -type f -print0 >"$resource_file_list"; then
        echo "error: $configuration bundle resources could not be enumerated" >&2
        exit 1
    fi
    regular_file_count=0
    has_unexpected_regular_file=0
    exec 4<"$resource_file_list"
    while IFS= read -r -d '' _resource_file <&4; do
        regular_file_count=$((regular_file_count + 1))
        case "$_resource_file" in
            "$bundled_resources/RecordButton.png"|"$bundled_resources/StopButton.png"|"$bundled_resources/AppIcon.icns") ;;
            *) has_unexpected_regular_file=1 ;;
        esac
    done
    exec 4<&-
    rm -f "$resource_file_list"
    if [ "$regular_file_count" -ne 3 ]; then
        echo "error: $configuration bundle resources must contain exactly 3 regular files; found $regular_file_count" >&2
        exit 1
    fi
    if [ "$has_unexpected_regular_file" -ne 0 ]; then
        echo "error: $configuration bundle resources contain an unexpected regular file" >&2
        exit 1
    fi
    for asset_name in RecordButton.png StopButton.png AppIcon.icns; do
        if [ ! -f "$bundled_resources/$asset_name" ]; then
            echo "error: $configuration bundle is missing $asset_name" >&2
            exit 1
        fi
        if ! cmp "$project_root/Resources/$asset_name" "$bundled_resources/$asset_name"; then
            echo "error: $configuration bundle asset differs: $asset_name" >&2
            exit 1
        fi
    done
}

cp "$project_root/Resources/RecordButton.png" "$fixture_resources/RecordButton.png"
cp "$project_root/Resources/StopButton.png" "$fixture_resources/StopButton.png"
"$project_root/Scripts/validate-control-assets.sh" "$fixture_resources"

rm "$fixture_resources/StopButton.png"
if "$project_root/Scripts/validate-control-assets.sh" "$fixture_resources" >"$log_file" 2>&1; then
    echo "error: validator accepted a missing StopButton.png" >&2
    exit 1
fi
assert_single_diagnostic "error: missing control asset: StopButton.png"
if grep -Fq 'RecordButton.png' "$log_file"; then
    echo "error: missing-asset validation reported an unrelated asset" >&2
    cat "$log_file" >&2
    exit 1
fi

cp "$project_root/Resources/StopButton.png" "$fixture_resources/StopButton.png"
dd if="$project_root/Resources/RecordButton.png" \
    of="$fixture_resources/RecordButton.png" bs=64 count=1 2>/dev/null
fixture_format="$(LC_ALL=C /usr/bin/sips --getProperty format \
    "$fixture_resources/RecordButton.png" 2>/dev/null | awk '
        $1 == "format:" { print $2 }
    ')"
if [ "$fixture_format" != "png" ]; then
    echo "error: corrupt fixture did not reach the PNG decode gate" >&2
    exit 1
fi
if "$project_root/Scripts/validate-control-assets.sh" "$fixture_resources" >"$log_file" 2>&1; then
    echo "error: validator accepted a corrupt RecordButton.png" >&2
    exit 1
fi
assert_single_diagnostic "error: invalid PNG control asset: RecordButton.png"
if grep -Fq 'StopButton.png' "$log_file"; then
    echo "error: corrupt-asset validation reported an unrelated asset" >&2
    cat "$log_file" >&2
    exit 1
fi

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

"$linked_project/Scripts/build-app.sh" debug
assert_bundle_assets debug
unexpected_asset_name="$(printf 'Unexpected\nAsset')"
: >"$project_root/.build/app/GIFpro.app/Contents/Resources/$unexpected_asset_name"
if (assert_bundle_assets debug) >"$log_file" 2>&1; then
    echo "error: debug bundle assertion accepted an unexpected regular file" >&2
    exit 1
fi
assert_single_diagnostic "error: debug bundle resources must contain exactly 3 regular files; found 4"

"$linked_project/Scripts/build-app.sh" release
assert_bundle_assets release

app_bundle="$project_root/.build/app/GIFpro.app"
app_contents="$app_bundle/Contents"
if [ "$(lipo -archs "$app_contents/MacOS/GIFpro")" != "arm64" ]; then
    echo "error: release bundle executable is not arm64-only" >&2
    exit 1
fi
non_system_dylibs="$(otool -L "$app_contents/MacOS/GIFpro" | awk '
    NR > 1 && $1 !~ "^/System/Library/" && $1 !~ "^/usr/lib/" { print $1 }
')"
if [ -n "$non_system_dylibs" ]; then
    echo "error: release bundle links non-system libraries:" >&2
    echo "$non_system_dylibs" >&2
    exit 1
fi
codesign --verify --deep --strict "$app_bundle"
plutil -lint "$app_contents/Info.plist"
cmp "$project_root/Resources/Info.plist" "$app_contents/Info.plist"
if [ "$(plutil -extract CFBundleIconFile raw -o - "$app_contents/Info.plist")" != "AppIcon" ]; then
    echo "error: release bundle does not declare AppIcon" >&2
    exit 1
fi
app_bytes="$(find "$app_bundle" -type f -exec stat -f '%z' {} \; | awk '{ total += $1 } END { printf "%.0f\n", total }')"
if [ "$app_bytes" -ge $((10 * 1024 * 1024)) ]; then
    echo "error: release app is not below 10 MB: $app_bytes bytes" >&2
    exit 1
fi
