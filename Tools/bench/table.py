# table.py <data> <out dir> <meetings...>: the bench's table and averages (score.py per run)
import re, subprocess, sys, os
data, out, ms = sys.argv[1], sys.argv[2], sys.argv[3:]
here = os.path.dirname(os.path.abspath(__file__))
rows = []
for m in ms:
    off = open(f"{data}/{m}.off").read().split()[0]
    for v in ["", "-opus"]:
        r = subprocess.run(["python3", "-I", f"{here}/score.py", f"{data}/{m}.ref.json", f"{out}/{m}{v}.json", off], capture_output=True, text=True).stdout
        if not r: print(f"{m}{v}: no result"); continue
        wer = float(re.search(r"WER ([\d.]+)%", r)[1]); lab = [int(x) for x in re.findall(r"one-to-one (\d+)%", r)]
        t = float(re.search(r"processed in (\d+) s", r)[1])
        rows.append((wer, lab[0], lab[1], t)); print(f"{m:8} {v or 'plain':6} WER {wer:5.1f}%  voices live {lab[0]:3}%  after {lab[1]:3}%  {t:4.0f} s")
n = len(rows)
if n: print(f"\n{n} runs: WER {sum(r[0] for r in rows) / n:.1f}%, voices live {sum(r[1] for r in rows) / n:.1f}%, after {sum(r[2] for r in rows) / n:.1f}% (worst {min(r[2] for r in rows)}%), {sum(r[3] for r in rows) / n:.1f} s per 10 min")
