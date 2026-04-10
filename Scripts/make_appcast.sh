#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/release_config.sh"
ZIP=${1:?
"Usage: $0 CodexBar-<ver>.zip"}
FEED_URL=${2:-"$CODEXBAR_APPCAST_URL"}
PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}
if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to your ed25519 private key PEM file." >&2
  exit 1
fi
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "Private key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "Zip not found: $ZIP" >&2
  exit 1
fi

ZIP_DIR=$(cd "$(dirname "$ZIP")" && pwd)
ZIP_NAME=$(basename "$ZIP")
ZIP_BASE="${ZIP_NAME%.zip}"
VERSION=${SPARKLE_RELEASE_VERSION:-}
if [[ -z "$VERSION" ]]; then
  if [[ "$ZIP_NAME" =~ ^CodexBar-(.+)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "Could not infer version from $ZIP_NAME; set SPARKLE_RELEASE_VERSION." >&2
    exit 1
  fi
fi

NOTES_HTML="${ZIP_DIR}/${ZIP_BASE}.html"
KEEP_NOTES=${KEEP_SPARKLE_NOTES:-0}
if [[ -x "$ROOT/Scripts/changelog-to-html.sh" ]]; then
  "$ROOT/Scripts/changelog-to-html.sh" "$VERSION" >"$NOTES_HTML"
else
  echo "Missing Scripts/changelog-to-html.sh; cannot generate HTML release notes." >&2
  exit 1
fi
cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ "$KEEP_NOTES" != "1" ]]; then
    rm -f "$NOTES_HTML"
  fi
}
trap cleanup EXIT

DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-"${CODEXBAR_RELEASES_URL}/download/v${VERSION}/"}
WORK_DIR=$(mktemp -d /tmp/codexbar-appcast.XXXXXX)

ZIP_SIZE=$(stat -f%z "$ZIP")
DOWNLOAD_URL="${DOWNLOAD_URL_PREFIX}${ZIP_NAME}"
PUB_DATE=$(date -R)
SIGNATURE_BIN="$WORK_DIR/${ZIP_BASE}.sig"
if python3 - "$PRIVATE_KEY_FILE" "$ZIP" "$SIGNATURE_BIN" <<'PY' 2>/dev/null
import sys

try:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
except ModuleNotFoundError:
    raise SystemExit(1)

private_key_path, zip_path, signature_path = sys.argv[1:]
with open(private_key_path, "rb") as fh:
    private_key = load_pem_private_key(fh.read(), password=None)
with open(zip_path, "rb") as fh:
    payload = fh.read()
signature = private_key.sign(payload)
with open(signature_path, "wb") as fh:
    fh.write(signature)
PY
then
  :
elif ! openssl pkeyutl -sign -inkey "$PRIVATE_KEY_FILE" -in "$ZIP" -out "$SIGNATURE_BIN" 2>/dev/null; then
  openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY_FILE" -in "$ZIP" -out "$SIGNATURE_BIN"
fi
ED_SIGNATURE=$(openssl base64 -A < "$SIGNATURE_BIN")

if [[ ! -f "$ROOT/appcast.xml" ]]; then
  cat <<EOF > "$ROOT/appcast.xml"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>CodexBar</title>
    </channel>
</rss>
EOF
fi

DESCRIPTION_HTML=$(cat "$NOTES_HTML")
python3 - "$ROOT/appcast.xml" "$BUILD_NUMBER" "$VERSION" "$PUB_DATE" "$FEED_URL" "$DOWNLOAD_URL" "$ZIP_SIZE" "$ED_SIGNATURE" "$DESCRIPTION_HTML" <<'PY'
import sys
from xml.dom import Node, minidom

appcast_path, build_number, version, pub_date, feed_url, download_url, zip_size, signature, description_html = sys.argv[1:]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

document = minidom.parse(appcast_path)
rss = document.documentElement
if rss.tagName != "rss":
    raise SystemExit("appcast.xml missing rss root element")
if not rss.hasAttribute("xmlns:sparkle"):
    rss.setAttribute("xmlns:sparkle", sparkle_ns)

channels = [node for node in rss.childNodes if node.nodeType == Node.ELEMENT_NODE and node.tagName == "channel"]
if not channels:
    raise SystemExit("appcast.xml missing channel element")
channel = channels[0]

for item in [node for node in channel.childNodes if node.nodeType == Node.ELEMENT_NODE and node.tagName == "item"]:
    versions = [
        child for child in item.childNodes
        if child.nodeType == Node.ELEMENT_NODE and child.tagName == "sparkle:version"
    ]
    if any((child.firstChild and child.firstChild.nodeValue == build_number) for child in versions):
        channel.removeChild(item)

item = document.createElement("item")

def append_text(parent, tag, value):
    element = document.createElement(tag)
    element.appendChild(document.createTextNode(value))
    parent.appendChild(element)
    return element

append_text(item, "title", version)
append_text(item, "pubDate", pub_date)
append_text(item, "link", feed_url)
append_text(item, "sparkle:version", build_number)
append_text(item, "sparkle:shortVersionString", version)
append_text(item, "sparkle:minimumSystemVersion", "14.0")

description = document.createElement("description")
description.appendChild(document.createCDATASection(description_html))
item.appendChild(description)

enclosure = document.createElement("enclosure")
enclosure.setAttribute("url", download_url)
enclosure.setAttribute("length", zip_size)
enclosure.setAttribute("type", "application/octet-stream")
enclosure.setAttribute("sparkle:edSignature", signature)
item.appendChild(enclosure)

title_node = next(
    (node for node in channel.childNodes if node.nodeType == Node.ELEMENT_NODE and node.tagName == "title"),
    None,
)
insert_before = title_node.nextSibling if title_node is not None else channel.firstChild
channel.insertBefore(item, insert_before)

pretty = document.toprettyxml(indent="    ", encoding="utf-8")
with open(appcast_path, "wb") as fh:
    fh.write(pretty)
PY

echo "Appcast generated (appcast.xml). Upload alongside $ZIP at $FEED_URL"
