import subprocess, pathlib, os, time, signal, hashlib, json
root=pathlib.Path.cwd(); work=root/'.test-tmp/delta-proof'; results=[]
run=work/'retry'; run.mkdir(exist_ok=True)
for variant,script in [('main',work/'baseline.sh'),('candidate',root/'bin/fm-remote-delta-read.sh')]:
 for scope in ['pid','group']:
  for sig in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT,signal.SIGQUIT]:
   case=run/f'{variant}-{scope}-{sig.name}'; (case/'home/state').mkdir(parents=True); (case/'tmp').mkdir(); (case/'bin').mkdir()
   log=case/'home/state/replies.status'; log.write_bytes(b'')
   shim=case/'bin/sleep'; shim.write_text('#!/bin/bash\nprintf "%s %s\\n" "$$" "$1" > "$READY"\nexec /bin/sleep "$@"\n'); shim.chmod(0o755)
   env=dict(os.environ,FM_HOME=str(case/'home'),TMPDIR=str(case/'tmp'),READY=str(case/'ready'),PATH=str(case/'bin')+':/bin:/usr/bin:'+os.environ['PATH'])
   env.pop('FM_REMOTE_DELTA_POLL_SECONDS',None)
   p=subprocess.Popen(['/bin/bash',str(script),'state/replies.status','0',hashlib.sha256(b'').hexdigest(),'30'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
   end=time.monotonic()+10
   while not (case/'ready').exists() and time.monotonic()<end: time.sleep(.01)
   assert (case/'ready').exists(), 'reader never entered external sleep'
   child,cadence=(case/'ready').read_text().split(); started=time.monotonic()
   (os.kill if scope=='pid' else os.killpg)(p.pid,sig)
   survived=False
   try: out,err=p.communicate(timeout=2)
   except subprocess.TimeoutExpired:
    survived=True
    os.killpg(p.pid,signal.SIGTERM)
    out,err=p.communicate(timeout=5)
   dirs=[x.name for x in (case/'tmp').iterdir()]
   results.append(dict(variant=variant,scope=scope,signal=sig.name,cadence=cadence,survived_initial_signal=survived,exit=p.returncode,stop_ms=round((time.monotonic()-started)*1000),remaining_delta_dirs=len(dirs),stdout=out.decode(),stderr=err.decode()))
   try: os.kill(int(child),signal.SIGTERM)
   except ProcessLookupError: pass
for a,b in zip(results[:8],results[8:]):
 assert (a['survived_initial_signal'],a['exit'],a['remaining_delta_dirs'])==(b['survived_initial_signal'],b['exit'],b['remaining_delta_dirs']), (a,b)
print(json.dumps({'platform':'macOS native Bash 3.2','signal_outcomes_match':True,'results':results},indent=2))
