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
"$project_root/Scripts/validate-control-assets.sh" "$project_root/Resources"
swift build -c "$configuration" --arch arm64
binary_directory="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
executable="$binary_directory/GIFpro"

rm -rf "$app_contents"
mkdir -p "$app_contents/MacOS" "$app_contents/Resources"
cp "$executable" "$app_contents/MacOS/GIFpro"
cp "$project_root/Resources/Info.plist" "$app_contents/Info.plist"
for asset_name in RecordButton.png StopButton.png; do
    cp "$project_root/Resources/$asset_name" "$app_contents/Resources/$asset_name"
    if ! cmp "$project_root/Resources/$asset_name" "$app_contents/Resources/$asset_name"; then
        echo "error: copied control asset differs: $asset_name" >&2
        exit 1
    fi
done

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
    maximum_bytes=$((10 * 1024 * 1024))
    size_work_directory="$(mktemp -d /tmp/gifpro-app-size.XXXXXX)"
    file_list="$size_work_directory/files"
    size_data="$size_work_directory/sizes"
    cleanup_size_work_directory() {
        rm -f "$file_list" "$size_data"
        rmdir "$size_work_directory" 2>/dev/null || :
    }
    trap cleanup_size_work_directory 0
    trap 'exit 1' 1 2 15

    if ! find "$app_bundle" -type f -print0 >"$file_list"; then
        echo "error: could not enumerate release app files" >&2
        exit 1
    fi
    : >"$size_data"
    file_count=0
    exec 3<"$file_list"
    while IFS= read -r -d '' file_path <&3; do
        file_count=$((file_count + 1))
        if ! file_bytes="$(LC_ALL=C stat -f '%z' "$file_path")"; then
            echo "error: could not stat release app file" >&2
            exit 1
        fi
        case "$file_bytes" in
            ''|*[!0-9]*)
                echo "error: stat returned a non-integer file size" >&2
                exit 1
                ;;
        esac
        if ! printf '%s\n' "$file_bytes" >>"$size_data"; then
            echo "error: could not record release app file size" >&2
            exit 1
        fi
    done
    exec 3<&-
    if [ "$file_count" -eq 0 ] || [ ! -s "$size_data" ]; then
        echo "error: release app contains no files to measure" >&2
        exit 1
    fi
    if ! app_bytes="$(awk '
        /^[0-9]+$/ { total += $1; count += 1; next }
        { exit 2 }
        END {
            if (count == 0) { exit 3 }
            printf "%.0f\n", total
        }
    ' "$size_data")"; then
        echo "error: could not sum release app file sizes" >&2
        exit 1
    fi
    case "$app_bytes" in
        ''|*[!0-9]*)
            echo "error: release app size total is not an integer" >&2
            exit 1
            ;;
    esac
    if [ "$app_bytes" -ge "$maximum_bytes" ]; then
        echo "error: uncompressed app size must be below 10 MB; found $app_bytes bytes" >&2
        exit 1
    fi
    cleanup_size_work_directory
    trap - 0 1 2 15
    echo "Release verification: arm64 only; system dylibs only; $app_bytes bytes; signature valid"
fi

echo "Built $app_bundle"
