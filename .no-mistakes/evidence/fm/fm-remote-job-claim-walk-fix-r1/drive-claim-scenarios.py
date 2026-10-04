import os, pathlib, subprocess, tempfile, time, json, shutil
root = pathlib.Path.cwd()
fixture = pathlib.Path(tempfile.mkdtemp(prefix='claim-live-', dir=root / '.test-phase-tmp'))
try:
    account = fixture / 'account'
    account.mkdir()
    state = fixture / 'state'
    env = dict(os.environ, FM_REMOTE_JOB_STATE_ROOT=str(state))
    def call(code):
        return subprocess.run(['bash', '-c', '. "$1/bin/fm-remote-job-lib.sh"; '+code, '_', str(root), str(account)], env=env, text=True, capture_output=True, check=True)
    call('fm_remote_job_prepare_state "$2"')
    claims = state / '.seq-claims'
    now = int(time.time())
    for i in range(1,17461):
        p = claims / str(i)
        p.mkdir()
        if i <= 8730: os.utime(p, (now-90000, now-90000))
    began=time.monotonic()
    call('fm_remote_job_reap_stale "$2"')
    duration=time.monotonic()-began
    remaining=len(list(claims.iterdir()))
    print(json.dumps(dict(scenario='17460-claim sweep', elapsed_seconds=round(duration,3), expired_removed=17460-remaining, fresh_remaining=remaining)), flush=True)
    assert remaining == 8730
    assert duration < 15
    # Expired data added after a sweep must wait until the hourly marker is due.
    probe = claims / '17461'; probe.mkdir(); os.utime(probe,(now-90000,now-90000))
    marker = state / '.seq-claims-reaped'
    before=marker.stat().st_mtime_ns
    call('fm_remote_job_reap_stale "$2"')
    assert probe.exists() and marker.stat().st_mtime_ns == before
    print(json.dumps(dict(scenario='hourly throttle', expired_added_after_sweep='preserved', marker='unchanged')), flush=True)
    # Pin the clock only for an exact one-second retention boundary.
    for name,age in [('20001',86400),('20002',86399),('20003',86401),('0',90000),('notes',90000),('1x',90000),('.private',90000),('00',90000),('01',90000),('20004',90000)]:
        p=claims/name; p.mkdir()
        if name=='20004': (p/'payload').write_text('must survive')
        os.utime(p,(now-age,now-age))
    target=fixture/'outside-target'; target.mkdir(); os.utime(target,(now-90000,now-90000))
    (claims/'20005').symlink_to(target, target_is_directory=True)
    os.utime(marker,(946684800,946684800))
    call('date() { if [ "$1" = +%s ]; then printf "%s\\n" '+str(now)+'; else command date "$@"; fi; }; fm_remote_job_reap_stale "$2"')
    removed=['20001','20003','00','01','17461']
    kept=['20002','0','notes','1x','.private','20004','20005']
    assert all(not (claims/n).exists() for n in removed)
    assert all((claims/n).exists() for n in kept)
    assert (claims/'20004'/'payload').read_text()=='must survive' and target.is_dir()
    assert not list(state.glob('.seqreap*'))
    print(json.dumps(dict(scenario='retention and adversarial guards', removed=removed, preserved=kept, symlink_target='intact', temporary_beacons='removed')), flush=True)
finally:
    shutil.rmtree(fixture)
