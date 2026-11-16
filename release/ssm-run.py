#!/usr/bin/env python3
# Runs a bash script on the production EC2 server through AWS Session Manager (the only access available).
# usage: python3 -I ssm-run.py <script-file> [timeout-seconds]
# Needs the AWS profile edunexus-deploy and the session-manager-plugin. The script is sent base64-encoded, runs as
# root with sudo, and its temporary copy in /tmp is removed afterwards.
import base64, os, pty, select, sys, time

INSTANCE = 'i-036deb764f61a10ef'
script = open(sys.argv[1], 'rb').read()
timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 900
env = dict(os.environ, AWS_PROFILE='edunexus-deploy', AWS_REGION='us-east-1')
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('aws', ['aws', 'ssm', 'start-session', '--target', INSTANCE], env)


def read_until(marker, seconds):
    buf = b''
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            buf += data
            if marker in buf:
                return buf
    return buf


read_until(b'$ ', 60)
encoded = base64.b64encode(script).decode()
os.write(fd, b'stty -echo; unset HISTFILE; umask 077; export PAGER=cat PSQL_PAGER=cat; rm -f /tmp/.rel.b64\n')
read_until(b'$ ', 10)
for i in range(0, len(encoded), 2000):
    os.write(fd, ('printf %s ' % encoded[i:i + 2000] + '>> /tmp/.rel.b64\n').encode())
    read_until(b'$ ', 30)
os.write(fd, b"base64 -d /tmp/.rel.b64 > /tmp/.rel.sh; rm -f /tmp/.rel.b64; echo ==BEGIN==; sudo PAGER=cat bash /tmp/.rel.sh 2>&1; echo ==END rc=$?==; rm -f /tmp/.rel.sh\n")
out = read_until(b'==END rc=', timeout)
out += read_until(b'==\r\n', 5)
os.write(fd, b'exit\n')
time.sleep(1)
text = out.decode('utf-8', 'replace').replace('\r', '')
start = text.rfind('==BEGIN==')
print(text[start:] if start >= 0 else text)
sys.exit(0 if '==END rc=0==' in text else 1)
