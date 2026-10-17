#!/bin/bash
# Where a backup can go: cloud folders, external disks, a folder on this Mac. Sourced by backup.sh.

# Volume properties from diskutil, one per line as key=value
volume_info() {
  diskutil info -plist "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | /usr/bin/perl -MJSON::PP -0777 -ne '
    my $j = eval { decode_json($_) } or exit 1;
    for (qw(MountPoint Internal BusProtocol FilesystemType WritableVolume Encryption FileVault VolumeName)) {
      my $v = $j->{$_}; $v = ref $v ? ($v ? "true" : "false") : ($v // "");
      print "$_=$v\n";
    }'
}
vinfo() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# Topmost folder on the same volume as a path
mount_point() {
  local d="$1" dev parent
  dev=$(stat -f %d "$d") || return 1
  while parent=$(dirname "$d"); [ "$parent" != "$d" ] && [ "$(stat -f %d "$parent")" = "$dev" ]; do d="$parent"; done
  echo "$d"
}

# Largest archive part a destination accepts, in MB. Empty means no limit.
part_limit_mb() {
  local p="$1" info
  case "$p/" in "$HOME/Library/CloudStorage/Box"*) echo 3900; return ;; esac  # Box Business: 5 GB per file
  in_cloud_folder "$p" && return
  info=$(volume_info "$(mount_point "$p")")
  [ "$(vinfo "$info" FilesystemType)" = msdos ] && echo 3900  # FAT32: 4 GiB per file
}

# Lists destinations as TSV: id kind label path free_kb fs part_mb note
list_places() {
  local d name email info fs note mp label
  for d in "$HOME"/Library/CloudStorage/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
      GoogleDrive-*)
        email=${name#GoogleDrive-}
        # The account folder itself is read-only. Shared drives are left out on purpose: the whole team sees them.
        [ -d "$d/My Drive" ] && place_row "gdrive:$email" cloud "Google Drive ($email)" "$d/My Drive" cloud "" "" ;;
      OneDrive-*) place_row "onedrive:${name#OneDrive-}" cloud "OneDrive (${name#OneDrive-})" "$d" cloud "" "" ;;
      Dropbox*) place_row "dropbox" cloud "Dropbox" "$d" cloud "" "" ;;
      Box*) place_row "box" cloud "Box" "$d" cloud 3900 "Archives are split into 3.9 GB parts: Box allows 5 GB per file." ;;
      *) place_row "cloud:$name" cloud "$name" "$d" cloud "" "" ;;
    esac
  done
  d="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
  if [ -d "$d" ] && grep -q MOBILE_DOCUMENTS "$HOME/Library/Preferences/MobileMeAccounts.plist" 2>/dev/null; then
    note="Uses your Apple account. Check your company's policy before you put work files there."
    [ "$(defaults read com.apple.bird optimize-storage 2>/dev/null)" = 1 ] ||
      note="$note Optimize Mac Storage is off, so uploaded archives stay on this Mac and need free space."
    place_row icloud cloud "iCloud Drive" "$d" cloud "" "$note"
  fi
  for d in "${MIG_VOLUMES:-/Volumes}"/*; do
    [ -d "$d" ] || continue
    info=$(volume_info "$d") || continue
    mp=$(vinfo "$info" MountPoint)
    [ -n "$mp" ] && [ "$mp" != / ] || continue
    [ "$(vinfo "$info" WritableVolume)" = true ] || continue
    [ "$(vinfo "$info" BusProtocol)" = "Disk Image" ] && [ -z "$MIG_ALLOW_DISK_IMAGES" ] && continue
    fs=$(vinfo "$info" FilesystemType)
    # shellcheck disable=SC1111  # curly quotes are for display
    label="Disk “$(basename "$d")”"
    note=""
    case "$fs" in
      msdos) place_row "disk:$(basename "$d")" disk "$label" "$d" "$fs" 3900 "FAT32 disk: archives are split into 3.9 GB parts. exFAT or APFS avoids that." ;;
      apfs | hfs)
        [ "$(vinfo "$info" Encryption)" = true ] || [ "$(vinfo "$info" FileVault)" = true ] ||
          note="This disk isn't encrypted. The archives are, but anything else on it isn't."
        place_row "disk:$(basename "$d")" disk "$label" "$d" "$fs" "" "$note" ;;
      *) place_row "disk:$(basename "$d")" disk "$label" "$d" "$fs" "" "" ;;
    esac
  done
  place_row local local "A folder on this Mac (copy it yourself)" "$HOME/mac-migration-archives" apfs "" \
    "Copy the folder to a cloud drive or disk when the backup is done."
}

place_row() {  # id kind label path fs part_mb note
  local free
  free=$(free_kb "$4"); [ -n "$free" ] || free=$(free_kb "$(dirname "$4")")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${free:-0}" "$5" "$6" "$7"
}

# A short, safe name for this Mac, used in backup folder names
host_slug() {
  (scutil --get ComputerName 2>/dev/null || hostname -s) | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

# The backup folder inside a destination: the destination itself when it already is one,
# the newest unfinished backup of this Mac there, or a new mac-migration-<mac>-<date> folder.
# With "existing", the newest backup of this Mac, finished or not (for --add and --status).
backup_dir_in() {  # place [existing]
  local place="$1" d best="" new
  if [ -f "$place/plan.txt" ] || [ -f "$place/MANIFEST.txt" ]; then echo "$place"; return; fi
  for d in "$place/mac-migration-$(host_slug)-"*; do
    [ -f "$d/MANIFEST.txt" ] || [ -f "$d/plan.txt" ] || continue
    if [ "$2" = existing ] || [ "$(manifest_field "$d/MANIFEST.txt" complete 2>/dev/null)" != yes ]; then best="$d"; fi
  done
  if [ -n "$best" ] || [ "$2" = existing ]; then echo "$best"; return; fi
  new="$place/mac-migration-$(host_slug)-$(date +%Y%m%d)"
  while [ -e "$new" ]; do new="$new-2"; done
  echo "$new"
}
