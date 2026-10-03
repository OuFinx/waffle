"""The results as a table: WER (%) of "Them" (sys) and "Me" (mic), and seconds until words show and become final (medians)."""
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
order = ["dialogue", "fast", "slow-pauses", "short-replies", "noisy", "phone", "echo", "echo-strong"]
rows.sort(key=lambda r: (order.index(r["scenario"]), r["lang"]))
def w(r, k):
    v = r.get(k)
    return "-" if v is None or isinstance(v, str) else f"{v * 100:.1f}"
print("| Language | Scenario | Each utterance alone (Them / Me) | Waffle now | Waffle 0.3 | Shows (now / 0.3) | Final (now / 0.3) |")
print("|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| {r['lang']} | {r['scenario']} | {w(r, 'offline_sys')} / {w(r, 'offline_mic')} | {w(r, 'new_sys')} / {w(r, 'new_mic')} | {w(r, 'old_sys')} / {w(r, 'old_mic')} "
          f"| {r.get('new_show_p50')} / {r.get('old_show_p50')} s | {r.get('new_final_p50')} / {r.get('old_final_p50')} s |")
