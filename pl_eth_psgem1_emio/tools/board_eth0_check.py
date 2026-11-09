# 只读：确认板子 eth0 是否仍在路由器上（区分"插的是 PL 口还是 PS 口"）
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import paramiko

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("192.168.1.113", username="root", password="fmsh", timeout=20,
            look_for_keys=False, allow_agent=False)

def run(cmd, t=30):
    _, o, e = cli.exec_command(cmd, timeout=t)
    o.channel.recv_exit_status()
    so = o.read().decode("utf-8", "replace").rstrip()
    se = e.read().decode("utf-8", "replace").rstrip()
    print("\n$ " + cmd)
    if so: print(so)
    if se: print("[err] " + se)
    return so

run("ip -br addr")
run("cat /sys/class/net/eth0/operstate; cat /sys/class/net/eth0/carrier; cat /sys/class/net/eth0/speed")
run("ip -s link show eth0 | head -6")
run("dmesg | grep -E 'Link is (Up|Down)' | tail -8")
run("echo -n 'Up='; dmesg | grep -c 'Link is Up'; echo -n 'Down='; dmesg | grep -c 'Link is Down'")
run("ip -br link")

cli.close()
