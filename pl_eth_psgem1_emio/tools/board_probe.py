# 只读探测：确认板上有几个网口、GEM1 节点在不在、eth0 健康度
# 不写板、不改配置、不重启任何服务
import sys, time, io
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import paramiko

HOST = "192.168.1.113"
PW = "fmsh"

CMDS = [
    ("A1 ip -br link", "ip -br link"),
    ("A2 /sys/class/net", "ls /sys/class/net"),
    ("A3 GEM1 platform 节点", "ls /sys/bus/platform/devices | grep -i e0049 || echo NO_e0049"),
    ("A4 device-tree ethernet 节点", "ls /proc/device-tree | grep -i ethernet || echo NO_DT_ETH"),
    ("A5 dwmac 驱动目录", "ls /sys/bus/platform/drivers | grep -i -E 'dwmac|stmmac' || echo NO_DRIVER_DIR"),
    ("A6 dmesg eth 相关", "dmesg 2>/dev/null | grep -iE 'fmql-dwmac|eth[01]' | tail -40"),
    ("A7 ethtool eth0", "ethtool eth0 2>&1 | head -40"),
    ("A8 speed/duplex/carrier", "for f in speed duplex carrier operstate; do printf '%s=%s\\n' $f \"$(cat /sys/class/net/eth0/$f 2>&1)\"; done"),
    ("A9 ip -s link show eth0", "ip -s link show eth0"),
    ("A10 dmesg Link Up/Down 计数", "echo -n 'Up='; dmesg 2>/dev/null | grep -c 'Link is Up'; echo -n 'Down='; dmesg 2>/dev/null | grep -c 'Link is Down'"),
    ("A11 /proc/net/dev", "cat /proc/net/dev"),
    ("A12 ethtool -S eth0 尾部", "ethtool -S eth0 2>&1 | tail -40"),
    ("A13 ip addr", "ip -br addr"),
    ("A14 路由", "ip route"),
    ("A15 /proc/device-tree ethernet 详情", "for d in /proc/device-tree/amba-apu@0/ethernet@*; do echo \"== $d\"; cat $d/status 2>/dev/null | tr -d '\\0'; echo; cat $d/phy-mode 2>/dev/null | tr -d '\\0'; echo; done"),
]

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username="root", password=PW, timeout=20,
            look_for_keys=False, allow_agent=False)

buf = io.StringIO()
buf.write("board probe @ %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))

for title, cmd in CMDS:
    _, o, e = cli.exec_command(cmd, timeout=60)
    o.channel.recv_exit_status()
    so = o.read().decode("utf-8", "replace").rstrip()
    se = e.read().decode("utf-8", "replace").rstrip()
    block = "\n===== %s =====\n$ %s\n%s" % (title, cmd, so)
    if se:
        block += "\n[stderr] " + se
    print(block, flush=True)
    buf.write(block + "\n")

cli.close()

out = "S:/work/WCIS/workenv/pl_eth/board_probe_%s.txt" % time.strftime("%Y%m%d_%H%M%S")
with open(out, "w", encoding="utf-8") as f:
    f.write(buf.getvalue())
print("\n[saved] " + out)
