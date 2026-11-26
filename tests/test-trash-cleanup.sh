#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper=$repository/assets/purge-old-trash.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/vps-manager-trash-test.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
trash=$test_root/home/.local/share/Trash
mkdir -p "$trash/files" "$trash/info"
printf keep > "$test_root/protected"
make_entry() {
 printf test > "$trash/files/$1"
 printf '[Trash Info]\nPath=/test/%s\nDeletionDate=%s\n' "$1" "$2" > "$trash/info/$1.trashinfo"
}
make_entry old 2000-01-01T00:00:00
make_entry recent 2099-01-01T00:00:00
make_entry invalid not-a-date
ln -s "$test_root/protected" "$trash/files/old-link"
printf '[Trash Info]\nDeletionDate=2000-01-01T00:00:00\n' > "$trash/info/old-link.trashinfo"
printf '[Trash Info]\nDeletionDate=2000-01-01T00:00:00\n' > "$trash/info/orphan.trashinfo"
preview=$(sh "$helper" --days 180 --dry-run --root "$trash")
printf '%s\n' "$preview" | grep -q 'matched=2'
[ -f "$trash/files/old" ] && [ -L "$trash/files/old-link" ]
sh "$helper" --days 180 --root "$trash" >/dev/null
[ ! -e "$trash/files/old" ] && [ ! -L "$trash/files/old-link" ]
[ "$(cat "$test_root/protected")" = keep ]
[ -f "$trash/files/recent" ] && [ -f "$trash/files/invalid" ]
[ ! -e "$trash/info/orphan.trashinfo" ]
if sh "$helper" --days 0 --dry-run >/dev/null 2>&1; then exit 1; fi
if sh "$helper" --root "$test_root" --dry-run >/dev/null 2>&1; then exit 1; fi
make_entry guarded 2000-01-01T00:00:00
ln -s "$test_root/home" "$test_root/linked-home"
sh "$helper" --root "$test_root/linked-home/.local/share/Trash" >/dev/null
[ -f "$trash/files/guarded" ]
printf 'Trash retention safety regression passed.\n'
