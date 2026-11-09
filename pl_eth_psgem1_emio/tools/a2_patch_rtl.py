#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A2 步骤③：给工程副本的三层 RTL 打上 PL 网口透传补丁。

只动 workenv/pl_eth/proj_trial/ 里的副本，厂商原件一个字节不碰。
每条锚点必须恰好命中一次，否则整体不落笔（不产生半套改动）。
可重复跑：文件里已有 WCIS-PL-ETH A2 标记就跳过并报告。
行尾按原文件保留（ps_ai_wrapper.sv／ps_ai_peripheral.sv 是 CRLF）。
"""
import sys
import os

MARK = "WCIS-PL-ETH A2"
RTL = r"S:\work\WCIS\workenv\pl_eth\proj_trial\fpai_demo_fpga\rtl"
F_WRAP = os.path.join(RTL, "ps_ai_wrapper.sv")
F_PERI = os.path.join(RTL, "ps_ai_peripheral.sv")
F_TOP = os.path.join(RTL, "ai7030_edif_top.v")

# 九根新端口（顶层／peripheral／wrapper 三层同名，XDC 绑的就是这一组名字）
PORTS = [
    "  output                 RGMII_0_txc           ,",
    "  output                 RGMII_0_tx_ctl        ,",
    "  output      [  3 : 0]  RGMII_0_td            ,",
    "  input                  RGMII_0_rxc           ,",
    "  input                  RGMII_0_rx_ctl        ,",
    "  input       [  3 : 0]  RGMII_0_rd            ,",
    "  output                 MDIO_PHY_0_mdc        ,",
    "  inout                  MDIO_PHY_0_mdio_io    ,",
    "  output      [  0 : 0]  phy_reset_n            ",
]

# BD(ps_ai) 实例上要多连的 11 个端口连接（MDIO 三态在此层拆开）
CONNS = [
    "  .RGMII_0_txc                        (RGMII_0_txc                        ),",
    "  .RGMII_0_tx_ctl                     (RGMII_0_tx_ctl                     ),",
    "  .RGMII_0_td                         (RGMII_0_td                         ),",
    "  .RGMII_0_rxc                        (RGMII_0_rxc                        ),",
    "  .RGMII_0_rx_ctl                     (RGMII_0_rx_ctl                     ),",
    "  .RGMII_0_rd                         (RGMII_0_rd                         ),",
    "  .MDIO_PHY_0_mdc                     (MDIO_PHY_0_mdc                     ),",
    "  .MDIO_PHY_0_mdio_i                  (MDIO_PHY_0_mdio_i                  ),",
    "  .MDIO_PHY_0_mdio_o                  (MDIO_PHY_0_mdio_o                  ),",
    "  .MDIO_PHY_0_mdio_t                  (MDIO_PHY_0_mdio_t                  ),",
    "  .phy_reset_n                        (phy_reset_n                        )",
]

# 上面两层（peripheral／edif_top）只透传 wrapper 的对外端口：
# 三态已在 wrapper 里用 IOBUF 合掉，外面只剩 mdc ＋ inout 的 mdio_io。
CONNS_TOP = [
    "  .RGMII_0_txc                        (RGMII_0_txc                        ),",
    "  .RGMII_0_tx_ctl                     (RGMII_0_tx_ctl                     ),",
    "  .RGMII_0_td                         (RGMII_0_td                         ),",
    "  .RGMII_0_rxc                        (RGMII_0_rxc                        ),",
    "  .RGMII_0_rx_ctl                     (RGMII_0_rx_ctl                     ),",
    "  .RGMII_0_rd                         (RGMII_0_rd                         ),",
    "  .MDIO_PHY_0_mdc                     (MDIO_PHY_0_mdc                     ),",
    "  .MDIO_PHY_0_mdio_io                 (MDIO_PHY_0_mdio_io                 ),",
    "  .phy_reset_n                        (phy_reset_n                        )",
]

IOBUF = [
    "  // " + MARK + " begin: 手抄 wrapper 不带这颗，编译路径上 MDIO 的三态由这里合",
    "  wire MDIO_PHY_0_mdio_i;",
    "  wire MDIO_PHY_0_mdio_o;",
    "  wire MDIO_PHY_0_mdio_t;",
    "  IOBUF MDIO_PHY_0_mdio_iobuf (",
    "    .I(MDIO_PHY_0_mdio_o),",
    "    .IO(MDIO_PHY_0_mdio_io),",
    "    .O(MDIO_PHY_0_mdio_i),",
    "    .T(MDIO_PHY_0_mdio_t));",
    "  // " + MARK + " end",
]


def load(path):
    raw = open(path, "rb").read()
    eol = "\r\n" if raw.count(b"\r\n") > raw.count(b"\n") // 2 else "\n"
    text = raw.decode("utf-8")
    if eol == "\r\n":
        text = text.replace("\r\n", "\n")
    return text, eol


def save(path, text, eol):
    if eol == "\r\n":
        text = text.replace("\n", "\r\n")
    open(path, "wb").write(text.encode("utf-8"))


def sub_once(text, old_lines, new_lines, what, eol):
    o = "\n".join(old_lines)
    n = "\n".join(new_lines)
    c = text.count(o)
    if c != 1:
        raise SystemExit("ABORT %s: 锚点命中 %d 次（要 1 次）" % (what, c))
    return text.replace(o, n)


def check_new_names(text, path):
    for name in ["RGMII_0_txc", "MDIO_PHY_0_mdio_io", "phy_reset_n"]:
        if name in text:
            raise SystemExit("ABORT %s: 文件里已经有 %s，名字会撞" % (path, name))


def patch_wrap():
    text, eol = load(F_WRAP)
    if MARK in text:
        return "skip(已打过)"
    check_new_names(text, F_WRAP)
    # 1) 模块端口表尾
    text = sub_once(text, ["    output                clk_200mhz", "    );"],
                    ["    output                clk_200mhz          ,",
                     "    // " + MARK + " begin",
                     ] + PORTS + [
                     "    // " + MARK + " end",
                     "    );"], "wrapper 端口表", "\n")
    # 2) IOBUF 放在 ps_ai 实例前面
    text = sub_once(text, ["ps_ai ps_ai_i("], IOBUF + ["", "ps_ai ps_ai_i("],
                    "IOBUF", "\n")
    # 3) ps_ai_i 端口连接表尾
    text = sub_once(text,
                    ["  .reset_n                            (reset_n                            ),",
                     "  .soft_rst_n                         (soft_rst_n                         )",
                     ");"],
                    ["  .reset_n                            (reset_n                            ),",
                     "  .soft_rst_n                         (soft_rst_n                         ),",
                     "",
                     "  // " + MARK + " begin",
                     ] + CONNS + [
                     "  // " + MARK + " end",
                     ");"], "ps_ai_i 连接", "\n")
    save(F_WRAP, text, eol)
    return "ok (eol=%s)" % ("CRLF" if eol == "\r\n" else "LF")


def patch_peri():
    text, eol = load(F_PERI)
    if MARK in text:
        return "skip(已打过)"
    check_new_names(text, F_PERI)
    text = sub_once(text, ["  input                  User_Ddr_rready", ");"],
                    ["  input                  User_Ddr_rready       ,",
                     "  // " + MARK + " begin",
                     ] + PORTS + [
                     "  // " + MARK + " end",
                     ");"], "peripheral 端口表", "\n")
    text = sub_once(text,
                    ["    .clk_200mhz                (clk_200mhz               )    ",
                     "    );"],
                    ["    .clk_200mhz                (clk_200mhz               ),",
                     "",
                     "    // " + MARK + " begin",
                     ] + [l.replace("  ", "    ", 1) for l in CONNS_TOP] + [
                     "    // " + MARK + " end",
                     "    );"], "ps_ai_wrapper_u0 连接", "\n")
    save(F_PERI, text, eol)
    return "ok (eol=%s)" % ("CRLF" if eol == "\r\n" else "LF")


def patch_top():
    text, eol = load(F_TOP)
    if MARK in text:
        return "skip(已打过)"
    check_new_names(text, F_TOP)
    text = sub_once(text, ["  output                 PJTAG_TDO                 ", ");"],
                    ["  output                 PJTAG_TDO                 ,",
                     "",
                     "  // " + MARK + " begin",
                     ] + PORTS + [
                     "  // " + MARK + " end",
                     ");"], "顶层端口表", "\n")
    text = sub_once(text,
                    ["  .User_Ddr_rready        ( User_Ddr_rready    ) ",
                     ");"],
                    ["  .User_Ddr_rready        ( User_Ddr_rready    ),",
                     "",
                     "  // " + MARK + " begin",
                     ] + CONNS_TOP + [
                     "  // " + MARK + " end",
                     ");"], "U0_ps_ai_peripheral 连接", "\n")
    save(F_TOP, text, eol)
    return "ok (eol=%s)" % ("CRLF" if eol == "\r\n" else "LF")


def main():
    for f in (F_WRAP, F_PERI, F_TOP):
        if not os.path.isfile(f):
            raise SystemExit("ABORT 找不到文件 " + f)
    print("ps_ai_wrapper.sv    :", patch_wrap())
    print("ps_ai_peripheral.sv :", patch_peri())
    print("ai7030_edif_top.v   :", patch_top())
    for f in (F_WRAP, F_PERI, F_TOP):
        b = open(f, "rb").read()
        print("%-22s %9d B  CRLF=%d  A2标记=%d" % (os.path.basename(f), len(b),
                                                   b.count(b"\r\n"),
                                                   b.decode("utf-8", "replace").count(MARK)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
