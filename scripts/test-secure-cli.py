#!/usr/bin/env python3
"""Isolated CLI refusal tests. Never connects to the user's app or vault."""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
cli = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='scli-', dir='/tmp') as directory:
    root = pathlib.Path(directory)
    env = dict(os.environ, SNIPPETS_SUPPORT_DIR=directory, LLVM_PROFILE_FILE=str(root/'cli.profraw'))
    def run(*args, body=b'fictional-secret-only'):
        return subprocess.run([cli, *args], input=body, capture_output=True, env=env, timeout=10)
    common = ['add', '--keyword', 'synthetic']
    for flags in [ ['--secure', '--content', 'fictional-secret-only'],
                   ['--secure'], ['--secur', '--content', '-'],
                   ['--secure', '--content', '-', '--content', '-'],
                   ['--secure', '--stdin', '--prompt'],
                   ['--secure', '--content', '-', '--stdin'],
                   ['--secure', '--content-file', '/unused', '--prompt'],
                   ['--secure', '--content-fd', 'fictional-secret-only'],
                   ['--secure', '--content-fd', '-1'],
                   ['--content-file', '/unused'], ['--prompt'] ]:
        result = run(*common, *flags)
        assert result.returncode == 1
        assert b'fictional-secret-only' not in result.stdout + result.stderr
        assert not (root/'snippets.json').exists()
    result = run(*common, '--secure', '--content', '-')
    assert result.returncode == 3
    assert not (root/'snippets.json').exists()
    # A same-user impostor can bind the socket, but must receive zero body bytes.
    (root/'Sync').mkdir(exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(root/'Sync'/'ipc.sock'))
    listener.listen(1)
    received = []
    sources = [['--content', '-'], ['--stdin'], ['--content-file', '/unused'],
               ['--content-fd', '0'], ['--prompt']]
    def accept():
        for _ in sources:
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(5)
                received.append(conn.recv(4096))
    thread = threading.Thread(target=accept)
    thread.start()
    for source in sources:
        result = run(*common, '--secure', *source)
        assert result.returncode == 1
        assert b'fictional-secret-only' not in result.stdout + result.stderr
    thread.join(timeout=6)
    listener.close()
    assert result.returncode == 1
    assert received == [b''] * len(sources), 'secret was transmitted to an unverified peer'
    assert b'fictional-secret-only' not in result.stdout + result.stderr
    result = run(*common, '--content', '-')
    assert result.returncode == 0
    assert json.loads(result.stdout)['content'] == 'fictional-secret-only'
    before = (root/'snippets.json').read_bytes()
    for flags in [['--secure', '--content', '-'], ['--prompt'], ['--secur', '--content', '-']]:
        result = run('update', 'synthetic', *flags, body=b'different-test-secret')
        assert result.returncode == 1
        assert b'different-test-secret' not in result.stdout + result.stderr
        assert (root/'snippets.json').read_bytes() == before
print('PASS: input-source validation, no-app refusal, impostor receives no data, ordinary add preserved')
