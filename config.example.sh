# Copy to config.sh and change what you need. backup.sh reads it at start.
# Paths are relative to your home folder unless they start with /.

# Where the archives go. A folder on an encrypted external disk works too.
OUT="$HOME/mac-migration-archives"

# Archive size in GB of source data, and how much disk space to keep free while packing.
MAX_BATCH_GB=8
FREE_MARGIN_GB=5

# Add settings files or folders on top of the defaults.
SETTINGS_ITEMS+=(.config/gh .gitmessage .ideavimrc)

# Personal folders. Desktop and Documents are skipped automatically when iCloud syncs them.
PERSONAL_ITEMS=(Documents Desktop Pictures)

# Folders whose subfolders are your projects. Each subfolder goes whole into one archive.
PROJECT_ROOTS=(proj code Developer work)

# Folder and file names left out everywhere, because they are rebuilt or recreated.
EXCLUDE_NAMES+=(.gradle target dist .turbo .cache)
