import json, os, pathlib, shutil, subprocess, time
ROOT = pathlib.Path.cwd()
SCRATCH = ROOT / '.test-claim-validation'
EVIDENCE = pathlib.Path('/Users/kunchen/.no-mistakes/evidence/01M447XA82K0HSFN5VMT2JWQMP')
BASE = SCRATCH / 'base/bin/fm-remote-job-lib.sh'
CURRENT = ROOT / 'bin/fm-remote-job-lib.sh'

def env_for(home, state):
    env = os.environ.copy()
    for key in ('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    env.update(HOME=str(home), FM_REMOTE_JOB_STATE_ROOT=str(state), TMPDIR=str(SCRATCH / 'tmp'))
    return env

def lib_run(lib, env, command, *args):
    return subprocess.run(['bash', '-c', '. "$1"; shift; ' + command, '_', str(lib), *map(str,args)], env=env, text=True, capture_output=True, check=True)

def fixture(name, lib):
    root = SCRATCH / name
    root.mkdir()
    home, state = root / 'account', root / 'state'
    home.mkdir()
    env = env_for(home, state)
    lib_run(lib, env, 'fm_remote_job_prepare_state "$HOME" || exit 1')
    return root, home, state, env

results = []
for name, lib in [('current', CURRENT), ('base', BASE)]:
    root, home, state, env = fixture('retention-' + name, lib)
    claims = state / '.seq-claims'
    now = int(time.time())
    ages = {'1': now - 90000, '2': now - 86410, '3': now - 86390, '4': now, '0': now - 90000, 'notes': now - 90000, '1x': now - 90000, '.private': now - 90000, '5': now - 90000}
    for leaf, stamp in ages.items():
        (claims / leaf).mkdir()
    (claims / '5' / 'keep').write_text('nonempty claim must survive\n')
    outside = root / 'outside'
    outside.mkdir()
    (outside / '6').mkdir()
    os.utime(outside / '6', (now - 90000, now - 90000))
    (claims / '6').symlink_to(outside / '6', target_is_directory=True)
    (claims / '7').write_text('regular file must survive\n')
    for leaf, stamp in ages.items():
        os.utime(claims / leaf, (stamp, stamp))
    started = time.perf_counter()
    response = lib_run(lib, env, 'fm_remote_job_reap_stale "$HOME" || exit 1')
    retained = sorted(p.name for p in claims.iterdir())
    expected = sorted(['3','4','0','notes','1x','.private','5','6','7'])
    boundary = {'implementation': name, 'sweep_seconds': round(time.perf_counter()-started, 4), 'retained': retained, 'expected_previous_retention': expected, 'age_boundary_ok': not (claims/'1').exists() and not (claims/'2').exists() and (claims/'3').exists() and (claims/'4').exists(), 'nonempty_and_symlink_and_file_preserved': (claims/'5'/'keep').exists() and (claims/'6').is_symlink() and (outside/'6').exists() and (claims/'7').is_file(), 'invalid_and_hidden_names_preserved': all((claims/leaf).exists() for leaf in ['0','notes','1x','.private']), 'stdout': response.stdout, 'stderr': response.stderr}
    (claims / '8').mkdir()
    os.utime(claims/'8', (now-90000, now-90000))
    marker = state / '.seq-claims-reaped'
    first_marker_mtime = marker.stat().st_mtime_ns
    lib_run(lib, env, 'fm_remote_job_reap_stale "$HOME" || exit 1')
    boundary['hourly_marker_blocks_second_sweep'] = (claims/'8').exists() and marker.stat().st_mtime_ns == first_marker_mtime
    os.utime(marker, (now-3605, now-3605))
    lib_run(lib, env, 'fm_remote_job_reap_stale "$HOME" || exit 1')
    boundary['due_marker_allows_next_sweep'] = not (claims/'8').exists()
    boundary['temporary_reference_files_left'] = [p.name for p in state.glob('.seqreap*')]
    results.append(boundary)
    shutil.rmtree(root)

(EVIDENCE/'retention-boundaries.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2), flush=True)

bench = []
for name, lib in [('current', CURRENT), ('base', BASE)]:
    root, home, state, env = fixture('benchmark-' + name, lib)
    claims = state / '.seq-claims'
    old = time.time() - 90000
    for i in range(1,17461):
        p = claims / str(i)
        p.mkdir()
        if i <= 8730:
            os.utime(p, (old,old))
    before = len(list(claims.iterdir()))
    started = time.perf_counter()
    response = lib_run(lib, env, 'fm_remote_job_reap_stale "$HOME" || exit 1')
    elapsed = time.perf_counter()-started
    remaining = len(list(claims.iterdir()))
    row = {'implementation': name, 'claim_count_before':before, 'expired_claims':8730, 'sweep_seconds':round(elapsed,4), 'claim_count_after':remaining, 'expired_removed':not (claims/'1').exists() and not (claims/'8730').exists(), 'fresh_preserved':(claims/'8731').exists() and (claims/'17460').exists(), 'stderr':response.stderr}
    bench.append(row)
    print(json.dumps(row), flush=True)
    shutil.rmtree(root)
(EVIDENCE/'sweep-benchmark.json').write_text(json.dumps(bench,indent=2)+'\n')
