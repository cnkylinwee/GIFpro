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

cd "$project_root"
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
    NR > 1 && $1 !~ "^/System/Library/" && $1 !~ "^/usr/lib/" { print $1 }
')"
if [ -n "$non_system_dylibs" ]; then
    echo "error: executable links non-system libraries:" >&2
    echo "$non_system_dylibs" >&2
    exit 1
fi

codesign --force --sign - "$project_root/.build/app/GIFpro.app"
echo "Built $project_root/.build/app/GIFpro.app"
