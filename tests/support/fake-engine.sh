#!/bin/bash
# Stands in for backup.sh in the app's self-test. It follows the same contract: a status snapshot
# and events.tsv in MIG_RUN, the result in the EXIT trap, the password on stdin, exit codes.
pw=""
for a in "$@"; do [ "$a" = --password-stdin ] && IFS= read -r pw; done
reason=""
on_exit() { local code=$?; printf 'result\t%s\t%s\n' "$code" "$reason" >> "$MIG_RUN/events.tsv"; }
trap on_exit EXIT
trap 'exit 143' TERM
status() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" > "$MIG_RUN/status.tmp" && mv -f "$MIG_RUN/status.tmp" "$MIG_RUN/status"; }

case "${FAKE_SCENARIO:-ok}" in
  ok)
    if [ "$pw" != secret ]; then reason="Wrong password."; exit 10; fi
    echo "password ok"
    for i in 1 2 3; do status pack "projects-0$i" $((i * 100)) 300 1024 10 ""; sleep 0.2; done
    printf 'done\t3 files\n' >> "$MIG_RUN/events.tsv"
    exit 0 ;;
  slow)
    # a TERM to the group can end sleep before bash runs its trap: pass on what killed it
    sleep 30 &
    wait $!
    exit $? ;;
  list)
    printf 'gdrive:a@b\tcloud\tGoogle Drive (a@b)\t/x/My Drive\t1000\tcloud\t\t\n'
    exit 0 ;;
esac
