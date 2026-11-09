# FPGA HD-SDI → PS 视频采集卡（收档）

> **任务名**：FPGA实现HD-SDI至PS视频采集卡（复旦微 FMQL30TAI「悟净」板，PS7 按 `xc7z030ffg676-2` 档配置）
> **本目录是收档快照**：交付件 + 证据 + 调研原件。**工程本体（可编译的权威副本）在**
> `S:\work\WCIS\sdi-cap`（2026-10-16 由 `S:\apps\llm\agentwork\sdi-cap` 迁入）——
> 要重编译、要改，都回那里做；本目录只当"交出去的那一包"。
> **Wiki 收口页**：《SDI到PS的数据搬运（厂商参考与设备事实）》（`S:\work\WCIS\wiki\md\技术文档\`）。

一句话：把板上厂商 SDI 接收链解出来的像素**不看格式、不判帧率、不丢帧（仅 FIFO 满时整拍丢弃）**
地连续搬进 PS DDR。RTL + 寄存器 + PS 驱动 + 位流已出；构建、行为级仿真、门级仿真全部跑完，
**上板尚未做**。

## 目录

| 目录 | 内容 |
|---|---|
| `bitstream/` | 交付位流 + BOOT.bin 候选 |
| `ps/` | PS 驱动 `sdi_cap.c/.h` + 语法检查脚本 |
| `docs/` | 五份文档：`调研与选型.md`、`AXI速率实测.md`、`设计说明.md`、`寄存器手册.md`、`上板检查.md` |
| `evidence/` | 仿真、构建、探针、拼装校验、编译检查的**原始输出**（清单见下） |
| `research/` | 厂商调研原件：HP 客户说明 PDF + ModelScope 下载件 |
| `src/` | 自研源码与配置**快照**（权威副本在工程本体；含唯一被改过的厂商文件 `rx_sdi.v`） |
| `tools/` | BOOT.bin 拼装/校验脚本（`boot-splice.py` 等） |

## 交付件身份（2026-10-15/16 核对）

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `bitstream/sdi_cap_lite_20261015_230629.bit` | 5,980,025 B | `01712DB8DE9329ABB4706781A83AFB19` | hp2d 构建的交付位流；WNS 2.388 / WHS 0.049 / WPWS 1.100；DRC 0 错 25 警 |
| `bitstream/BOOT_sdi_cap_20261015_230629.bin` | 7,023,040 B | `03AB070C241D17C5BC912EE713CD81E8` | BOOT.bin 候选：由 `board_BOOT.bin`（md5 `ACA4612B566738350A8C5EDAC0DB1929`）在槽 `0x2D9F0` 换入新位流载荷，未上板 |
| （参照，不在本目录）| 7,023,040 B | `0F4F00E1DE0AF8F70299572BE622E45A` | 已知-good 参照 `BOOT_status_export.bin`，用于交叉核对拼接产物结构 |
| （参照，不在本目录）| — | `ACA4612B566738350A8C5EDAC0DB1929` | 拼接用模板 `board_BOOT.bin`（板子现役镜像导出的同级文件） |

## 已验证 / 未验证

**已验证**（每条在 `evidence/` 里都有原始输出）：

- **行为级**：19 套件 + 寄存器 52 项检查全 PASS（`sim_run_full_hp2d.txt`；含 `B_LAT_*` 突发延迟档、`W_LAT_*`、`PX_*` 频点/占空档）
- **门级**（综合后网表 + UNISIM，含真实 RAMB 模型）：与行为级 `B_LAT_32` **逐项相同** ——
  150.91 MB/s（1080p30 需求的 121.3%）、beats/wlast/aw = 37728/2358/2312、帧数 140、
  排空水位 9（`sim_run_gl_B_LAT_32.log`、`sim_run_gl_hp2d.txt`）
- **布线后网表探针**：HP2/GP1 引脚方向、CDC 信号驱动+负载（`probe6_netlist_acceptance.log`）；
  FIFO 落点 = 2×`RAMB36E1`（`probe_ramb.log`，`LUT as Distributed RAM = 0`）
- **构建验收**：`build_impl_hp2d.log` + 布线后报告（时序/DRC/利用率），DRC 0 错误
- **BOOT.bin 拼装可复现**：重跑拼装 md5 一致、槽外字节不动、槽内 == 换字节序后的新载荷（`boot_splice_verify.txt`）
- **驱动语法级编译干净**：x86-64 主机 gcc（WSL Ubuntu 15.2.0），`ALL CLEAN`（`arm_compile_check.txt`）
  —— 注意这只是**语法/告警级**，不是 aarch64 真编译

**未验证**（上板才做）：

- 位流在板上的实际运行、SDI 锁定、寄存器读数、驱动的收发
- 换 BOOT.bin 后能否正常开机（判读见 `docs/上板检查.md` 第三节；**LED 映射：M6=`rx0_locked`=锁定，J1=恢复时钟心跳**，2026-10-16 更正）
- aarch64 侧编译与运行驱动

## 复现入口（在工程本体 `S:\work\WCIS\sdi-cap` 里）

| 要干什么 | 命令 |
|---|---|
| 出位流 | `build.bat`（Vivado 2018.3，自动打器件库补丁） |
| 行为级全跑 | `sim\run_bench.ps1 -Full` |
| 门级定案 | `sim\run_gl_bench.bat` |
| 拼 BOOT.bin | `tools\boot-splice.py <new.bit> <BOOT模板> <out> --slot 0x2D9F0 --size 5979868` |
| 上板 | `docs/上板检查.md`（先换 BOOT.bin → 先看灯 → 再动软件） |

## 注意

1. `src/` 是快照，可能与工程本体后续演进而不同步；**以工程本体为准**。
2. 厂商文件只改过一个：`rx_sdi.v`（加法式 `y422_*` 输出 + `cam_clk` 兜底 100 MHz）。
   差异见 `evidence/rx_sdi_y422_patch.diff`；其余厂商 RTL 与交付包逐字节相同。
3. `research/` 的 HP 客户说明是 2026-10-12 的 11 页 PDF 副本，正本在
   `S:\work\WCIS\fdw\PS-PL_AXI_HP_事务计数与复位语义.pdf`。
4. `research/modelscope/` 的文件名把原路径里的 `/` 换成了 `__`（下载器产物），
   文件名即来源路径。
5. 本目录**未做**上板验证；"已验证/未验证"的分界线以本节为准，不要外推。
