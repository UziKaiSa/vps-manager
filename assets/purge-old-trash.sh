#!/bin/sh
# FreeDesktop Trash retention; supports GNU tools and Alpine BusyBox without Python.
set -eu
days=180
dry_run=0
single_root=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) [ "$#" -ge 2 ] || exit 2; days=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --root) [ "$#" -ge 2 ] || exit 2; single_root=$2; shift 2 ;;
    *) echo "Usage: $0 [--days 180] [--dry-run] [--root /home/user/.local/share/Trash]" >&2; exit 2 ;;
  esac
done
case "$days" in ''|*[!0-9]*|0*) echo 'Retention must be 1..36500 whole days.' >&2; exit 2;; esac
[ "$days" -le 36500 ] || exit 2
cutoff=$(($(date +%s) - days * 86400))
removed=0
retained=0
invalid=0
locked=0
lock_dir=/run/vps-manager-trash-cleanup.lock
if [ "$dry_run" = 0 ] && [ -z "$single_root" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock_dir}.flock"
    flock -n 9 || { echo 'Cleanup already running; skipped.'; exit 0; }
  else
    if ! mkdir "$lock_dir" 2>/dev/null; then
      old_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
      case "$old_pid" in ''|*[!0-9]*) echo 'Invalid cleanup lock; skipped.'; exit 0;; esac
      if kill -0 "$old_pid" 2>/dev/null; then echo 'Cleanup already running; skipped.'; exit 0; fi
      rm -f -- "$lock_dir/pid"; rmdir "$lock_dir"; mkdir "$lock_dir"
    fi
    printf '%s\n' "$$" > "$lock_dir/pid"
    locked=1
    trap '[ "$locked" = 0 ] || { rm -f -- "$lock_dir/pid"; rmdir "$lock_dir"; } 2>/dev/null || true' EXIT HUP INT TERM
  fi
fi
entry_time() {
  entry=$1
  metadata=$2
  timestamp=
  if [ -f "$metadata" ] && [ ! -L "$metadata" ]; then
    deleted=$(sed -n 's/^DeletionDate=//p' "$metadata" | head -n 1 | tr 'T' ' ')
    if [ -n "$deleted" ]; then timestamp=$(date -d "$deleted" +%s 2>/dev/null || true); fi
  fi
  if [ -z "$timestamp" ]; then
    modified=$(stat -c %Y "$entry" 2>/dev/null || echo 0)
    changed=$(stat -c %Z "$entry" 2>/dev/null || echo 0)
    if [ "$modified" -gt "$changed" ]; then timestamp=$modified; else timestamp=$changed; fi
  fi
  printf '%s\n' "$timestamp"
}
has_mount() {
  [ -r /proc/self/mountinfo ] || return 1
  awk -v root="$1" '{p=$5;gsub(/\\040/," ",p);if(p==root || index(p,root"/")==1)found=1} END{exit !found}' /proc/self/mountinfo
}
purge_root() {
  trash_root=${1%/}
  case "$trash_root" in /*/.local/share/Trash) ;; *) echo "Refusing non-Trash root: $trash_root" >&2; return 2;; esac
  [ -d "$trash_root" ] || return 0
  if [ -L "$trash_root" ] || [ "$(readlink -f "$trash_root")" != "$trash_root" ]; then
    echo "Skipping symlinked Trash root: $trash_root"; invalid=$((invalid+1)); return 0
  fi
  files_dir=$trash_root/files
  info_dir=$trash_root/info
  [ -d "$files_dir" ] && [ -d "$info_dir" ] || return 0
  if [ -L "$files_dir" ] || [ -L "$info_dir" ]; then invalid=$((invalid+1)); return 0; fi
  for candidate in "$files_dir"/* "$files_dir"/.[!.]* "$files_dir"/..?*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    info_path=$info_dir/${candidate##*/}.trashinfo
    at=$(entry_time "$candidate" "$info_path")
    case "$at" in ''|*[!0-9]*) invalid=$((invalid+1)); continue;; esac
    if [ "$at" -eq 0 ] || [ "$at" -ge "$cutoff" ]; then retained=$((retained+1)); continue; fi
    if has_mount "$candidate"; then echo "Skipping mounted entry: $candidate"; invalid=$((invalid+1)); continue; fi
    if [ "$dry_run" = 1 ]; then
      printf 'would_remove: %s\n' "$candidate"
    else
      # Unlink final symlinks, never traverse them. Child mounts were rejected above.
      if [ -L "$candidate" ]; then rm -f -- "$candidate"; else rm -rf -- "$candidate"; fi
      [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
      if [ -f "$info_path" ] && [ ! -L "$info_path" ]; then rm -f -- "$info_path"; fi
      printf 'removed: %s\n' "$candidate"
    fi
    removed=$((removed+1))
  done
  for info_path in "$info_dir"/*.trashinfo; do
    [ -f "$info_path" ] && [ ! -L "$info_path" ] || continue
    name=${info_path##*/}; name=${name%.trashinfo}
    [ ! -e "$files_dir/$name" ] && [ ! -L "$files_dir/$name" ] || continue
    deleted=$(sed -n 's/^DeletionDate=//p' "$info_path" | head -n 1 | tr 'T' ' ')
    [ -n "$deleted" ] || continue
    at=$(date -d "$deleted" +%s 2>/dev/null || true)
    case "$at" in ''|*[!0-9]*) continue;; esac
    [ "$at" -lt "$cutoff" ] || continue
    if [ "$dry_run" = 0 ]; then rm -f -- "$info_path"; fi
  done
}
if [ -n "$single_root" ]; then
  purge_root "$single_root"
else
  for user_home in /root /home/*; do
    [ -d "$user_home" ] && [ ! -L "$user_home" ] || continue
    purge_root "$user_home/.local/share/Trash"
  done
fi
printf 'summary: days=%s dry_run=%s matched=%s retained=%s invalid=%s\n' "$days" "$dry_run" "$removed" "$retained" "$invalid"
