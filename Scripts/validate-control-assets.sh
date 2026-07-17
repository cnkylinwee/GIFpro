#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 RESOURCE_DIRECTORY" >&2
    exit 2
fi

resource_directory="$1"
if [ ! -d "$resource_directory" ]; then
    echo "error: control asset resource directory not found: $resource_directory" >&2
    exit 1
fi

decode_directory="$(mktemp -d /tmp/gifpro-control-asset-validation.XXXXXX)"
cleanup() {
    rm -rf "$decode_directory"
}
trap cleanup 0
trap 'exit 1' 1 2 15

for asset_name in RecordButton.png StopButton.png; do
    asset_path="$resource_directory/$asset_name"
    if [ ! -f "$asset_path" ]; then
        echo "error: missing control asset: $asset_name" >&2
        exit 1
    fi

    asset_format="$(/usr/bin/sips --getProperty format "$asset_path" 2>/dev/null | awk '
        $1 == "format:" { print $2 }
    ')"
    if [ "$asset_format" != "png" ] ||
        ! /usr/bin/sips --setProperty format png "$asset_path" \
            --out "$decode_directory/$asset_name" >/dev/null 2>&1 ||
        [ ! -f "$decode_directory/$asset_name" ]; then
        echo "error: invalid PNG control asset: $asset_name" >&2
        exit 1
    fi
done
