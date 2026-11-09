#!/usr/bin/env python3
# board-boot-swap.py — 把本地 BOOT.bin 写进板子 SD 卡的引导分区并（可选）重启
#
# 用法：
#   python board-boot-swap.py 192.168.1.113                      只写，不重启（打印重启命令）
#   python board-boot-swap.py 192.168.1.113 --reboot             写完立即重启
#   python board-boot-swap.py 113 --file BOOT_status_export.bin --expect-boot fd15bb85
# 门禁：卡上必须有一份 md5 为官方原版（aca4612b…）的 BOOT.bak 兜底，否则拒绝写入；
#       现网 BOOT.bin 与 --expect-boot 前缀不符时也要 --force 才继续。
import hashlib
import re
import socket
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import paramiko

OFFICIAL_BOOT_MD5 = "aca4612b566738350a8c5edac0db1929"
DEV = "/dev/mmcblk0p1"
MP = "/mnt/p1"
CH = 8192
# 口令值全库单点：从既有的 board-ssh.py 里取，不再抄第三份
PW = re.search(r'password="([^"]+)"',
               open("S:/apps/llm/agentwork/board-ssh.py", encoding="utf-8").read()).group(1)

host = sys.argv[1]
args = sys.argv[2:]
reboot = "--reboot" in args
force = "--force" in args
no_gate = "--no-rollback-gate" in args
fname = "BOOT_status_export.bin"
expect_boot = None
for a in ("--file", "--expect-boot"):
    if a in args:
        v = args[args.index(a) + 1]
        if a == "--file":
            fname = v
        else:
            expect_boot = v
        del args[args.index(a):args.index(a) + 2]

data = open(fname, "rb").read()
lm = hashlib.md5(data).hexdigest()
print("local  %s: %d B md5=%s" % (fname, len(data), lm))

s = socket.create_connection((host, 22), timeout=8)
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username="root", password=PW, sock=s,
          look_for_keys=False, allow_agent=False, timeout=10)


def run(cmd, t=60):
    _, out, err = c.exec_command(cmd, timeout=t)
    o = out.read().decode(errors="replace")
    e = err.read().decode(errors="replace")
    print("$ %s\n%s%s" % (cmd, o, ("STDERR:" + e) if e.strip() else ""))
    return o, e


print("board clock: %s  boot_id: %s" % (
    run("date -u -Iseconds")[0].strip(), run("cat /proc/sys/kernel/random/boot_id")[0].strip()))
run("find /mnt -maxdepth 2 -name 'BOOT*' -type f 2>/dev/null | head")
run("md5sum %s/BOOT.bin %s/BOOT.bak %s/AA.bin 2>/dev/null | head" % (MP, MP, MP))
run("mkdir -p %s; mount %s %s 2>&1; mount | grep mmcblk0p1" % (MP, DEV, MP))
listing = run("ls -l %s | head -20" % MP)[0]
print(listing)
cur = run("md5sum %s/BOOT.bin 2>/dev/null | cut -d' ' -f1" % MP)[0].strip()
bak = run("md5sum %s/BOOT.bak 2>/dev/null | cut -d' ' -f1" % MP)[0].strip()
print("on-card BOOT.bin=%s  BOOT.bak=%s" % (cur or "MISSING", bak or "MISSING"))

if not no_gate and bak != OFFICIAL_BOOT_MD5:
    print("GATE: 卡上没有官方原版 BOOT.bak（或已改动），拒绝写入。"
          "确认有别的兜底后加 --no-rollback-gate 重来。")
    sys.exit(4)
if expect_boot is not None and not cur.startswith(expect_boot):
    if not force:
        print("GATE: 现网 BOOT.bin=%s 与预期 %s 不符（可能另一个会话换过片）。加 --force 继续。"
              % (cur, expect_boot))
        sys.exit(5)
    print("GATE overridden by --force")

t0 = time.time()
sftp = c.open_sftp()
sftp.put(fname, "%s/NB.bin" % MP)
sftp.chmod("%s/NB.bin" % MP, 0o644)
sftp.close()
print("sftp put %d B in %.1fs" % (len(data), time.time() - t0))

remote = run("wc -c < %s/NB.bin; md5sum %s/NB.bin | cut -d' ' -f1" % (MP, MP))[0]
print("NB.bin on board: %s" % remote.replace("\n", " / ").strip())
if lm not in remote:
    print("GATE: 上传后 md5 不符，中止（BOOT.bin 未改动）")
    sys.exit(7)

run("cp -f %s/BOOT.bin %s/BOOT.pre_swap.bin && sync && md5sum %s/BOOT.pre_swap.bin | cut -d' ' -f1"
    % (MP, MP, MP))
run("mv -f %s/NB.bin %s/BOOT.bin && sync && sync && md5sum %s/BOOT.bin && wc -c < %s/BOOT.bin"
    % (MP, MP, MP, MP))
after = run("md5sum %s/BOOT.bin | cut -d' ' -f1" % MP)[0].strip()
if after != lm:
    print("!!! BOOT.bin 落盘校验不符（%s != %s），立刻回滚" % (after, lm))
    run("cp -f %s/BOOT.pre_swap.bin %s/BOOT.bin && sync" % (MP, MP))
    sys.exit(8)
run("umount %s; echo umount_rc=$?" % MP)
print("SWAP DONE: BOOT.bin 现为 %s（下次上电生效）" % lm)

if reboot:
    print("rebooting（会打断板上所有会话）")
    c.exec_command("sync; sleep 1; reboot", timeout=20)
else:
    print("未重启。重启：python board-ssh.py %s 'sync; reboot'" % host)
time.sleep(1)
c.close()
