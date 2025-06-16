#!/bin/bash
set -euo pipefail
# Copyright (C) 2019 Checkmk GmbH - License: GNU General Public License v2
# This file is part of Checkmk (https://checkmk.com). It is subject to the terms and
# conditions defined in the file COPYING, which is part of this source code package.

# Automatically create hosts for Docker containers providing piggyback data.
# Execute this script as the site user from the site root directory.

# === Configuration ===
WATO_FOLDER="piggyback"
WATO_HOSTDIR="etc/check_mk/conf.d/wato/$WATO_FOLDER"
HOSTS_FILE="$WATO_HOSTDIR/hosts.mk"
CMK="bin/cmk"
PIGGYBACK_DIR="tmp/check_mk/piggyback"
LOCKFILE="/tmp/create_piggyback_hosts.lock"
LOGFILE="var/log/piggyback_host_creation.log"
CLEANUP_AGE_MINUTES=60

# === Logging ===
log() {
  echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE"
}

# === Prevent parallel execution ===
if [ -e "$LOCKFILE" ]; then
  log "🚫 Script läuft bereits – Abbruch."
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

touch "$LOCKFILE"

# === Preparation ===
mkdir -p "$WATO_HOSTDIR"
mkdir -p "$(dirname "$LOGFILE")"
: > "$HOSTS_FILE"

# create wato folder metadata if missing
if [ ! -e "$WATO_HOSTDIR/.wato" ]; then
  echo "{'attributes': {}, 'lock': False, 'num_hosts': 0, 'title': '$WATO_FOLDER'}" > "$WATO_HOSTDIR/.wato"
fi

# === Check piggyback source ===
if [ ! -d "$PIGGYBACK_DIR" ]; then
  log "❌ Piggyback-Verzeichnis fehlt: $PIGGYBACK_DIR"
  exit 1
fi

# === Counters ===
total=0
new=0
skipped=0

log "📦 Beginne Verarbeitung von Piggyback-Daten..."

# === Create hosts from piggyback directories ===
shopt -s nullglob
for docker_path in "$PIGGYBACK_DIR"/*/; do
  ((total++))
  docker_id=$(basename "$docker_path")
  parent_file=$(find "$docker_path" -maxdepth 1 -type f | head -n 1)

  if [[ -z "$parent_file" ]]; then
    log "⚠ Kein Parent für $docker_id gefunden – übersprungen"
    continue
  fi

  parent_host=$(basename "$parent_file")

  if grep -q "\"$docker_id\"" "$HOSTS_FILE" 2>/dev/null; then
    log "✔ Host $docker_id existiert bereits – übersprungen"
    ((skipped++))
    continue
  fi

  log "➕ Lege Host $docker_id mit Parent $parent_host an"
  echo "all_hosts += [\"$docker_id|no-agent|no-ip|/$WATO_FOLDER/\"]" >> "$HOSTS_FILE"
  echo "extra_host_conf.setdefault('parents', []).append((\"$parent_host\", [\"$docker_id\"]))" >> "$HOSTS_FILE"
  ((new++))
done
shopt -u nullglob

# === Apply configuration ===
log "🔄 Generiere Konfiguration (cmk -U)"
if ! $CMK -U >> "$LOGFILE" 2>&1; then
  log "❌ cmk -U fehlgeschlagen"
  exit 1
fi

log "🔧 Inventarisiere neue Hosts"
for docker_path in "$PIGGYBACK_DIR"/*/; do
  docker_id=$(basename "$docker_path")
  if $CMK -l | grep -q "^$docker_id$"; then
    log "   🔍 Inventory für $docker_id"
    $CMK -I "$docker_id"
  fi
done

log "✅ Aktiviere Konfiguration (cmk -R)"
$CMK -R

# === Cleanup ===
log "🧹 Entferne veraltete Piggyback-Ordner (> $CLEANUP_AGE_MINUTES Minuten)"
find "$PIGGYBACK_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +$CLEANUP_AGE_MINUTES -exec rm -rf {} \; >> "$LOGFILE" 2>&1

log "🏁 Fertig: $new neu | $skipped übersprungen | Gesamt: $total"

exit 0
