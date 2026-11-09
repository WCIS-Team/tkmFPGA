#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""有界 PL-YT8521 PHY 诊断（B 路候选位流的 NTP2 管理页，只读为主）。

现役件重写的背景见 wiki/PL/pl_eth_psgem1_emio.md 第三节与 D-1793904039：旧脚本与 v2 原件都不在盘上，
且旧那次"标识全为 0"不能当 PHY 数据真全零的证据（写 MMIO 的方式不保证 32 位访问宽度）。
本版相对旧版的改进＝每次控制写都回读、并且先做一次性写宽度自证，再做 MDIO 扫描。

用法：
  板上（必须跑在候选位流 fd5606055c4c 下）：python3 read_phy_identifiers_v2.py --out /root/phy-id-v2.json
  本机离线自测（不碰 /dev/mem）：        python -X utf8 read_phy_identifiers_v2.py --selftest

退出码：0＝扫到 PHY；2＝管理页不在（位流不是候选件，板子没被动过）；
        3＝写宽度/回读自证失败（访问路径坏，PHY 结论无效）；1＝页面活着且访问正确，但 32 个地址都不应。
"""
import ctypes
import json
import os
import sys
import time

REG_PAGE = 0x400C2200           # 管理页：0x400c0000 起 256 KiB 窗口里 awaddr[17:8]==10'h022
MAGIC = 0x4E545032              # NTP2，TX_ONLY_SERDES=1 时才有（wcis_preview_registers.v:80）
EXPECTED = {"magic": MAGIC, "capability": 7, "width": 1920, "height": 1080}

R_ID, R_ENABLE, R_STATUS, R_REJECT = 0x00, 0x04, 0x08, 0x2C
R_SESSION, R_MASK = 0x0C, 0x24
R_CMD, R_RESP, R_RESET = 0x30, 0x34, 0x38
R_CAP, R_W, R_H = 0x5C, 0x54, 0x58

BUSY, DONE, ERR = 0x10000, 0x20000, 0x40000
YT8521_ID = 0x0000011A          # reg2<<16|reg3，出处 npu_photo/src/pl_net_config.cpp:71


def rd(reg):
    raise RuntimeError("no memory model bound")


def wr(reg, val):
    raise RuntimeError("no memory model bound")


class DevMem:
    """一次 32 位对齐访问＝一条 ldr/str，不靠 memcpy 的拆分行为。

    path 默认 /dev/mem（PL AXI 窗口不受 STRICT_DEVMEM 限制，板上已用同样方式映射 0x40080000，
    见 repos/FPAI30TAI图像FPGA/ps_app/src/wcis_camera_mmio.hpp:11-31）；
    传一个普通文件即可在没有板子的机器上验证这条 ctypes 取数路径（--selftest-device）。
    """

    def __init__(self, path="/dev/mem", base=REG_PAGE):
        import mmap as _m
        pagesize = _m.PAGESIZE
        self.aligned = base & ~(pagesize - 1)
        self.intra = base - self.aligned
        length = self.intra + 0x100                   # 寄存器页只用到 +0x64，留一整页
        size = (length + pagesize - 1) & ~(pagesize - 1)
        self.fd = os.open(path, os.O_RDWR | getattr(os, "O_SYNC", 0) | os.O_CLOEXEC)
        try:
            self.mm = _m.mmap(self.fd, size, offset=self.aligned, access=_m.ACCESS_WRITE)
        except (ValueError, OSError) as exc:
            os.close(self.fd)
            raise RuntimeError("mmap(%s, off=0x%x, len=0x%x) failed: %s（pagesize=0x%x）"
                               % (path, self.aligned, size, exc, pagesize))
        self.words = (ctypes.c_uint32 * (size // 4)).from_buffer(self.mm)

    def read(self, reg):
        return self.words[(self.intra + reg) // 4]

    def write(self, reg, val):
        self.words[(self.intra + reg) // 4] = val & 0xFFFFFFFF

    def close(self):
        try:
            self.words = None                    # 先放掉 ctypes 导出的缓冲区，否则 mmap 关不掉
            self.mm.close()
        finally:
            os.close(self.fd)


def mdio(reading, phy, reg, data=0, absent_ok=False, deadline_s=0.1):
    """一次有界 Clause-22 事务。返回 (value, raw, error_bit)；absent 时 value=None。"""
    if rd(R_RESP) & BUSY:
        raise RuntimeError("MDIO busy before trigger")
    wr(R_CMD, (0x40000000 if reading else 0) | ((phy & 0x1F) << 21) | ((reg & 0x1F) << 16) | (data & 0xFFFF))
    end = time.time() + deadline_s
    while True:
        s = rd(R_RESP)
        if not (s & BUSY) and (s & DONE):
            break
        if time.time() > end:
            raise RuntimeError("MDIO deadline: raw=0x%08x" % s)
        time.sleep(10 / 1e6)
    if s & ERR:
        if absent_ok:
            return None, s, True
        raise RuntimeError("turnaround failed: raw=0x%08x" % s)
    return s & 0xFFFF, s, False


def build_sequence():
    """五步按 D-1793904039 步骤①的判据顺序；每步返回 (ok, note)，失败即停。"""

    def p0_identity(ctx):
        got = {"magic": rd(R_ID), "capability": rd(R_CAP), "width": rd(R_W), "height": rd(R_H)}
        ctx["page"] = got
        for k, v in EXPECTED.items():
            if got[k] != v:
                return False, "page mismatch: %r != %r" % (got[k], v)
        return True, ""

    def p1_width(ctx):
        """逐字节不同的两个种子：任一字节没落上就会被看出来。"""
        bad = []
        if rd(R_ENABLE) & 1:                   # enable=1 时页面只收 0x04=0，其余写全被拒
            wr(R_ENABLE, 0)
            if rd(R_ENABLE) & 1:
                return False, "enable stayed 1 after writing 0（推流没停，MDIO 扫描无法独占）"
        before = rd(R_REJECT)
        for reg, seed in zip((R_SESSION, R_MASK), (0xDEADBEEF, 0x13579BDF)):
            wr(reg, 0)
            wr(reg, seed)
            back = rd(reg)
            ctx.setdefault("width", {})[hex(reg)] = {"wrote": seed, "read": back}
            if back != seed:
                bad.append("%s: wrote 0x%08x read 0x%08x" % (hex(reg), seed, back))
            wr(reg, 0)
            if rd(reg) != 0:
                bad.append("%s: could not clear" % hex(reg))
        after = rd(R_REJECT)
        ctx["rejected_writes"] = {"before": before, "after": after}
        if after != before:
            bad.append("rejected_writes grew %d -> %d (enable=1, or a write hit an unwritable offset)" % (before, after))
        return (not bad), "; ".join(bad)

    def p2_reset(ctx):
        wr(R_RESET, 0)
        if rd(R_RESET) & 1:
            return False, "phy_reset_n stayed 1 after writing 0"
        time.sleep(0.02)                       # YT8521S Table 13：低电平 >= 10 ms
        wr(R_RESET, 1)
        if not rd(R_RESET) & 1:
            return False, "phy_reset_n stayed 0 after writing 1"
        time.sleep(0.05)
        return True, ""

    def p3_scan(ctx):
        rows = []
        hit = None
        for a in range(32):
            hi, raw_hi, _ = mdio(True, a, 2, 0, absent_ok=True)
            if hi is None:
                rows.append({"phy": a, "present": False, "raw": raw_hi})
                continue
            lo, raw_lo, _ = mdio(True, a, 3, 0, absent_ok=True)
            ident = None if lo is None else (hi << 16) | lo
            rows.append({"phy": a, "raw_hi": raw_hi, "raw_lo": raw_lo, "id": ident})
            if ident == YT8521_ID:
                if hit is not None:
                    return False, "two YT8521 at %d and %d" % (hit, a)
                hit = a
        ctx["scan"] = rows
        ctx["phy"] = hit
        return True, ""

    def p4_dump(ctx):
        a = ctx["phy"]
        if a is None:
            return True, "no PHY answered; skip register dump"
        ctx["bank"] = {}
        for r in range(32):
            v, _, _ = mdio(True, a, r, 0, absent_ok=True)
            ctx["bank"][r] = v
        ext = {}
        for addr in (0xA001, 0xA003):          # 扩展地址：strap / TX 延迟，只读
            mdio(False, a, 0x1E, addr)
            v, _, _ = mdio(True, a, 0x1F, 0, absent_ok=True)
            ext[hex(addr)] = v
        ctx["extended"] = ext
        return True, ""

    return [("P0_page_identity", p0_identity, 2), ("P1_write_width", p1_width, 3),
            ("P2_phy_reset", p2_reset, 3), ("P3_mdio_scan", p3_scan, 1), ("P4_dump", p4_dump, 1)]


def run(report):
    ctx = {}
    verdict = 0
    for name, fn, fail_code in build_sequence():
        try:
            ok, msg = fn(ctx)
        except Exception as exc:                # 每一步都要留下读数，不让它半路丢
            ctx[name] = {"error": str(exc)}
            report["steps"].append({"step": name, "ok": False, "error": str(exc)})
            text = str(exc)
            engine_dead = ("deadline" in text) or ("busy" in text) or ("turnaround" in text)
            verdict = 3 if engine_dead or name in ("P2_phy_reset",) else 1
            break
        report["steps"].append({"step": name, "ok": ok, "note": msg})
        if not ok:
            verdict = fail_code
            break
    report["context"] = {k: v for k, v in ctx.items() if k != "scan"}
    report["scan"] = ctx.get("scan")
    report["phy"] = ctx.get("phy")
    if ctx.get("phy") is None and verdict == 0:
        verdict = 1
    report["verdict"] = verdict
    report["boundary"] = {
        1: ("本套读数分不出“PHY 不应答”与“我方 MDIO 输入路径被钉在低”"
            "——事务期间线恒 0 时 turnaround 检查也不报错。要判死这一条需要"
            "B2 离线探针里的 MDIO 自环或示波器。"),
        3: "访问宽度或 MDIO 引擎这一层就没走通，PHY 有没有应答的结论不成立。",
        2: "管理页不在＝位流不是候选件，板子未被本工具动过（一次写都没发）。",
    }.get(verdict, "")
    return verdict


def selftest():
    """离线自测：用 1024 字的 python 列表当寄存器堆，验证打包与判据顺序，不碰 /dev/mem。

    三个场景＝板上可能遇到的三种总线状态：有 PHY 应答、地址 7 应答且 ID 正确；
    全线被钉在低（正是 2026-10-28 那次“标识全为 0”的读数形状）；访问宽度坏（写进读不出）。
    """
    IDX = lambda reg: reg // 4     # 模型＝从管理页首字开始的寄存器堆
    mem = [0] * 64
    mem[IDX(R_ID)] = MAGIC
    mem[IDX(R_CAP)] = 7
    mem[IDX(R_W)] = 1920
    mem[IDX(R_H)] = 1080
    mode = {"bus": "phy7", "width": "ok"}

    def _rd(reg):
        return mem[IDX(reg)]

    def _wr(reg, val):
        idx = IDX(reg)
        val &= 0xFFFFFFFF
        if reg == R_CMD:
            mem[idx] = 0
            reading = bool(val & 0x40000000)
            phy = (val >> 21) & 0x1F
            r = (val >> 16) & 0x1F
            resp = mem[IDX(R_RESP)]
            if not reading:
                mem[IDX(R_RESP)] = DONE
            elif mode["bus"] == "stuck_low":
                resp = DONE                                  # 线恒 0：无 error、数据全 0
                mem[IDX(R_RESP)] = resp
            elif phy == 7:
                mem[IDX(R_RESP)] = DONE | {2: 0x0000, 3: 0x011A}.get(r, 0x5A5A)
            else:
                mem[IDX(R_RESP)] = DONE | ERR  # 别址不应答
        else:
            if reg in (R_SESSION, R_MASK) and mode["width"] == "broken":
                mem[idx] = 0                                 # 写得进去但读回 0＝字节没落全
            else:
                mem[idx] = val

    global rd, wr
    rd, wr = _rd, _wr
    checks = []

    # 触发字段的打包必须与 RTL 的 case(awaddr[7:0]) 0x30 一致
    sent = []
    _wr_base = _wr
    rd, wr = _rd, (lambda reg, val: (sent.append((reg, val & 0xFFFFFFFF)), _wr_base(reg, val))[1])
    mdio(True, 7, 2, 0, absent_ok=True)
    reg, word = sent[0]
    checks.append(("cmd_reg_offset", reg == R_CMD))
    checks.append(("cmd_read_bit30", bool(word & 0x40000000)))
    checks.append(("cmd_phy_bits25_21", ((word >> 21) & 0x1F) == 7))
    checks.append(("cmd_reg_bits20_16", ((word >> 16) & 0x1F) == 2))
    checks.append(("cmd_data_bits15_0", (word & 0xFFFF) == 0))
    rd, wr = _rd, _wr_base

    # 场景一：地址 7 是活的 YT8521
    r1 = {"steps": []}
    v1 = run(r1)
    checks.append(("phy7_verdict_0", v1 == 0))
    checks.append(("phy7_found", r1.get("phy") == 7))
    checks.append(("phy7_dumped_reg0", r1["context"].get("bank", {}).get(0) == 0x5A5A))
    checks.append(("phy7_ext_readback", r1["context"].get("extended", {}).get("0xa001") == 0x5A5A))
    checks.append(("phy7_no_boundary", r1.get("boundary") == ""))

    # 场景二：管理页不是 NTP2（位流不是候选件）⇒ 停在 P0 且一次写都没有
    mem[IDX(R_ID)] = 0x4E545031
    writes = []
    rd, wr = _rd, (lambda reg, val: (writes.append(reg), _wr_base(reg, val))[1])
    r2 = {"steps": []}
    v2 = run(r2)
    rd, wr = _rd, _wr_base
    checks.append(("wrong_bitstream_verdict_2", v2 == 2))
    checks.append(("wrong_bitstream_stops_at_P0", len(r2["steps"]) == 1))
    checks.append(("wrong_bitstream_zero_writes", writes == []))
    mem[IDX(R_ID)] = MAGIC

    # 场景三：全线钉低（2026-10-28 的读数形状）⇒ 退出码 1 ＋ 边界声明
    mode["bus"] = "stuck_low"
    r3 = {"steps": []}
    v3 = run(r3)
    checks.append(("stuck_low_verdict_1", v3 == 1))
    checks.append(("stuck_low_no_phy", r3.get("phy") is None))
    checks.append(("stuck_low_all_rows", len(r3.get("scan") or []) == 32))
    checks.append(("stuck_low_boundary", "MDIO 输入路径" in (r3.get("boundary") or "")))
    mode["bus"] = "phy7"

    # 场景四：写宽度坏 ⇒ 退出码 3，且不会去做 MDIO
    mode["width"] = "broken"
    r4 = {"steps": []}
    v4 = run(r4)
    checks.append(("width_fail_verdict_3", v4 == 3))
    checks.append(("width_fail_stops_at_P1", [s["step"] for s in r4["steps"]][-1] == "P1_write_width"))
    mode["width"] = "ok"

    # 场景五：页面已 enable（推流在跑）时，P1 先把它关掉再继续
    mem[IDX(R_ENABLE)] = 1
    r5 = {"steps": []}
    v5 = run(r5)
    checks.append(("enable1_verdict_0", v5 == 0))
    checks.append(("enable1_cleared", _rd(R_ENABLE) == 0))

    results = [{"check": k, "pass": bool(v)} for k, v in checks]
    print(json.dumps(results, ensure_ascii=False))
    print("selftest %s（%d/%d）" % ("PASS" if all(v for _, v in checks) else "FAIL",
                                    sum(1 for _, v in checks if v), len(checks)))
    for k, v in checks:
        if not v:
            print("  FAIL %s" % k)
    return 0 if all(v for _, v in checks) else 1


def device_selftest(path):
    """真实 DevMem 类（mmap＋ctypes 字数组）对着一个普通文件跑一遍，没有板子也能验取数路径。

    这一步只证明“32 位对齐读写在 Python 侧确实是一次字访问”这半条链；
    设备映射的强序语义与 /dev/mem 是否放行只有板上才算数，别把这里当板上验收。
    """
    import mmap as _m
    pagesize = _m.PAGESIZE
    aligned = REG_PAGE & ~(pagesize - 1)
    intra = REG_PAGE - aligned
    size = ((intra + 0x100) + pagesize - 1) & ~(pagesize - 1)
    with open(path, "r+b" if os.path.exists(path) else "wb") as fh:
        fh.truncate(aligned + size)
    dev = DevMem(path)
    global rd, wr
    rd, wr = dev.read, dev.write
    checks = []
    checks.append(("alignment_intra", intra == 0x200 if pagesize == 4096 else True))
    for reg, val in ((R_ID, MAGIC), (R_CAP, 7), (R_W, 1920), (R_H, 1080)):
        wr(reg, val)
    r = {"steps": []}
    verdict = run(r)
    steps = {s["step"]: s for s in r["steps"]}
    checks.append(("P0_pass", steps.get("P0_page_identity", {}).get("ok") is True))
    checks.append(("P1_pass_32bit", steps.get("P1_write_width", {}).get("ok") is True))
    checks.append(("P2_pass_reset", steps.get("P2_phy_reset", {}).get("ok") is True))
    checks.append(("P3_stops_at_deadline", "MDIO deadline" in (steps.get("P3_mdio_scan", {}).get("error") or "")))
    checks.append(("verdict_3", verdict == 3))
    checks.append(("words_persist_through_file", dev.read(R_H) == 1080))
    dev.close()
    with open(path, "rb") as fh:
        fh.seek(REG_PAGE + R_H)
        checks.append(("file_bytes_match", fh.read(4) == b"\x38\x04\x00\x00"))
    print(json.dumps([{"check": k, "pass": bool(v)} for k, v in checks], ensure_ascii=False))
    ok = all(v for _, v in checks)
    print("device_selftest %s（%d/%d，pagesize=%d, path=%s）"
          % ("PASS" if ok else "FAIL", sum(1 for _, v in checks if v), len(checks), pagesize, path))
    for k, v in checks:
        if not v:
            print("  FAIL %s" % k)
    return 0 if ok else 1


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    args = sys.argv[1:]
    if "--selftest" in args:
        return selftest()
    if "--selftest-device" in args:
        i = args.index("--selftest-device") + 1
        if i >= len(args):
            print("--selftest-device needs a file path", file=sys.stderr)
            return 4
        return device_selftest(args[i])
    if "--out" in args:
        i = args.index("--out") + 1
        if i >= len(args):
            print("--out needs a path", file=sys.stderr)
            return 4
        out = args[i]
    else:
        out = None
    report = {"steps": [], "tool": "read_phy_identifiers_v2", "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    dev = DevMem()
    global rd, wr
    rd, wr = dev.read, dev.write
    try:
        verdict = run(report)
    finally:
        dev.close()
    text = json.dumps(report, ensure_ascii=False, indent=1)
    print(text)
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return verdict


if __name__ == "__main__":
    sys.exit(main())
