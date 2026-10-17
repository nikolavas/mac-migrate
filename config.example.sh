# shellcheck disable=SC2034  # read by backup.sh, make-setup.sh and cleanup.sh
# Copy to ~/.mac-migration/config.sh (or config.sh next to the scripts) and change what you need.
# Paths are relative to your home folder unless they start with /.

# Where the backup goes. A cloud folder (Google Drive, iCloud Drive, OneDrive, Dropbox) or a disk:
# each archive is written there, and for cloud folders freed on this Mac once it has uploaded.
# Leave it empty to write to OUT and copy the archives yourself. The app and --to override it.
DEST=""
OUT="$HOME/mac-migration-archives"

# Archive size in GB of source data, and how much disk space to keep free while packing.
MAX_BATCH_GB=8
FREE_MARGIN_GB=5

# Split archives into parts of this many MB. Empty means automatic: 3900 on FAT32 disks and Box,
# which don't take files over 4 or 5 GB, and no splitting elsewhere.
PART_MB=""

# Read every archive back right after packing it. Costs time, catches a bad disk before you rely on it.
VERIFY_ARCHIVES=1

# Add settings files or folders on top of the defaults.
SETTINGS_ITEMS+=(.config/gh .gitmessage .ideavimrc)

# Personal folders. Desktop and Documents are skipped automatically when iCloud syncs them.
PERSONAL_ITEMS=(Documents Desktop Pictures)

# Folders whose subfolders are your projects. Each subfolder goes whole into one archive.
PROJECT_ROOTS=(proj code Developer work)

# Folder and file names left out of projects and personal folders, because they are rebuilt or recreated.
EXCLUDE_NAMES+=(.gradle target dist .turbo .cache)

# Apps your company installs for you. They stay out of the software package's Brewfile
# and are listed under "From your company's self-service portal" instead.
SETUP_SKIP_APPS=("Okta Verify" "Microsoft Word" "Microsoft Excel" "Microsoft Outlook" "Microsoft Teams" "Privileges")

# Free up space: cache folders cleanup.sh never touches, relative to your home folder.
CLEANUP_KEEP=()
