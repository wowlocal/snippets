#!/usr/bin/env python3
"""Exercise shipping SecureInput.swift with synthetic secrets and disposable PTYs."""
import errno, hashlib, os, pathlib, pty, select, signal, subprocess, sys, tempfile, termios, time
binary = sys.argv[1]
body = '  fictional-秘密\nsecond line\n'.encode()
def run(*args, body=body, **kw):
    return subprocess.run([binary, *args], input=body, capture_output=True, timeout=5, **kw)
def good(r, value):
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == b'OK ' + hashlib.sha256(value).hexdigest().encode()
    assert value not in r.stdout + r.stderr
def bad(r):
    assert r.returncode == 1
    assert body not in r.stdout + r.stderr
with tempfile.TemporaryDirectory(prefix='secure-input-') as d:
    root = pathlib.Path(d)
    f = root/'secret'; f.write_bytes(body); f.chmod(0o600)
    good(run('stdin'), body)
    good(run('file', str(f)), body)
    with f.open('rb') as stream:
        good(run('fd', str(stream.fileno()), pass_fds=(stream.fileno(),)), body)
    read_fd, write_fd = os.pipe()
    os.write(write_fd, body); os.close(write_fd)
    good(run('fd', str(read_fd), pass_fds=(read_fd,)), body); os.close(read_fd)
    for value in (b'', b'\xff', b'a'*65): bad(run('stdin', body=value))
    good(run('stdin', body=b'a'*64), b'a'*64)
    good(run('stdin', body=b'a\x00b'), b'a\x00b')
    f.chmod(0o644); bad(run('file', str(f)))
    f.chmod(0o600)
    link = root/'link'; link.symlink_to(f); bad(run('file', str(link)))
    fifo = root/'fifo'; os.mkfifo(fifo, 0o600); bad(run('file', str(fifo)))
    bad(run('file', str(root))); bad(run('file', str(root/'absent')))
    bad(run('fd', '9999')); bad(run('prompt', start_new_session=True))

    def terminal(value, cancel=False):
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(binary, [binary, 'prompt'])
        output = b''
        status = None
        try:
            deadline = time.monotonic()+5
            while b'one line): ' not in output:
                assert time.monotonic() < deadline, 'prompt timeout'
                if select.select([fd], [], [], .1)[0]: output += os.read(fd, 4096)
            assert termios.tcgetattr(fd)[3] & termios.ECHO == 0
            os.write(fd, b'\x03' if cancel else value+b'\n')
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        part=os.read(fd,4096)
                        if not part: break
                        output += part
                    except OSError as e:
                        if e.errno != errno.EIO: raise
                        break
            _, status = os.waitpid(pid, 0)
            assert termios.tcgetattr(fd)[3] & termios.ECHO, 'terminal echo was not restored'
            assert value not in output, 'terminal echoed secret'
            if cancel:
                assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGINT
            elif len(value) <= 64:
                assert os.waitstatus_to_exitcode(status) == 0, output
                assert hashlib.sha256(value).hexdigest().encode() in output
            else: assert os.waitstatus_to_exitcode(status) == 1
        finally:
            if status is None:
                os.kill(pid, signal.SIGKILL); os.waitpid(pid,0)
            os.close(fd)
    terminal(b'fictional-hidden-input')
    terminal('  вымышленный-秘密  '.encode())
    terminal(b'x'*65)
    terminal(b'cancel-test', cancel=True)
print('PASS: pipe, private file, inherited fd, exact bytes, UTF-8/size errors, hidden prompt, Ctrl-C and echo restoration')
