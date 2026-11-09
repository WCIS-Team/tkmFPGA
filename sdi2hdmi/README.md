# sdi2hdmi

SDI → HDMI 转换器。纯 PL，目标板 **FMQL30TAI**（复旦微，器件 `xc7z030ai`）。

```
SDI 子板 ──GT──> smpte_sdi ──> YCbCr422 ─> RGB888 ─> scaler_720 ─> 行槽 CDC ─> 720p60 光栅 ─> TMDS ─> HDMI
```

## 为什么另起一个工程

厂商交付 `S:\work\WCIS\fdw\20260916\fpai_demo_fpga` 里已经有 SDI → HDMI，
但那条路是 `SDI → AXI → PS DDR → PS → 显示缓冲 → HDMI`——一张纯视频的图绕 CPU 走一整圈。
代价是 **MMCM 5/5 用满、WNS 只剩 +0.072 ns**。本设计全程留在 PL 里，**只用 3 个 MMCM**。

另一条结论：**厂商 demo 实际输出的是 1080p60 / 742.5 MHz TMDS**，
正是手册说会闪屏的那一档（HR bank 上限 710 MHz）。本设计输出 **720p60 / 371.25 MHz TMDS**。
推导见 `doc/01-architecture.md` 第二节。

## 状态

| 段 | 状态 |
|---|---|
| 设计 | ✅ 见 `doc/01-architecture.md` |
| 仿真 | ✅ `scaler_720` 对独立黄金模型逐像素比对，1280×720 透传与 1920×1080 缩放两例全过 |
| 仿真 | ✅ `hdmi_out` 自检测试台：14 帧 / 12 902 417 像素，光栅时序、同步极性、CDC 完整性、背压**全部 0 错** |
| 仿真 | ✅ **端到端**：真实 2200×1125 源 → `scaler_720` → `hdmi_out` → 720p60 光栅，逐像素匹配黄金模型，稳态 **720 行 / 720 取行 / 0 丢弃** |
| 仿真 | ✅ **真实视频**（校机 Verilator）：BBB 1080p **30 帧与 60 帧**、Park Joy 1080p50 **12 帧**全部逐像素通过 |
| 仿真 | ✅ **极限用例**：12 种图案（全黑/全白/噪声/单点…）、60 帧长跑、失锁重锁、换几何（1440×1080）全过；边界表见 `doc/02-verification.md` 第四节 |
| 仿真 | ✅ **帧相位对齐已修（2026-10-17）**：`hdmi_out` 一次性消隐插入，16 个相位点 `dropped 0 / held 0`（校机 Verilator 套件）；本机 xsim 另用连续源复核 3 个起始相位（校正量 4 / 731 / 746，逐帧 720/720 行、稳态 0 丢弃、收敛回死区） |
| 综合 | ✅ 0 error |
| 实现 + DRC | ✅ **0 error，0 critical**（对齐修复后重跑） |
| **时序** | ⚠️ **WNS +0.026 ns、WHS +0.083 ns，失败端点 0 / 13 526** —— 达标但**贴线**，见下 |
| 位流 | ✅ `dist/sdi2hdmi_20261017_155133.bit`，5 980 026 B，md5 `3cdb1284507610ba9ccaa064fed97383`，含对齐修复。**槽位装得下**：同步字 `AA 99 55 66` 在偏移 **158**，payload = 5 980 026 − 158 = **5 979 868 B，与 BOOT.bin 槽位逐字节相等**。~~原话：「比 BOOT.bin 的固定槽位大 158 B，`.bit` 大小只由器件决定，重建永远解决不了这 158 B」~~ —— **此句已撤回（2026-10-25）**：那 158 B 是 `.bit` 自己的头部长度，不是超出量；原判断把文件总长和 payload 长混在一起跟槽位比了。`dist/` 里 2026-10-14 至 10-17 的 **15 次构建全部** 5 980 026 B／同步字 158／payload 5 979 868，没有一次不等。槽位与"加逻辑不会让位流变大"的机理见 wiki `BOOTbin位流替换手术.md` §6.5。 |
| 上板 | ❌ 未做。位流运行时刷不进去，只能走 BOOT.bin 手术（wiki `BOOTbin位流替换手术.md`） |
| TMDS 编码与串行化 | ⚠️ 只验到编码器输入（VHDL + 硬件原语，仿不了） |
| 真实 SDI 源的相位关系 | ⚠️ 已定标：板实测几何 1920×1080，与「`cam_vs` 与第一条有效行同拍」一致；整条相位轴已扫过 |
| `overflow` 接引脚 | ❌ 未做。**当前位流里没有它**（综合已优化掉），需要先查到空闲引脚 |
| SD-SDI | ❌ 明确不支持（DRU 是加密网表，替身把 SD 路径留空，见 `doc/01-architecture.md` 第九节） |

资源：**MMCM 3/5、LUT 4.36%（3430/78600）、FF 1.14%（1785/157200）、BRAM 8.5/265、GTXE2_CHANNEL 1/4、IOB 15/250**。
（对齐修复的代价：**+74 LUT / +43 FF**，对比例 LUT 3356、FF 1742。）

> **⚠️ WNS 只剩 +0.026 ns（26 ps）**，等于贴线。换 Vivado 版本、换约束顺序、
> 或者再动一点逻辑都可能翻负。加功能前这条必须重新盯。

仿真挖出的 RTL bug，**综合和时序报告一个都看不出来**：

| 测试台 | 挖出的 |
|---|---|
| `tb_hdmi_out` | 同步极性反了（点不亮显示器）、`vcnt` 没跟 `hcnt` 联动（光栅彻底错乱）、RGB565→888 绿通道多拼一位（颜色全错）、CDC 同步器没复位（综合干净的空画面） |
| `tb_e2e` | `scaler_720` 的 `out_y` 没有上界 → 每帧多推 59 行 → 行槽静默溢出、画面永久错位；以及启动瞬态把测量帧的垃圾数据喂进不可反压的 FIFO |
| 校机 harness（真实视频） | 判据的帧相位模型漏了**跨帧边界那 2 行**（合成图案逐帧不变，看不出来；真实视频一看就出来） |
| 校机 harness（相位用例） | 8 槽环只吸得住 **约 ±7 行**（上界 ±8 行）的源/光栅帧相位差，超出就永久留下横带；而板上的源相位是任意的 → **已修**（2026-10-17，一次性消隐插入，16 点表全过） |
| 校机 harness（**自己的缺陷**） | 「等输出帧」的等待循环**只推时钟、不驱动源**：对齐机制把一帧拉长到近 1500 行（实测最长 746 行 ⇒ 1496 行）时，等待变成一次最长 ~16 ms 的源停机，把刚校正掉的相位又造回来 ⇒ 每帧重校正的极限环。测试台的等待也是激励（`doc/03-flow.md` 坑 32） |

> **`tb_e2e` 还证伪了我自己上一轮的一个「修复」**：当时根据一个节拍设错的测试台，
> 把 `hdmi_out` 的取行门控改错了。端到端实测证明**原来的写法才对**，已回退。
> 记在 `doc/02-verification.md` 第二节的 ⛔ 小节。

> **✅ 上板横带问题已修（2026-10-17）**：行槽环只有 8 个槽，只吸得住 **约 ±7 行
> （上界 ±8 行 = ±26 400 camclk）** 的源/光栅帧相位差，而真板上 SDI 源自由运行、相位任意，
> 于是每帧丢/重复约 `(偏差 − 7)` 行、位置恒定、不会自愈（解锁也不行）——这是修前的实测结论。
> 修法：`hdmi_out` 在写侧帧标记到达时**把当前帧拉长一次**（多插 `(p + 4)` 行消隐，只拉长不缩短），
> 读侧帧边界自此与源同相、永久锁住。校机 16 个相位点全部 `dropped 0 / held 0`
> （`doc/02-verification.md` 第四节第 3b 小节），xsim 另有独立复核（连续源、真实起始相位）。
> 代价：一帧变长（≤ 16.7 ms，显示器最多丢一帧）、+74 LUT / +43 FF。

收敛过程与逐条分析见 `doc/02-verification.md` 第四节（校机）与第六节（本机）。

## 跑

> **脚本在哪**（2026-10-17 归口 + 回退；当晚工程移入 `S:\work\WCIS\wiki\repos\sdi2hdmi\`＝最终位置）：
>
> - **本目录（正本）**：`compile.ps1`、`compile_impl.ps1`、`build.tcl`／`build_synth.tcl`、
>   `impl_only.tcl`。构建脚本用 `ROOT = SCRIPT_DIR` 推根目录，**搬到别处就原地失效**
>   （`doc/03-flow.md` 坑 35），所以它们必须和 `rtl\`／`constrs\` 待在一起。
> - **`S:\work\WCIS\workenv\fpga-src\sdi2hdmi\`**：`sim\run_sim_*.ps1` 与
>   `sim\suite_school*.sh`（校机套件）。本目录留 `rtl\`、`doc\`、`sim\` 的源码与测试台。
>
> 下面的命令按「谁的正本在哪」写路径。

```powershell
# 仿真：重采样（约 20 秒）
powershell -NoProfile -ExecutionPolicy Bypass -File S:\work\WCIS\workenv\fpga-src\sdi2hdmi\sim\run_sim_scaler.ps1

# 仿真：行槽 CDC + 光栅（约 2 分钟，14 帧逐像素）
powershell -NoProfile -ExecutionPolicy Bypass -File S:\work\WCIS\workenv\fpga-src\sdi2hdmi\sim\run_sim_hdmi_out.ps1

# 仿真：端到端（约 2 分钟，真实 2200x1125 源）
powershell -NoProfile -ExecutionPolicy Bypass -File S:\work\WCIS\workenv\fpga-src\sdi2hdmi\sim\run_sim_e2e.ps1

# 1) 综合，产出 .build\post_synth.dcp
powershell -NoProfile -ExecutionPolicy Bypass -File .\compile.ps1 -SynthOnly

# 2) 实现 + 出位流（从上面的 checkpoint 续跑）
powershell -NoProfile -ExecutionPolicy Bypass -File .\compile_impl.ps1
```

**端到端 + 源起始相位**（本机 xsim；板上的真实条件：光栅先跑、源后锁，相位任意）。
`sim\tb_e2e.v` 的 `SRC_HOLD_LINES` 把源**在消隐里**推迟 N 个源行再起跑（1 源行 = 2/3 光栅行），
源之后仍是连续的 1125×2200、没有插入时间：

```powershell
xvlog .\rtl\sdi2hdmi\scaler_720.v .\rtl\sdi2hdmi\hdmi_out.v .\sim\tb_e2e.v
xelab  tb_e2e -s e2e_sweep
xsim   e2e_sweep --R --testplusarg "hold=1091"   # 1091 行 ≈ 727 光栅行：校正量 731 行的一帧
xsim   e2e_sweep --R --testplusarg "hold=1113"   # 1113 行 ≈ 742 光栅行：校正量 746（最坏）
```

> ⚠️ plusarg 的值**必须带引号**才能过 `xsim` 的命令行解析，而 PowerShell 把参数交给 `.bat`
> 时会**吞掉引号**（`doc/03-flow.md` 坑 6），所以上面两条要写进 `.cmd` 或在 `cmd /c` 里跑；
> 直接在 PowerShell 里敲会得到 `Expected a switch but found …`。
> 取 `SRC_HOLD_LINES` 的默认值（0）就是旧的相位≈0 用例。

**真实视频 / 极限用例 / 事件恢复 / 长跑在**校机**上跑（Verilator + C++ 测试台）：

```bash
# 脚本正本：本目录 sim/（2026-10-18 入库；校机那份 D:\yzd\sdi2hdmi\ 已删）
bash sim/suite_school.sh        # 全量套件，约 20 分钟，日志 out/suite2_summary.txt
# 帧相位窗口表（16 个相位点，验收判据）：同目录 suite_school_window.sh，约 7 分钟
bash sim/suite_school_window.sh
```

**为什么拆成两步**：这台机器上的 Vivado 会随机读不到**它自己的**运行时脚本，
构建在不同阶段以退出码 −1 断掉。综合是最长的阶段、最容易撞上，所以做一次，
实现从 checkpoint 续跑。两个脚本都带重试。

**为什么真实视频在校机**：本机只有 xsim，几十帧真实视频要按小时算；
校机的 Verilator 测试台每源帧约 0.4 s（快两个数量级）。跑法与坑见
`doc/03-flow.md` 第六节。

Vivado 只在本机（`S:\apps\Xilinx\Vivado\2018.3`），校机没装。

## 目录

```
rtl/
  sdi2hdmi_top.v          顶层：时钟、复位、接线、LED
  sdi2hdmi/
    scaler_720.v          盒式重采样 -> 1280x720（已仿真 + 端到端验证）
    hdmi_out.v            行槽 CDC + 720p60 光栅（已仿真 + 端到端验证）
  vendor/                 厂商 RTL，逐字复制
    sdi/                  rx_sdi 及 smpte_sdi 解码链（rx_sdi.v 加了一个输出端口）
    display/              uihdmitx / TMDSEncoder / oserdese2_10to1
    ip/                   sys_clk、mgtclk、smpte_sdi(EDIF)
constrs/sdi2hdmi.xdc      引脚与时序约束
sim/                     自检测试台与运行脚本
doc/                     架构 / 验证读数 / 流程与踩坑
dist/                    综合与实现报告、位流
```

## 支持的制式

| 源 | 输出 | 说明 |
|---|---|---|
| 1080p60 / 59.94 (3G-SDI)，光栅 2200×1125 | 720p60 | 2:3 盒式缩小，主用例 |
| 1440×1080 系（光栅仍是 2200×1125） | 720p60 | 水平 9:8 缩小，实测通过 |
| 1080p30 / 25 (HD-SDI) | 720p60 | 缩小 + 读侧重复帧 |
| 1080p50（光栅 2376×1125） | 720p60 | ⚠️ 帧周期与 active 窗口**都不匹配** → 永久撕裂，不是本设计的目标 |
| 720p60 / 50 (HD-SDI) | 720p60 | 1:1 透传（需 `cam_clk = 74.25 MHz`，测试台的时钟模型表达不了，未仿真验证） |

**光栅契约是两条等式**（不是一条）：源的 `有效行数 × 总宽度` 必须等于 2 376 000 camclk，
且 `总行数 × 总宽度` 必须等于 2 475 000 camclk。对 1080 行的源联立只有 **2200×1125** 一个解。
实测边界表见 `doc/02-verification.md` 第四节第 4 小节。

**没做的**（详见 `doc/01-architecture.md` 第九节）：隔行场合并、上采样、
4K/超过 1440 行、SDI 音频、EDH/ANC 数据、OSD。

## 指示灯

| 灯 | 含义 |
|---|---|
| J1 | SDI 传输帧锁定 `rx_t_locked`（沿用厂商 `LED_MON=1` 的含义） |
| M6 | HDMI 像素时钟在跑 |

`hdmi_out` 另有 `overflow` / `stat_dropped` 两个状态输出表示行槽溢出，
**目前只在顶层留了内部网，没接灯** —— 需要先查到空闲引脚。
在接上之前综合会把它优化掉，所以**当前位流里没有溢出检测**。
**上板前值得接上**：这一轮的「复位后永久撕裂」就是靠这两个计数（加上 harness 的
`--diag`）定位到行槽环的，没有它们上板只能看到「画面有横带」而说不出原因。