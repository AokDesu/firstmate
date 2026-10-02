import os, pathlib, subprocess, time, signal, json, shutil
root=pathlib.Path.cwd()
lab=root/'.test-tmp'/'live-worker'
evidence=pathlib.Path('/Users/kunchen/.no-mistakes/evidence/01M3YTSQWRN3AMJ7ZG7ERG1T76')
lab.mkdir(); (lab/'home').mkdir()
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k,None)
env.update(HOME=str(lab/'home'), FM_ROOT_OVERRIDE=str(root), FM_REMOTE_JOB_STATE_ROOT=str(lab/'state'))
lib='source bin/fm-remote-job-lib.sh; '
def api(expr):
    return subprocess.run(['/bin/bash','-c',lib+expr],env=env,capture_output=True,text=True)
r=api('fm_remote_job_prepare_state "$HOME"'); assert r.returncode==0, r.stderr
claims=lab/'state'/'.seq-claims'
for i in range(1,17401):
    p=claims/str(i); p.mkdir(); os.utime(p,(946684800,946684800))
log=open(evidence/'live-worker.log','w')
worker=subprocess.Popen([str(root/'bin/fm-remote-job-worker.sh')],env=env,stdout=log,stderr=log)
records=[]
start=time.monotonic()
try:
    ready=lab/'state'/'worker.ready'
    for _ in range(200):
        if ready.exists(): break
        assert worker.poll() is None
        time.sleep(.05)
    assert ready.exists()
    while True:
        elapsed=round(time.monotonic()-start,2)
        count=sum(1 for _ in claims.iterdir())
        probe=api('fm_remote_job_probe "$HOME"')
        owner=(lab/'state'/'worker.lock'/'pid').read_text().strip()
        entry=dict(phase='17400-claim-sweep',elapsed_seconds=elapsed,claims_remaining=count,worker_pid=worker.pid,lock_owner=owner,heartbeat_age_seconds=round(time.time()-ready.stat().st_mtime,2),probe_exit=probe.returncode)
        records.append(entry); print(json.dumps(entry),flush=True)
        assert worker.poll() is None and owner==str(worker.pid) and probe.returncode==0, entry
        if count==0: break
        assert elapsed<240, 'sweep exceeded observation bound'
        time.sleep(5)
    # A real stopped main process cannot refresh ready itself; heartbeat must do it.
    os.kill(worker.pid,signal.SIGSTOP)
    for _ in range(6):
        time.sleep(5)
        probe=api('fm_remote_job_probe "$HOME"')
        entry=dict(phase='main-loop-paused',worker_pid=worker.pid,heartbeat_age_seconds=round(time.time()-ready.stat().st_mtime,2),probe_exit=probe.returncode)
        records.append(entry); print(json.dumps(entry),flush=True)
        assert probe.returncode==0, entry
    os.kill(worker.pid,signal.SIGCONT)
finally:
    if worker.poll() is None:
        os.kill(worker.pid,signal.SIGCONT)
        worker.terminate()
        try: worker.wait(timeout=20)
        except subprocess.TimeoutExpired:
            api('fm_remote_job_stop_worker_tree '+str(worker.pid))
            worker.wait(timeout=20)
    log.close()
    (evidence/'live-worker-observations.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(lab)
