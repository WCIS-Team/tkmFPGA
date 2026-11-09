"""Upload files to the board over SFTP, install with mv, and verify md5 on both ends.

usage: python board-put.py 192.168.1.113 "S:/local/path=/root/remote/path" ...
The login secret is read from board-ssh.py so it keeps one home, not two.
"""
import hashlib
import os
import re
import shlex
import socket
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import paramiko

host = sys.argv[1]
pairs = sys.argv[2:]
if not pairs:
    raise SystemExit("nothing to upload")


def find_credential():
    # The login secret has exactly one home (never committed); board-put ships
    # without it, so resolve it from an explicit env override, the canonical
    # workstation home used by the other uploaders, then the legacy in-repo path.
    candidates = [
        os.environ.get("WCIS_BOARD_SSH"),
        "S:/apps/llm/agentwork/board-ssh.py",
        str(Path(__file__).resolve().parents[2] / "board-ssh.py"),
    ]
    for c in candidates:
        if c and Path(c).exists():
            return Path(c).read_text(encoding="utf-8")
    raise SystemExit("board-ssh.py credential not found (set WCIS_BOARD_SSH)")


cred = find_credential()
password = re.search(r'password="([^"]+)"', cred).group(1)

connection = paramiko.SSHClient()
connection.set_missing_host_key_policy(paramiko.AutoAddPolicy())
sock = socket.create_connection((host, 22), timeout=8)
connection.connect(host, username="root", password=password, sock=sock,
                   look_for_keys=False, allow_agent=False, timeout=10)
ftp = connection.open_sftp()
rc = 0
for pair in pairs:
    local, remote = pair.split("=", 1)
    data = Path(local).read_bytes()
    digest = hashlib.md5(data).hexdigest()
    temporary = remote + ".new"
    with ftp.open(temporary, "wb") as handle:
        handle.write(data)
        handle.flush()
    command = "mv -f %s %s && md5sum %s" % (shlex.quote(temporary), shlex.quote(remote), shlex.quote(remote))
    _, out, err = connection.exec_command(command, timeout=60)
    line = out.read().decode("utf-8", "replace").strip()
    error = err.read().decode("utf-8", "replace").strip()
    ok = line.startswith(digest)
    rc = rc or (0 if ok else 1)
    print("%s %s %s" % ("OK  " if ok else "FAIL", digest, remote if ok else line + " " + error))
ftp.close()
connection.close()
raise SystemExit(rc)
