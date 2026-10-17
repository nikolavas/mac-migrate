# Spikes

Checks made before building the connectors and the app, on macOS 26.5.1 (Apple silicon) with Google Drive for desktop in stream mode and Jamf Protect running. Re-run them when something here stops matching what you see.

## S1: Google Drive space

| Check | Result |
|---|---|
| Upload state of a file in `My Drive` (`lib/cloud.js status`) | Works. A 2 MB file showed uploaded after 19 s, a 20 MB file after 9 s. |
| `evictUbiquitousItemAtURL` on an uploaded file | Works. The file turns `compressed,dataless` with 0 blocks on disk and stays uploaded. |
| Evicting a file that hasn't uploaded yet | Fails with "The file couldn't be saved". The file stays local. |
| `startDownloadingUbiquitousItemAtURL` | Works. The file was local again 2 s later. |
| Plain read of an evicted file | Works. `shasum` downloaded it transparently (1 s for 2 MB). |
| `mv` from a folder in the home folder into `My Drive` | A rename on the same volume (same inode, 17 ms), uploaded like any new file. |
| `root_preference_sqlite.db` → `roots` | Empty in stream mode. Mirror mode not tested. |

Consequences for the connector:

- Build each archive in local staging, `mv` it into the Drive folder, wait until it's uploaded, then evict it. That frees the space for the next archive.
- If the file is still on disk after an evict (mirror mode, iCloud without Optimize Mac Storage, a provider that refuses), stop and ask for an external disk or more free space instead of waiting forever.
- In JXA, error out-parameters must be `$()`, not `Ref()`: with `Ref()` osascript crashes (exit 139) when the call fails.

Not tested: how fast macOS evicts uploaded files by itself under disk pressure, Drive paused or offline (`NSURLUbiquitousItemUploadingErrorKey`), and mirror mode.

## S2: Applet run loop

A JXA applet built with `osacompile`:

- is ad-hoc signed (`flags=0x2(adhoc)`) and has no quarantine flag, so it opens without a Gatekeeper prompt
- starts the engine with `NSTask` through `perl -e 'setpgrp(0,0); exec @ARGV'`, so the engine leads its own process group (pgid = pid)
- passes the password on stdin (`NSPipe`, written once and closed)
- polls a status file with `delay(0.5)` while updating `Progress`
- stops the whole job with `kill -TERM -<pgid>`: bash, a background `sleep` and the foreground child all exit (3 processes before, 0 after), and `terminationStatus` is 15

An app opened from Terminal inherits Terminal's PATH. From Finder it gets launchd's short PATH, so the engine sets its own.

## S3: Screens

`NSAlert` with an `NSStackView` accessory view works in an applet:

- Radio buttons group only when they share a target and action. Give every control an action on a class registered with `ObjC.registerSubclass`.
- Actions fire during `runModal` and can update labels live (for the size total of a checklist).
- `NSSecureTextField` works for passwords.
- `state` comes back as a string in JXA. Compare with `Number(button.state) === 1`.
- Block-based `NSTimer` doesn't fire in a modal loop. Use target/selector, added for `NSModalPanelRunLoopMode`.

## S4: Privacy prompts and security software

- Jamf Protect runs on this Mac and didn't block any of the ad-hoc spike applets.
- When the app starts the engine, macOS attributes Desktop, Documents and Downloads access to the app ("Mac Migrate"), the responsible process. Rebuilding the app changes its signature, so build it once per version.
- Still to check by hand on a company Mac: a Santa-style allowlist, which would block the app. The Terminal path keeps working there.
