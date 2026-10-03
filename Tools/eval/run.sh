#!/bin/sh
# Runs every scenario (two at a time) and prints the table; results in $WAFFLE_EVAL/results.jsonl. Takes about an hour on 4 cores.
cd "$(dirname "$0")"
ROOT="${WAFFLE_EVAL:-/tmp/waffle-eval}"
: > "$ROOT/results.jsonl"
cat <<J | xargs -P 2 -L 1 sh -c 'THREADS=2 WAFFLE_EVAL='"$ROOT"' '"$ROOT"'/env/bin/python eval.py "$0" "$1" "$2" >> '"$ROOT"'/results.jsonl'
uk_ua dialogue offline,new,old,new-rms
en_us dialogue offline,new,old
ru_ru dialogue offline,new,old
pl_pl dialogue offline,new,old
de_de dialogue offline,new,old
uk_ua fast offline,new,old
en_us fast offline,new,old
ru_ru fast offline,new,old
pl_pl fast offline,new,old
de_de fast offline,new,old
uk_ua slow-pauses offline,new,old
en_us slow-pauses offline,new,old
ru_ru slow-pauses offline,new,old
pl_pl slow-pauses offline,new,old
de_de slow-pauses offline,new,old
uk_ua short-replies offline,new,old
en_us short-replies offline,new,old
ru_ru short-replies offline,new,old
pl_pl short-replies offline,new,old
de_de short-replies offline,new,old
uk_ua noisy offline,new,old,new-rms
en_us noisy offline,new,old
uk_ua phone offline,new,old
en_us phone offline,new,old
uk_ua echo offline,new,old
en_us echo offline,new,old
uk_ua echo-strong offline,new,old
en_us echo-strong offline,new,old
mixed dialogue offline,new,old
mixed fast offline,new,old
J
"$ROOT/env/bin/python" table.py "$ROOT/results.jsonl"
