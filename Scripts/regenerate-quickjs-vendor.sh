#!/bin/sh
# Reproducibly stages the minimal embeddable quickjs-ng engine in Sources/CQuickJS.
set -eu

QUICKJS_VERSION="0.15.1"
QUICKJS_TAG="v${QUICKJS_VERSION}"
EXPECTED_SHA256="c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623"
ARCHIVE_URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/${QUICKJS_TAG}.tar.gz"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR="${ROOT_DIR}/Sources/CQuickJS"
MODE=${1:-check}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-quickjs-regen.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
ARCHIVE_FILE="${WORK_DIR}/quickjs.tar.gz"
SOURCE_DIR="${WORK_DIR}/quickjs-${QUICKJS_VERSION}"
STAGE_DIR="${WORK_DIR}/stage"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

curl -fsSL "$ARCHIVE_URL" -o "$ARCHIVE_FILE"
ACTUAL_SHA256=$(sha256_file "$ARCHIVE_FILE")
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "error: quickjs-ng archive hash ${ACTUAL_SHA256} does not match ${EXPECTED_SHA256}" >&2
    exit 1
fi

tar -xzf "$ARCHIVE_FILE" -C "$WORK_DIR"
mkdir -p "$STAGE_DIR/include"

for source in quickjs.c dtoa.c libregexp.c libunicode.c; do
    cp "${SOURCE_DIR}/${source}" "$STAGE_DIR/$source"
done

for header in \
    builtin-array-fromasync.h \
    builtin-iterator-zip-keyed.h \
    builtin-iterator-zip.h \
    cutils.h \
    dtoa.h \
    libregexp-opcode.h \
    libregexp.h \
    libunicode-table.h \
    libunicode.h \
    list.h \
    quickjs-atom.h \
    quickjs-c-atomics.h \
    quickjs-opcode.h \
    quickjs.h
do
    cp "${SOURCE_DIR}/${header}" "$STAGE_DIR/include/$header"
done

cp "${SOURCE_DIR}/LICENSE" "$STAGE_DIR/LICENSE"

case "$MODE" in
    check | --check)
        for file in quickjs.c dtoa.c libregexp.c libunicode.c LICENSE; do
            cmp "${STAGE_DIR}/${file}" "${TARGET_DIR}/${file}"
        done
        for file in "$STAGE_DIR"/include/*.h; do
            cmp "$file" "${TARGET_DIR}/include/$(basename "$file")"
        done
        echo "ok: vendored quickjs-ng ${QUICKJS_TAG} matches ${EXPECTED_SHA256}"
        ;;
    write | --write)
        rm -f \
            "${TARGET_DIR}/quickjs.c" \
            "${TARGET_DIR}/dtoa.c" \
            "${TARGET_DIR}/libregexp.c" \
            "${TARGET_DIR}/libunicode.c" \
            "${TARGET_DIR}/LICENSE"
        mkdir -p "${TARGET_DIR}/include"
        cp "$STAGE_DIR"/*.c "$TARGET_DIR/"
        cp "$STAGE_DIR"/LICENSE "$TARGET_DIR/"
        cp "$STAGE_DIR"/include/*.h "$TARGET_DIR/include/"
        echo "wrote ${TARGET_DIR} from quickjs-ng ${QUICKJS_TAG} (${EXPECTED_SHA256})"
        ;;
    *)
        echo "Usage: $0 [check|write]" >&2
        exit 2
        ;;
esac
