# sdi-cap — 悟净 FMQL30TAI 单路 HD-SDI 数据搬运通路

SDI 口进来的像素流，**原样连续写进 PS DDR**，Linux 侧软件直接映射读取。

| 项 | 值 |
|---|---|
| 器件 | `xc7z030ffg676-2`（复旦微 FMQL30TAI，Zynq-7000 级） |
| 顶层 | `sdi_cap_top` |
| 工具 | Vivado 2018.3（本机 `S:\apps\Xilinx\Vivado\2018.3`） |
| 输入 | 1 路 HD-SDI，SMPTE 292M |
| 落点 | PS DDR；寄存器走 **GP1** @ `0x8000_0000`，帧数据走 **`S_AXI_HP2`**（PL 当主机，64 bit） |

> **收档（2026-10-16）**：交付件 + 证据 + 厂商调研原件的只读快照在
> `S:\work\WCIS\FPGA HD-SDI to PS Video Capture Card\`；wiki 收口页是
> 《SDI到PS的数据搬运（厂商参考与设备事实）》。**本目录仍是权威副本**，
> 快照随此后改动不再自动同步。

---

## 这个块做什么 / 不做什么

**做**：SDI 口进来什么像素，就往 PS DDR 写什么像素。帧和帧之间连续，中间没有空洞。

**不做**（刻意不做，不是没做完）：

- 不判断格式、不判制式
- 不按帧率门控、不丢帧
- 不等一行收满、不等一帧收满才写
- 不缩放、不转色彩空间、不滤波
- **接收器没锁定也照写**——黑屏时软件仍然能拿到原始字节流，
  并且从寄存器就能分辨是"没信号"、"没锁定"、"认不出格式"还是"像素在进但没人读"

> 最初版本做成了"采集卡"：幅面要配 1920×1080、帧率要选 25/30、不匹配就丢帧、
> 还要等 `sig_locked` 才开火。结果是**源端格式认不出就什么都不给 PS，黑屏**。
> 而"黑屏"恰恰是排障时最需要看到数据的情况。见 `docs/设计说明.md` 第一节。

---

## 目录

```
sdi-cap/
├── build.bat / build.tcl         一键编译
├── rtl/
│   ├── sdi_cap_top.v             顶层：接收链 -> 测量 -> 打包 -> 异步 FIFO -> 写帧器
│   ├── sdi_cap_ps.v              PS7 封装 + 时钟；S_AXI_HP2（PL 主机）+ M_AXI_GP1（寄存器）
│   ├── cap/                      ← 自研核心 RTL，6 个模块
│   │   ├── sdi_cap_meas.v        幅面/帧周期测量（不筛选）
│   │   ├── sdi_px_pack.v         4 像素拼 1 拍 64 bit，帧首打标记位
│   │   ├── sdi_px_afifo.v        双时钟 FIFO（65 bit × 1024 = 8 KB）
│   │   ├── sdi_stream_wr.v       AXI4 主机（HP2，64 bit），连续写环形缓冲
│   │   ├── sdi_cap_regs.v        AXI4-Lite 控制/状态（GP1）
│   │   └── sdi_cap_cdc.v         CDC
│   └── vendor/                   复用
│       ├── sdi/                  厂商 SDI 接收链（含新增的 y422_* 端口）
│       │   ├── dru.edf           SD 速率 DRU 的加密实现（必须加进工程）
│       │   └── ip/smpte_sdi      AMD SMPTE SD/HD/3G-SDI（PG071 v3.0）
│       └── ip/{ps7,clk_wiz_0}   PS7 IP + 时钟 IP
├── constrs/
│   ├── sdi_cap.xdc               通用约束
│   ├── gt_refclk_lite.xdc        GT 参考时钟：R6/R5（厂商交付包里生效的那对）
│   └── gt_refclk_full.xdc        GT 参考时钟：U6/U5
├── sim/
│   ├── run_bench.ps1             仿真入口：像素链 + 寄存器块两条测试台（行为级）
│   ├── run_gl_bench.ps1/.bat     门级入口：综合后网表 + UNISIM 原语跑同一个像素链
│   ├── tb_sdi_stream_wr.v        像素链（pack -> afifo -> writer -> HP2 从模型）
│   └── tb_sdi_cap_regs.v         CSR 块（真实 AXI4-Lite 主模型，52 项检查）
├── ps/
│   ├── sdi_cap.h                 寄存器定义
│   └── sdi_cap.c                 驱动 + demo（-DSDI_CAP_DEMO）
├── docs/
│   ├── 调研与选型.md             ← FPGA 采集卡项目调研（§9 附厂商 SDI→PS 协议对照）
│   ├── AXI速率实测.md            带宽核算 + 19 个仿真套件 + 判据（历史节保留 32 bit 版数据）
│   ├── 设计说明.md               架构、带宽核算、踩坑记录（§6 有 27 小节：6.1–6.26 + 6.11b）
│   ├── 寄存器手册.md             完整寄存器表
│   └── 上板检查.md               上板步骤与排障判据
└── dist/                         编译产物（.bit + 报告）
```

## 编译

```bat
build.bat              :: 完整编译（综合 + 实现 + 出位流）
build.bat synth        :: 只综合，快速验证
build.bat full         :: 用 U6/U5 那对 GT 参考时钟引脚
```

`BOARD_VARIANT` 为什么重要：这块板只有一个 GT bank，PCIe/SFP/SDI/SMA 共用，
靠跳线片选。GT 参考时钟引脚有两对，选错 = GT 拿不到参考时钟 = SDI 永远 0 帧。
厂商交付包里生效的是 **lite**（`R6/R5`），所以默认就是 lite。

## 仿真

```powershell
cd sim
powershell -ExecutionPolicy Bypass -File run_bench.ps1          # 默认扫描（B_LAT + REGS）
powershell -ExecutionPolicy Bypass -File run_bench.ps1 -Full    # 19 个像素套件 + REGS 全跑
powershell -ExecutionPolicy Bypass -File run_bench.ps1 -Only REGS
run_gl_bench.bat 200000                                          # 门级：综合后网表（慢，几分钟）
```

三条链，被测对象不同：

| 测试台 | 被测 | 套件 | 判据 |
|---|---|---|---|
| `tb_sdi_stream_wr.v` | `sdi_px_pack` → `sdi_px_afifo` → `sdi_stream_wr` → HP2 从设备模型 | 19 条：`B_LAT_*` / `W_LAT_*` / `RING_*` / `PX_*` / `RST_MID` | `data marker frames axi ring drain quiet ovf` 全 PASS |
| `tb_sdi_cap_regs.v` | `sdi_cap_regs`（CSR）+ 真实 AXI4-Lite 主模型 | 1 条：`REGS`（52 项检查） | `REGS RESULT: PASS` |
| `run_gl_bench`（门级） | 综合后 `sdi_stream_wr` 网表 + UNISIM 原语，跑 `B_LAT_32` 同一套 | 1 条 | `data/axi/ring/drain/quiet/ovf` 全 PASS，数字与行为级逐项相同（`设计说明.md` §6.13）|

第二条几十秒就能跑完，**第一次跑就抓出三个 CSR 级 bug**（`设计说明.md` §6.23–§6.25：
`ARREADY` 死锁、`FPS_X100` 恒 0、`CTRL` 读回位号错 + `ROW_BYTES` 少一半）。
它用的是真实握手 —— VALID 举两拍、等到 BVALID/RVALID 回来才撤 READY、每个等待都带
超时并报 FAIL —— 所以"一读寄存器就死锁"这种故障跑一次就现形，不用等上板。

第三条（门级）要综合 + 编 UNISIM，几分钟才出结果：同一个测试台、同一份 bench.txt，
只把写帧器换成网表，数字与行为级逐项对照 —— 它就是 `设计说明.md` §6.12/§6.13
那个"FIFO 落点"悬案的定案工具。

> 三条教训合成一句：**综合过、DRC 过、时序过，和功能对之间还隔着一次仿真。**
> 这三个 bug 都不影响出位流，也不影响时序报告。

## PS 侧

```c
#include "sdi_cap.h"

sdi_cap_t cap;
sdi_cap_open(&cap, ring_pa, ring_len);
sdi_cap_start(&cap, ring_pa, ring_len);   /* 没有幅面参数、没有帧率参数 */
/* 轮询 sdi_cap_get_info() 看实测值，sdi_cap_grab() 取帧 */
```

板上编译（板上有 gcc，不需要容器）：

```sh
gcc -O2 -DSDI_CAP_DEMO -o demo sdi_cap.c
./demo 10 frame.pgm 0x<udmabuf 的物理地址> 33554432
```

`ring_phys_addr` **必须**是用户态导出的 udmabuf。这里没有安全的默认值：
PS DDR 只有 1 GB 而且内核住在里面，写死一个物理地址很可能踩到在用的内存，
而且失败现象是一帧莫名其妙的花屏而不是报错。导出方法见
`docs/上板检查.md` 和 `sdi_cap.c` 顶部注释。

## 上板前必查

1. **跳线**：J26 的 `GTX_LANE_SEL0~3` 接高（选 SDI），J27 选 148.5M 进 CLK1
   （手册 §4.5 / §4.22）。**这一步用眼睛查。**
2. **先不用改 OBS**。新设计不依赖它做对：不管源是 CVBS 还是格式不对，
   只要 GT 出得了数据就会写进 PS DDR，从寄存器就能判断是哪一种情况。
3. **换位流**：板上三条运行时重载通道已实测全部失效，
   只能 **BOOT.bin 替换 + 重启**。本轮可直接换的镜像：
   `S:\work\WCIS\sdi-cap\dist\BOOT_sdi_cap_20261015_230629.bin`（md5 `03AB070C…`，
   拼法与交叉核对见 `docs/上板检查.md` §二）。
4. **看灯**：`led[1]`=M6 是 SDI 传输帧锁定（`rx0_locked`，锁定常亮），
   `led[0]`=J1 是恢复时钟心跳（`rx_usrclk_cnt[25]`，慢闪）。
   与厂商 `LED_MON=1` 同向；2026-10-16 更正，此前写反。
   这是厂商留的调试指示，第一步就该看。

## 自研 RTL 有多少

**6 个模块 + 2 个封装文件**：

| 模块 | 做什么 |
|---|---|
| `sdi_cap_meas` | 实测有效幅面和帧周期；不筛选、不门控 |
| `sdi_px_pack` | 4 像素拼 1 拍（64 bit），帧首打标记位 |
| `sdi_px_afifo` | 65 bit × 1024 双时钟 FIFO，跨 `cam_clk` → `clk_100m` |
| `sdi_stream_wr` | AXI4 主机（`S_AXI_HP2`，64 bit），多突发流水拖环形缓冲 |
| `sdi_cap_regs` | AXI4-Lite 控制/状态寄存器（`M_AXI_GP1`） |
| `sdi_cap_cdc` | CDC（单 bit 电平 / 多 bit 总线） |

外加 `sdi_cap_top.v`（接线）和 `sdi_cap_ps.v`（PS7 封装、时钟、两个 AXI 口）。

SDI 接收链（GT、`smpte_sdi` IP、帧转换、状态测量）是**复用**的，
只做了一处**加法式**改动：`frame_convertor` 本就在产的 4:2:2（`img_Y`/`img_CbCr`）
经 wrapper `rx_sdi.v` 引出为 `y422_*` 输出（16 bit 4:2:2），不动原有逻辑。

### 为什么 AXI 主机不在像素时钟域

`cam_clk` 是"恢复了锁就用恢复时钟、失锁就切 100 MHz 兜底"这样来的
（厂商 `rx_sdi.v:395`）。把 AXI 接口压在这个时钟上，**在途事务期间换频 = 挂死**
（厂商文档 L3/L4 那类）。所以 AXI 侧跑常驻的 `clk_100m`，像素只跨一次域。
代价是多一个异步 FIFO（2 × RAMB36），换来的是"像素时钟怎么变都不影响 AXI 正确性"。
见 `设计说明.md` §3.2 / §6.18。

## 已知限制

- **位流加载只能靠 BOOT.bin 替换 + 重启**，运行时重载三条通道已实测失效。
- **上板验证尚未做**（本轮交付到出位流为止）。
- **`WR_IDLE=1` 不等于 FIFO 空**：停源时最多 15 拍（120 字节）会合法地留在 FIFO 里 ——
  那是一个没发完的突发。判空握手（复位前用）看的是"没有在途事务"，见
  `docs/寄存器手册.md` §一点五。
- **多 bit 状态值没有快照握手**：`BEATS`/`FRAME_CNT`/`FRAME_ADDR`/`WR_ADDR`
  从 `clk_100m` 域直连进 `fclk0_clk` 的寄存器块，理论上可能读到"正在变化"的组合。
  软件侧应当**读两次比对**，或者只在 `IDLE=1` 时读。单 bit（`WR_IDLE`）没这个问题。
- 环形缓冲回绕时读帧要按行处理跨环尾，`sdi_cap_grab()` 已经处理了；
  如果软件读得比 PL 写得慢，旧帧会被覆盖（`ERR.FIFO_FULL` 会置位）。
- 帧边界只记录在 `FRAME_ADDR`（精度 ≤ 1 拍 = 8 字节），PL 不切帧，
  帧长由软件按 `MEAS_W`/`MEAS_H` 算。