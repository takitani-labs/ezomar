#!/usr/bin/env bash
set -euo pipefail

# A crash or accidental empty start can replace the only fleet index. Cheap
# hourly copies narrow that gap without stopping the server; backup-ai carries
# the snapshot directory together with the canonical file.

SOURCE="$HOME/.config/herdr/session.json"
DEST="$HOME/.config/herdr/session-snapshots"

say() { echo "[ezomar][herdr-snapshot] $*"; }

if [ ! -s "$SOURCE" ]; then
  say "session.json ausente ou vazio; nenhum snapshot criado."
  exit 0
fi

mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp "$DEST/.session.json.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp --reflink=auto "$SOURCE" "$TMP"
mv "$TMP" "$DEST/session.json.$STAMP"

# Seven days of hourly recovery points cover a bad snapshot noticed late while
# keeping this safety net small compared with the conversation archive.
find "$DEST" -maxdepth 1 -type f -name 'session.json.*' -mtime +7 -delete
say "Snapshot: $DEST/session.json.$STAMP"
