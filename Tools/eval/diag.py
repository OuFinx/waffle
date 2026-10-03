"""Shows where the live transcript differs from recognizing each utterance on its own: python diag.py uk_ua dialogue 6"""
import eval as E, numpy as np, difflib, sys
lang, sc, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rng=np.random.default_rng(1); utts=E.load(lang)[:n]
mic,sys_,placed=E.build(E.SCENARIOS[sc],utts,rng)
for s,st,u in placed: print('utt', s, round(st/16000,1), round((st+len(u['audio']))/16000,1), 'rms', round(E.rms(u['audio'][abs(u['audio'])>1e-4]),4))
for src in ['sys','mic']:
    off=' '.join(u['text'] for s,_,u in placed if s==src)
    if not off: continue
    lines,ev,c,n_=E.run(f'{E.ROOT}/bridge',mic,sys_,echo_gate=sc.startswith('echo')) if src=='sys' else (lines,ev,c,n_)
    hyp=' '.join(l['text'] for l in sorted(lines,key=lambda l:l['t']) if l['src']==src)
    a=E.norm(off).split(); b=E.norm(hyp).split()
    print(src, 'wer off->live', round(E.wer(off,hyp),3))
    for op in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes():
        if op[0]!='equal': print('  ', op[0], a[op[1]:op[2]], '->', b[op[3]:op[4]])
for l in sorted(lines,key=lambda l:l['t']): print(' ', l['src'], l['t'], l['text'])
