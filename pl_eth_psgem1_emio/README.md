# pl_eth_psgem1_emio — PL 侧以太网口（路线 A2：PS GEM1 经 EMIO 透传）脚本与改动快照

FMQL30TAI676H「悟净」板上那颗接在 PL 侧的 YT8521：走 **PS GEM1 → EMIO → `GMII_to_RGMII` v4.0 → PL 引脚** 这条路线（内部代号 **A2**）。

本目录只放**可重跑的脚本**与**改动后的源码快照**，不放工程树、不放日志、不放位流。工程副本（533 MB）与全部证据日志都留在 `S:\work\WCIS\workenv\pl_eth\`（`workenv/` 永久排除，不进任何库）。

## 目录

| 目录 | 放什么 |
|---|---|
| `tcl/` | Vivado 批处理脚本（`-mode batch -source`），按 `stageNN` 顺序对应做事的顺序 |
| `xdc/` | 顶层约束：`pl_eth_routeA.xdc` 是正本；`pl_eth_placeholder.xdc` 是 10-30 那个只有脚位骨架的旧版，留作对照 |
| `rtl_a2_patched/` | A2 透传改动**之后的**三份厂商 RTL ＋ 改动时的 md5 记录。**不是厂商原件**，原件在 `S:\apps\llm\agentwork\fpga-src\fpai_demo_fpga\`，那边一个字节没动 |
| `tools/` | Python：补丁器、板端只读探测、PHY 诊断（后者未上板跑过） |
| `host/` | 宿主机侧一次性脚本（PC 网卡取证/恢复、工程查找与复制），只作过程留证 |

## tcl/ 各脚本干什么

| 脚本 | 作用 ／ 判据 |
|---|---|
| `pinbank.tcl` | 查 15 个脚落在哪个 bank、`PIN_FUNC` |
| `trial_enet1.tcl` | 最早那次只读试验：改 ENET1 参数 → 看接口 → `validate` → **不保存**退出 |
| `stage2_fclk_ip.tcl` | 基线留档 → 试改 FCLK1/2 → 装 `GMII_to_RGMII` → 打参数与端口 |
| `stage3_apply_save.tcl` | PS7 ENET1+EMIO、装转换核并配置、连 GMII/MDIO、接复位、RGMII 引顶层、`validate`、保存 |
| `stage4_clkin.tcl` | 补 `clk_wiz_eth`（50→200 MHz）喂 `clkin`，`validate` rc=0 |
| `stage5_ports.tcl` / `stage6_rgmii_pins.tcl` | 查 BD 端口与接口内部引脚（接口级查询拿不到，这条结论促成了 `stage7`） |
| `stage7_wbd.tcl` | `write_bd_tcl` 导出当前 BD（`bd_current.tcl`，本目录未收，可重生成）——查端口名最可靠的一手 |
| `stage8_gen.tcl` | `generate_target all`，rc=0，看重生成后的 wrapper 端口 |
| `stage9a_probe_state.tcl` | 只读探针：本 BD 有没有引出 PS7 EMIO GPIO（结论：没有） |
| `stage9b_mdio_ext.tcl` | **把 `MDIO_PHY` 与 PHY 复位引到 BD 外部**并重生成 wrapper（端口名在这一步才定下来） |
| `stage9c_fileset_probe.tcl` | 查 `.xpr` 的 `sources_1` 到底编译哪份 wrapper（结论：厂商手抄件，不是自动件） |
| `stage10_a2_synth.tcl` | 内存里摊平 `synth_design` ⇒ 撞 `Synth 8-439`。**这条路在本工程设计上不成立**，留作反例 |
| `stage11_reset_gen.tcl` | `reset_target`＋`generate_target all`：复现同一套 `_1` 目录布局，证明不是脏状态 |
| `stage12a_addfiles_probe.tcl` | 试 `add_files` 把 BD 生成源挂进 `sources_1`：`filemgmt 20-1440` 拒绝 |
| `stage13_launch_synth.tcl` | 正规 `launch_runs synth_1`：自动补建 7 个缺失 OOC run，顶层综合 **0 Errors** |
| `stage14_xdc_check.tcl` | 第一版 XDC 复校 ⇒ 抓出 4 条 `Vivado 12-4739`（发送时钟引用不到） |
| `stage15_txclk_probe.tcl` | 综合后网表的对象读数：端口方向、IOBUF 路径、转换核是 OOC 黑盒、`*rgmii_txc_out*` 零命中 |
| `stage16_xdc_recheck.tcl` | 修完的 XDC 两趟复校（裸网表 / 预置发送时钟），都要求 0 ERROR |
| `stage17_roundtrip.tcl` | 把约束 `write_xdc` 反写出来，逐条数 in/out delay 是否真落上 |

## 复跑

```bash
cd /s/work/WCIS/workenv/pl_eth
"/s/apps/Xilinx/Vivado/2018.3/bin/vivado.bat" -mode batch -nojournal -nolog -notrace \
  -source "S:/work/WCIS/workenv/pl_eth/stage13_launch_synth.tcl"
```

要点（都是踩出来的，别绕）：

1. **只能走 `launch_runs`**。BD 里的 IP 是 OOC 产物，内存里摊平 `synth_design` 会报 `Synth 8-439`；`add_files` 挂生成源也被 `filemgmt 20-1440` 拒。缺 OOC run 时 Vivado 会自己补建，别手工造。
2. **顶层 XDC 不许引用 IP 内部对象名**（`rgmii_txc_out`、`i_bufgmux_gmii_clk`、`gmii_clk_125m*`）：综合后顶层网表里 BD 每颗 IP 连 PS7 自己都是未连入的黑盒。只能"取"传播出来的钟，取不到要明确 WARN，别留静默失效的 `set_output_delay -clock <空>`。
3. **负数 delay（−1.5／−2.8）相对虚拟时钟**量，配套 4 条 false path ＋ 2 条 multicycle 必须一起搬；只搬 delay 等于把 PHY 内部约 2 ns 移位算两遍。
4. 改 RTL 前先跑 `tools/a2_patch_rtl.py`（锚点不唯一即中止），它按原样重打三份文件；原件与改后 md5 记在 `rtl_a2_patched/a2_rtl_md5_before_stage11.txt`。

## 状态（截至 2026-11-06）

- 副本内已完成：BD 改完（ENET1+EMIO、转换核、`clk_wiz_eth`、`gmii_rst_inv`、MDIO／复位引外部）→ 三层 RTL 透传 → **整板综合 0 Errors** → 实名顶层 XDC **两趟复校 0 ERROR**。
- 未做：**一次实现都没跑过**（布线、时序、时钟余量、顶层约束是否与 IP scoped 约束重复，全零读数）；**位流没出**；**板子没碰**。
- 只有原理图能定的三件仍未定：Bank12/13 的 VCCO（现在全按 `LVCMOS18` 占位）、YT8521 的 MDIO 地址 strapping、AA13 复位极性与由谁驱动（现为 `xlconstant` 恒 1 的占位）。

## 证据与文档

- 证据日志（`stage*.log`、`runme.log`、`xvlog_a2.log`、`a2_xdc_rt_pass2.xdc`）：`S:\work\WCIS\workenv\pl_eth\`，不入库。
- 正本文档：`S:\work\WCIS\wiki\PL\FPGA\PL网口bring-up与GEM1EMIO.md`（做事的全部读数，第 12.1.1 节是本轮）、`S:\work\WCIS\wiki\PL\pl_eth_psgem1_emio.md`（路线与待裁）。
- 厂商工程原件：`S:\apps\llm\agentwork\fpga-src\fpai_demo_fpga\`（**勿改**）。
