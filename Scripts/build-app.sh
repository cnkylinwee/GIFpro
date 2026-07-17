#!/bin/sh

set -eu

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app_contents="$project_root/.build/app/GIFpro.app/Contents"
app_bundle="$project_root/.build/app/GIFpro.app"

cd "$project_root"
plutil -lint "$project_root/Resources/Info.plist"
swift build -c "$configuration" --arch arm64
binary_directory="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
executable="$binary_directory/GIFpro"

rm -rf "$app_contents"
mkdir -p "$app_contents/MacOS"
cp "$executable" "$app_contents/MacOS/GIFpro"
cp "$project_root/Resources/Info.plist" "$app_contents/Info.plist"

architectures="$(lipo -archs "$app_contents/MacOS/GIFpro")"
if [ "$architectures" != "arm64" ]; then
    echo "error: expected arm64-only executable, found: $architectures" >&2
    exit 1
fi

linked_libraries="$(otool -L "$app_contents/MacOS/GIFpro")"
non_system_dylibs="$(printf '%s\n' "$linked_libraries" | awk '
    NR > 1 {
        library = $1
        if (library !~ "^/System/Library/" && library !~ "^/usr/lib/") {
            print library
        }
    }
')"
if [ -n "$non_system_dylibs" ]; then
    echo "error: executable links non-system libraries:" >&2
    echo "$non_system_dylibs" >&2
    exit 1
fi

codesign --force --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

if [ "$configuration" = "release" ]; then
    app_bytes="$(find "$app_bundle" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
    maximum_bytes=$((10 * 1024 * 1024))
    if [ "$app_bytes" -ge "$maximum_bytes" ]; then
        echo "error: uncompressed app size must be below 10 MB; found $app_bytes bytes" >&2
        exit 1
    fi
    echo "Release verification: arm64 only; system dylibs only; $app_bytes bytes; signature valid"
fi

echo "Built $app_bundle"
