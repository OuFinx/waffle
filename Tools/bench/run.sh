#!/bin/sh
# Meeting bench: real meetings (ICSI, AMI: 3 to 9 people, with human transcripts) through the app's code, plain and after an Opus 24 kbit/s
# round trip like a call. Prints per meeting the word error rate and the share of lines with the right voice (live / after the call), then
# the averages. `./run.sh [quick|full] [tag] [terms dir]` (the terms dir holds <meeting>.txt, one vocabulary term per line); data in $WAFFLE_BENCH (made by fetch.sh). One run at a time on this Mac (a lock), so timings
# stay honest when several checkouts measure at once.
set -e
cd "$(dirname "$0")"
DATA="${WAFFLE_BENCH:?set WAFFLE_BENCH to the data dir (fetch.sh)}"
SET="${1:-quick}"; TAG="${2:-run}"; TERMS="$3"
if [ "$SET" = full ]; then M="Bmr009 Bro018 Bed008 Bmr006 Bmr013 ES2004a Bmr001 Bed012 Bro027 IS1009a Bed002 Bmr016 Bns001 Bmr007 Bmr019 Bmr024"
else M="Bmr009 Bmr013 Bmr001 IS1009a Bmr007 Bmr019"; fi
swift build -c release 2>&1 | grep -E "error:" && exit 1
OUT="$DATA/out/$TAG"; mkdir -p "$OUT"
LOCK=/tmp/waffle-bench.lock
until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
trap 'rmdir "$LOCK"' EXIT
for m in $M; do for v in "" -opus; do .build/release/Bench "$DATA/$m$v.wav" "$OUT/$m$v.json" ${TERMS:+"$TERMS/$m.txt"} >/dev/null 2>&1; done; done
rmdir "$LOCK"; trap - EXIT
python3 -I table.py "$DATA" "$OUT" $M
