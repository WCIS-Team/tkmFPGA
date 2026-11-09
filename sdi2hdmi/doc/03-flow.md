# sdi2hdmi — 流程与踩坑

可复现的命令，以及这一轮真踩到的坑。**脚本内容一律英文**（仓库约定）。

Vivado 只在**本机**（`S:\apps\Xilinx\Vivado\2018.3`），校机没装。

分工（**按任务性质分，不是按机器分**）：xsim 三段自检在**本机**，因为它要 Vivado；
**长跑、真实视频、批量极限用例在校机**，用 Verilator（快两个数量级，且脚本化容易）。
见下面「校机：Verilator」。

---

## 一、仿真

```
cd S:\work\WCIS\wiki\repos\sdi2hdmi
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_sim_scaler.ps1
```

跑两例：1280×720 透传、1920×1080 缩放。约 1 分钟。

> **源比 1280×720 小 = SKIP**：`scaler_720` 不实现放大，测试台打印一句 `SKIP:`
> 就在**时间 0** `$finish`。这既不是通过也不是失败 —— 老版本的默认 plusarg 正是
> 96×54（放大），所以「默认跑一下」看起来像测试台坏了。默认值已改成真用例。

内部是裸 xsim 三步，不用工程模式：

```
xvlog rtl/sdi2hdmi/scaler_720.v sim/tb_scaler_720.v
xelab tb_scaler_720
xsim  tb_scaler_720 -runall --testplusarg w1920 --testplusarg h1080 --testplusarg f4
```

端到端（约 5 分钟，`2200×1125` 真源光栅全部逐像素比）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_sim_e2e.ps1
```

### 为什么用 plusarg 而不是 `-d`

Vivado 2018.3 的 `xvlog` **不接受 `-d MACRO=value`**：

```
> xvlog -d TB_SRC_W=1280 rtl/...
ERROR: [XSIM 43-4316] Can not find file: 1280
```

它在 `=` 处把参数拆开，然后去找一个叫 `1280` 的源文件。
`--define` 和 `-dTB_...` 一模一样地失败。**编译期参数化在这条工具链上走不通。**

### 为什么 plusarg 是「开关」而不是 `key=value`

`xsim.bat` 同样在 `=` 处拆命令行：

```
> xsim tb_scaler_720 -runall --testplusarg src_w=96
Expected a switch but found 9
Usage: .../xsim.exe [options]
```

`src_w=96` 被拆成 `src_w`、`9`、`6`。而且 **`xsim` 碰到不认识的参数会打印
usage 并且退出码仍是 0** —— 也就是「静默失败」。所以 `run_sim_scaler.ps1` 里
除了查 `FAIL:`，还额外要求日志里**必须出现 `PASS:`**：

```powershell
if (-not (Select-String -Path $simOut -Pattern 'PASS:' -Quiet)) {
    Write-Host '  -> no PASS line in the simulator log'
```

只查「没有 FAIL」会把一次根本没跑起来的仿真算成通过。这是这一轮实际踩到并修掉的。

### 校机：Verilator（长跑 / 真实视频 / 批量极限用例）

本机跑不动、或者要跑几百遍的东西都在**校机**上跑（Verilator 只有校机有）。
2026-10-18 起工程内 `sim/` 就是这些脚本的正本，校机原来那份 `D:\yzd\sdi2hdmi\` 已删——
在校机跑时把工程（或至少 `rtl/`、`sim/`、`out/`）放到任意目录，`bash sim/suite_school.sh` 会自己
`cd` 到工程根。`data/frames/*.rgb565` 是**按体积类规则不入库**的（下面有 ffmpeg 重建配方），
`out/` 需要存在（脚本直接往里写日志，只有 `focus.sh` 自己 `mkdir -p`）。
版本：Verilator 5.050 + MSYS2 mingw64 gcc 16.2.0。

```bash
# RTL 侧：Verilog 测试台直接编成二进制（--binary 自带 main，也能吃 +plusarg）
verilator --binary --timing -CFLAGS "-O2" -Wno-fatal -Wno-WIDTHEXPAND \
    --top-module tb_scaler_720 -j 8 -Mdir obj_sc720 -o sc720 \
    rtl/sdi2hdmi/scaler_720.v sim/tb_scaler_720.v
./obj_sc720/sc720.exe +w1920 +h1080 +f4

# C++ 测试台（长跑、真实视频、注入事件都走这条）
verilator --cc --exe --build -j 8 -CFLAGS "-O2" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
    --top-module vlt_top -Mdir obj_harness -o harness \
    rtl/sdi2hdmi/scaler_720.v rtl/sdi2hdmi/hdmi_out.v sim/vlt_top.v sim/harness.cpp
./obj_harness/harness.exe --pattern noise --frames 60
./obj_harness/harness.exe --src data/frames/bbb.rgb565 --frames 30
```

一次跑完真实视频 + 12 种图案 + 复位/失锁/换几何 + 长跑 + 源相位窗口 + `cam_vs` 相位扫描：

```bash
# 脚本正本：本目录 sim/suite_school.sh（2026-10-18 入库；原来放在 S:\work\WCIS\workenv\fpga-src\sdi2hdmi\sim\，那是未入库的临时归口）
bash sim/suite_school.sh   # 约 20 分钟，日志 out/suite2_summary.txt / out/suite2_full.log
```

窗口扫描（相位表那一张，16 个点、每个 12 帧、取后 4 帧稳态）另有单脚本：

```bash
# 正本同上：sim/suite_school_window.sh
bash sim/suite_school_window.sh   # 约 5 分钟
```

几个只在诊断时用的开关：

```bash
--diag              每源帧打印一次行槽环状态（行数/丢弃/停顿/几何/锁），判定失败时先看它
--start-phase N     复位后先把源空拖 N 个 camclk 再送第一帧 = 制造源与读侧的帧相位差
--vs-rise-x N       cam_vs 相对第一条有效行晚 N 个 camclk（相位敏感度扫描）
--reset-frame N     第 N 帧中途复位（事件恢复用例）
```

真实视频（`data/frames/*.rgb565`，每帧 `1920*1080*2` 字节）：

```
big_buck_bunny_1080p_h264.mp4  --ffmpeg-->  bbb.rgb565      60 帧
park_joy_1080p50.y4m           --ffmpeg-->  parkjoy.rgb565  12 帧

ffmpeg -i clip.mp4 -vf scale=1920:1080 -pix_fmt rgb565le -frames:v 60 -f rawvideo bbb.rgb565
```

**素材只是「内容」，光栅由测试台决定**：测试台一律按 1080p60 的 2200×1125 光栅驱动
（`cam_clk` 固定 148.5 MHz），所以 park_joy 那份 50 Hz 素材也是当 60 Hz 光栅喂的。
要验「源真是 1080p50 光栅（2376×1125）」是另一回事，走 `--geom2`（见坑 25）。

**为什么另做一个 C++ 测试台，而不是把 Verilog 测试台搬到校机**：剩下要问的问题是
**长跑、复位、失锁重锁、中途换几何**，这些用「`$readmemh` + 嵌套循环」的 Verilog 测试台
写起来极其别扭；而且 Verilog 测试台还有个更根本的问题 —— 它的信号可以随便驱动，
一不小心就喂出硬件产生不出来的激励（坑 17）。C++ 侧把「真源光栅」写成一个函数，
**所有**用例都从它取激励，出不了第二种光栅。

时钟模型：`cam_clk` 148.5 MHz，`hdmi_pix_clk` 取它一半（74.25 MHz），一拍 cam 对应
相位 0/1/2/3 —— 相位 1 采 HDMI 侧输出，相位 0/2 采 scaler 侧。所以**时钟关系是 2:1**，
这决定了 720p 源这一档在测试台上表达不出来（坑 25）。

---

## 二、综合

```
cd S:\work\WCIS\wiki\repos\sdi2hdmi
powershell -NoProfile -ExecutionPolicy Bypass -File .\compile.ps1 -SynthOnly -Jobs 8
```

全流程（综合 + 实现 + 位流）去掉 `-SynthOnly`。

产物在 `dist/`：

| 文件 | 内容 |
|---|---|
| `utilization_synth.rpt` / `utilization_routed.rpt` | LUT / FF / BRAM / DSP / MMCM |
| `timing_synth.rpt` / `timing_routed.rpt` | WNS / TNS / 端点数 |
| `drc_routed.rpt` | DRC |
| `sdi2hdmi_<时间戳>.bit` | 位流 |

工程用**非工程流程**（`read_verilog` → `synth_design` → `opt/place/route`）。
厂商交付是个 `.xpr`，里面挂着一棵预生成的 block design 和 71 MB 的 NPU EDIF 网表，
未授权 Vivado 根本展不开。这里没有值得继承的东西。

`smpte_sdi` 解码核**只有 EDIF 没有 RTL**，按厂商同样的方式读：
`read_edif` 实现 + `read_verilog` 端口桩。**桩是必需的**，去掉桩直接
`module 'smpte_sdi' not found`。

---

## 三、这一轮踩到的坑

### 1. `cam_hs` 与 `cam_de` 同拍上升

`rx_sdi.v` 里 `cam_hs`、`cam_vs`、`cam_data_en` 三个都出自
`YCbCr422_2_RGB888`，所以**行首那一拍 `cam_de` 也是高的**。

最初把「行首复位」写成 `cam_hs` 的**上升沿**，和像素通路放在同一个
`if / else if` 链上。于是首像素走了复位分支被丢掉，而竖直方向每次都是
少一行、多一行地错开。

更隐蔽的是另一版：即使让两者同拍跑，像素通路对 `h_take`／`h_frac` 的赋值
会**覆盖**行首初始化的值，用的是上一行残留的分数步进。结果 `h_take` 卡在 1，
每个像素都收口，`out_x` 在 0..63 之间反复绕圈，**每行尾部覆盖行首**。
帧照样「完成」、几何照样测对，只有像素是错的。

**改法**：行首复位挪到 `cam_hs` 的**下降沿**（消隐期），那里 `cam_de` 是低的，
两个块不碰同一批寄存器。

> 教训：这类「同拍信号」必须显式处理，不能靠 `else if` 排开。
> 判据不是「看起来对不对」，而是**下一个模块看到的时序是不是你以为的那个**。

### 2. 行宽计数器在错误的沿清零

`px_in_line` 一开始在 `frame_start` 清零，于是量出来的是**整帧像素数**
（本例 96×54 = 5184），不是行宽。

改成在行尾清零之后又踩了第二个坑：行尾是**最后一行之后**才到，而
`frame_start` 读的就是 `px_in_line` —— 已经清成 0 了，`locked_q` 永远不置位。

**最终**：行走状态在下降沿复位；`px_in_line` 单独在**上升沿**清零。
那个沿与首像素同拍，但只碰 `px_in_line` 和 `lines_in_frame`，不碰行走状态，
所以是安全的。

### 3. 垂直平均取错了参照物

垂直 2 抽头一开始写成「和上一条**已发布输出行**求平均」。`v_take=2` 时那条行
覆盖的源范围 `[F(k-2),F(k-1))` 和需要的 `[F(k-1),F(k))` 根本不是一回事，
结果是整行整行的纵向拖影。

**正确**：同一缓冲、同一像素下标读-改-写。顺带省掉第三块缓冲和第二遍扫描。

### 4. 测试台的坑比 RTL 的还多

| 现象 | 根因 |
|---|---|
| 921 601 条 mismatch，全是 `0xxxxx` | 捕获缓冲按 `cap[k][j]` 索引，但只写了 `DST_H` 行，而 `base = cap_y - DST_H` 越界。改成 `CAP_ROWS = 4*DST_H` 加取模 |
| 96×54 源刷出 921 601 条 mismatch | 那不是缩放，是**放大**，本设计不支持。TB 现在直接打印 `SKIP` 说明 |
| 第一帧的像素全是垃圾 | 缩放器的几何来自**上一帧**，复位后第一帧本来就该是垃圾。改成只比对最后一个完整帧 |

> 教训：写完自检 TB 先跑一遍**已知会过**的最小用例，确认判据本身是通的，
> 再去追 DUT 的 bug。这次是先怀疑了三轮 RTL，最后发现 TB 自己在骗人。

### 5. `smpte_sdi` 的 EDIF 后缀是 `.edf`，不是 `.edif`

这是本轮**最费时间**的一条。现象：

```
ERROR: [Common 17-69] Command failed: File
'S:/.../rtl/vendor/ip/smpte_sdi/smpte_sdi.edif' does not exist
```

但文件明明在那儿——`dir` 列得出来，`.NET Directory.GetFiles` 也枚举得到，
**偏偏 Tcl 的 `file exists` 返回 0，PowerShell 的 `Test-Path` 返回 False**。

对照一下字节就明白了：

```
枚举到的  ...smpte_sdi.edf      len=80
我拼出来的 ...smpte_sdi.edif     len=81
```

真名是 **`.edf`**。我按 EDIF 的通用后缀拼成了 `.edif`，于是：

- `Test-Path` / `file exists` 安静地返回 False，**不报错**；
- `Copy-Item` 报 "Cannot find path"；
- Vivado 只说 "does not exist"。

三条症状都指向「拷贝没成功」，于是先去查拷贝——而拷贝其实是对的。

> **教训**：路径拼错在这套工具链上**全部静默失败**。要确认一个文件在不在，
> 用 `[System.IO.Directory]::GetFiles($dir)` 枚举真实目录项，别用
> `Test-Path` 拼名字。厂商的 `.xpr` 里 `smpte_sdi.edf` 是对的，
> 抄自己的记忆而不是抄文件名。

### 6. PowerShell 传参会改写参数

`Start-Process -ArgumentList @('tb_scaler_720','-runall', ...)` 会被 PowerShell
重新加引号，xsim 随后报 `-runall` 非法。**改成把参数拼成一行交给 `cmd /c`** 才稳。

2026-10-17 又量了三次，把边界定清楚了：

| 写法 | 结果 |
|---|---|
| `xsim e2e --testplusarg hold=1091`（不加引号） | ❌ `Expected a switch but found 1091` —— 加载器在 `=` 处**拆开了 token** |
| `xsim e2e --testplusarg "hold=1091"`（引号直达 xsim） | ✅ |
| PowerShell 里写 `--testplusarg "hold=1091"` | ❌ 引号在交给 `.bat` 的路上**被 PowerShell 吞掉**，退化成第一行 |
| 同一行写进 `.cmd` 文件再从 PowerShell 调用 | ✅ 引号由 cmd 负责，能活到 xsim |

同理 `xelab -generic_top "SRC_HOLD_LINES=1091"` 走 PowerShell 会变成两个参数
（报 `Cannot find design unit work.0 in library work`）。

**结论**：凡是要带引号的 xsim/xelab 参数，**写进 `.cmd`（或 `cmd /c` 的一行）**，
不要在 PowerShell 里直接拼。脚本化的正本就是
`C:\Users\takomi\AppData\Local\Temp\opencode\e2e_compile.cmd` / `e2e_run_hold.cmd`
（本地 scratch，不属工程；形状见 README「端到端 + 源起始相位」）。

### 7. Tcl 里的 `!` 碰上非数字

`if {![$have_unisim] && [file exists $p]}` —— `$::env(XILINX_VIVADO)` 没设时
`file join` 返回空串，`$have_unisim` 初始化前循环里可能拿到非 0/1，
报 `can't use non-numeric string as operand of "!"`。
判据要用 `[info exists ::env(XILINX_VIVADO)]` 先探。

### 8. 器件是 `xc7z030ffg676-2`，不是 `xc7z030ai`

```
ERROR: [Common 17-69] Command failed: Invalid part specified: 'xc7z030ai'.
Use the get_parts command for information on what parts are available
```

板子丝印 `JFMQL30TAI676H`（FCBGA676）对应的就是这颗 Xilinx 器件。
**厂商自己的工程用的正是 `xc7z030ffg676-2`**（`fpai_demo_vivado.xpr` 的
`<Option Name="Part" Val="xc7z030ffg676-2"/>`）。

**别照 `ai` 那个后缀去猜。** 另外这一条有个好处：wiki 里记的
「器件库补丁 `JFM_Kits/ip_patch/100ai/`」是 **PS7 那条路**需要的
（报 `named port connection 'AI_IN1622' does not exist`），
**本设计没有 PS7，所以那份补丁不是前置条件**。

> 教训：器件型号这种字符串，抄工程文件里已经跑通的那一份，
> 不要按厂商命名习惯推。

### 9. 行槽 RAM 必须用「寄存读」，否则会推断成分布式 RAM

`mem[slot][px]` 直接连续赋值给输出，Vivado 会推断成 **LUTRAM**：
8 槽 × 1280 × 16 bit = **163 840 个 LUT**，而器件只有 78 600。
改法是把地址从计数器发出去、下一拍把数据寄存进 `rgb`，
`hs/vs/de` 同样从**同一拍**寄存，三者自然对齐（本来就是一级流水）。

### 10. `set_msg_config` 降不了 DRC 的严重级别

要放过 `DRC INBB-3`（黑盒 `dru`，替身与理由见 wiki [[SDI转HDMI转换器]] 第六节第 2 条），直觉写法是

```tcl
set_msg_config -id {INBB-3} -new_severity {WARNING}
```

**这条被静默忽略**，Vivado 自己会说：

```
[Common 17-1565] set_msg_config should not be used to change the severity of
DRC/METHODOLOGY checks. Please use the
'set_property SEVERITY <NEW_SEVERITY> [get_<drc|methodology>_checks <ID>]' command instead.
```

然后照旧在 `opt_design` 前跑 DRC，照旧中止：

```
[Vivado_Tcl 4-78] Error(s) found during DRC. Opt_design not run.
```

可用的是

```tcl
set_property SEVERITY {WARNING} [get_drc_checks {INBB-3}]
```

——**厂商自己的 `ai7030.xdc` 对 REQP-44/46/52/56 降级用的就是这个写法**
（见 [[官方demo时序基线与器件库补丁]]）。抄工程里已经跑通的形式。

> 教训：和上一条一样，**降级/覆盖这类操作去看一份已经生效的配置文件**，
> 不要按工具名和常见 API 猜。

### 11. MMCME2_BASE 会触发时序 38-1

```
CRITICAL WARNING: [Timing 38-1] DLL output pin(s) used on clock modifying cell
u_hdmi_mmcm without a feedback net: CLKOUT0 CLKOUT1
```

`MMCME2_BASE` 把 `CLKFBOUT`/`CLKFBIN` 留空是可以综合的，但工具在提醒：
输出与 fabric 的相位关系没有经过反馈路径验证。
换成 `MMCME2_ADV` 并把 `CLKFBOUT → BUFG → CLKFBIN` 接起来，
代价是一个 BUFG（本设计 BUFG 用量 10/32）。

### 12. Windows PowerShell 5.1 读写中文文件会把内容毁掉

**这一条差点毁掉整份验证文档**，而且是无声的。

```powershell
$t = Get-Content 'doc\02-verification.md' -Raw      # 按 ANSI(936) 读，不是 UTF-8
$t = $t -replace '## 三、', '## 四、'                # 正则里的中文也匹配不上
Set-Content 'doc\02-verification.md' $t -Encoding UTF8   # 再按 UTF-8 写，还加了 BOM
```

UTF-8 的字节被当 GBK 解码 → 再按 UTF-8 编码，**双重编码且有损**：
`器件` 的第二个字被吃掉，变成 `器` + U+FFFD + `?`（实际文件里写的是
U+FFFD 这个码位本身）。而且替换根本没生效（正则是在乱码上匹配的），
等于「改坏 + 没改成」。

**规矩**：

- 改中文文件用 `edit` / `write` 工具，**不要**用 `Get-Content` + `Set-Content`。
- 万一非要用 shell，按字节处理，不走文本往返：

  ```powershell
  $b = [System.IO.File]::ReadAllBytes($f)          # 绝对路径！
  if ($b[0] -eq 0xEF) { [System.IO.File]::WriteAllBytes($f, $b[3..($b.Length-1)]) }
  ```

- `[System.IO.File]` 类**不吃 PowerShell 的 `cd`**，必须给绝对路径。
  `cd` 改的是 PowerShell 的当前位置，.NET 用的是进程工作目录。
- md 交付前扫一遍：BOM、`CR`（要 LF）、`U+FFFD`。

### 13. `-replace` 里写 `\r\n` 会往源文件里塞 CR

用 PowerShell 做文本手术时，替换串里的 `` `r`n `` 会**原样写进文件**。
`hdmi_out.v` 和 `tb_hdmi_out.v` 各被塞进 1～4 个 CR，源文件里混进裸 CR。

不影响 Vivado 编译（它两种都收），但文件不再是纯 LF 了。
检查方法同上：按字节数 `= 13` 的个数。

### 14. `Tee-Object` / `>` 存下来的日志是 **UTF-16LE**，工具会当成二进制

同一个 `run_sim_scaler.ps1`，脚本自己重定向写出来的 `sim_run.txt` 是纯 ASCII，
而 `& .\run_sim_scaler.ps1 | Tee-Object -FilePath sim_scaler_postfix.txt`
存下来的是 **UTF-16LE 带 BOM**（头两字节 `FF FE`、一半字节是 `00`）：

```
sim_scaler_postfix.txt   head=FF FE 0D 00 0A 00  utf16le=True  NUL=921
sim_run.txt              head=0D 0A 2A 2A ...     utf16le=False NUL=0
```

后果：# 读文件的工具直接报 "Cannot read binary file"，
`git diff`/`rg` 也认不出来；`Select-String` 反倒能读（它自动识别 BOM），
所以「我明明 grep 到 PASS 了」和「这文件是二进制的」会同时成立。

**规矩**：留档的日志让**脚本自己**写（`Start-Process ... -RedirectStandardOutput`、
`cmd /c ... > file`），或者事后按字节转一道：

```powershell
$enc = New-Object System.Text.UTF8Encoding($false)                # 无 BOM
$t = [IO.File]::ReadAllText($f, [Text.Encoding]::Unicode)          # 按 UTF-16LE 读
[IO.File]::WriteAllText($f, $t, $enc)
```

转完仍然要扫 `= 13`（原来那批是 CRLF，会留下 CR）。

---

## 四、`hdmi_out` 行为仿真这一轮（2026-10-15）

新加 `sim/tb_hdmi_out.v` + `sim/run_sim_hdmi_out.ps1`，
一次挖出 4 个 RTL 真 bug，**综合和时序报告一个都看不出来**。
bug 本身和读数在 `doc/02-verification.md` 第二节，这里只记**方法上的坑**。

### 数字反常时，先怀疑判据本身

这一轮 4 个错报里有 3 个是测试台自己的，而且每一个都伪装成硬件故障：

| 坑 | 表面现象 | 真因 |
|---|---|---|
| `strict` 初值写成 1 | 开头 17 个像素误报 payload 错 | 主程序在**释放复位之后**才清 0，那时已经出第一行了 |
| `c_line_hold` 声明成 1 位 | 1000 万次「撕裂」 | 拿 1 位比 `rgb[23:19]`（5 位） |
| 极性期望取错流水深度 | 10 514 次误报 | `hs` 两级，期望取了一级 |
| `THROTTLE` 写成 parameter | 第二级**根本没超速** | 注释说全速冲，参数写死 |

最贵的一条：节流方向搞反。**空闲 2560 拍 = 每行 25.9 µs，比读侧 22.2 µs 慢**，
FIFO 是被**抽干**而不是填满，「无背压」阶段记了 733 440 个保持像素。
看着像设计有毛病，其实是测试台把生产者调慢了。

**所以：断言写错的时候，报出来的数越大越像真的。**

### 不可反压的写口，失败模式必须可见

SDI 像素流不能停，所以写口满时只能丢。
一旦丢了，生产者的像素计数器和 DUT 的写指针**永久错开**。

`dbg_hdmi_out.v` 量到的：

```
=== dropped writes        : 220160
=== dut w_bin final       : 8
=== producer w_line final : 4500
```

这种失败**在综合、时序、DRC 里全是绿的**。所以加了
`stat_dropped` + `overflow` 两个输出，让它能被数到。

根因是取行门控：`claim_now` 带 `&& in_vact`，
一帧 750 个行槽只取 720 个 → 每 1718.75 rclk 取一个，
生产者每 1650 rclk 供一个 → **快 4.17%** → 占用必然爬到上限。

> ⛔ **但这个「根因」本身是错的，见下一节 16 条。**
> 4.17% 是**测试台**的节拍设错，不是设计的缺陷。
> 端到端证明原来的 `&& in_vact` 才是对的，这里的"去掉它"已回退。
> 下面这段只保留当时的实测数字，结论以第 16 条为准。

### 长跑才能暴露的缺陷

4.17% 的亏空是**慢慢爬**的。测试台如果只跑两帧，深度根本到不了上限，
断言会全过。`dbg_hdmi_out` 用 112 个窗口 × 40 行的长跑才稳定看到
`stat_dropped = 0`。

> **凡是「速率对不上」类缺陷，测试必须长到覆盖最坏累积量**，
> 否则通过的那次是运气不是证据。

---

## 五、端到端仿真这一轮（2026-10-16）

新加 `sim/tb_e2e.v` + `sim/run_sim_e2e.ps1`。它验的是**两个模块之间**的契约，
这层前面两个测试台加起来都替代不了——各自单测时判据都成立，问题恰恰在中间。

### 14. 判据能对「全零」报 PASS

端到端测试台第一次运行时：

```
=== scaler lines emitted   : 0  (src geometry 0x6749, locked=0)
=== line-sequence slips (frame 0) : 0
=== PASS: end-to-end content exact
```

scaler **一行都没输出**，`locked_q=0`，几何是垃圾值。
而内容比对**通过了**——因为捕获缓冲全是 0，`gold[0][0]` 也恰好是 0。
**拿两个 0 比 0，等于什么都没验。**

**所以现在所有前置条件单独断言**：`locked` 必须置位、必须有行推出、
几何必须等于 1920×1080、黄金模型和捕获缓冲都**不许全零**。

> **内容比对的 PASS 是没有意义的，除非先证明激励真的动了。**

### 15. 脚本吞输出 → 连着三轮在读旧快照

`xelab` 早就失败（层级引用了不存在的信号），但我把输出 `| Out-Null` 掉了，
于是以为在测新代码，实际上 `sim_e2e.txt` 的时间戳一直是旧的。
**连续三轮的分析和两次 RTL 改动都建立在旧快照上。**

判据：**每次跑仿真先看日志时间戳是不是新的。**
`run_sim_*.ps1` 已经强制要求 `PASS:` 行，但**编译/细化失败要单独看**。

### 16. 测试台的错误会诱导出真的设计回归（最贵的一条）

我用一个**节拍设错**的测试台去量「设计稳不稳」，得到「不稳」，
于是去改设计——**改动本身制造出了一个更难查的问题，而原始证据始终是错的。**

错在哪：`tb_hdmi_out` 的生产者设成每 1650 rclk 出一行，
比消费者实际需要的 1718.75 rclk **快 4.17%**，所以溢出。
那是**测试台的错**，我却拿它当证据改了 `hdmi_out` 的取行门控。

**规则**：

1. 改设计之前，先证明**测试台的激励和真实场景是同一个契约**。
   判断标准不是「它报没报错」，而是「它的节拍对不对」。
2. 单模块测试台的节拍经常是假的，因为它**不知道另一个模块的突发特性**。
   本例中真实契约是**突发**的：720 行连续每 1650 rclk，然后消隐期停。
   按平均节拍配的测试台既会太慢也会太快，于是**两头都错**。
3. **端到端测试台是唯一能发现这类问题的**，因为它验的就是模块之间的契约。

---

## 六、真实视频与极限用例这一轮（2026-10-16，校机）

Vivado 只在本机，所以**长跑和批量用例搬到了校机**，用 Verilator 跑（`doc/02-verification.md`
第四节）。这一轮的坑里，最贵的三个都在**测试台**这边，而且第一个的代价是整轮判据。

### 17. 测试台给 DUT 喂了「硬件产生不出来」的激励（最贵的一条）

`cam_data_en = cam_vs & cam_hs`（`rx_sdi.v:357`）意味着**「vs 低而 de 高」这个组合在真板上
根本不存在**。而两个测试台都把 `src_de` **独立于 `src_vs`** 驱动，于是这个不存在的组合
随手可得——顺手就用上了：为了避开「`cam_vs` 与 `cam_hs` 同拍」引发的某次比对失败，
`tb_e2e` 把 `cam_vs` 的上升沿挪到了第一条有效行的有效像素**之后**（`VS_RISE_X = 2000`）。

代价：

- 垂直游走从**源第 1 行**起算，输出第 k 行由源第 k+1 行构成，**整帧下移一行**；
- 判据当时正好是坏的（见 18），于是这一行错位被解释成了「内容 90.6% 对上」，
  一路分析到「垂直平均取错了参照物」上去。

**规则**：测试台里的**每一个信号都要能追到厂商 RTL 的某一行**。
追不到的、或者「反正是内部信号，随便驱动」的，就是 bug 的入口。
`cam_vs` 的同拍上升沿**不是可选项**：晚一拍那条行就丢了 `data_en`，源帧永远少一行。

判断「测试台能不能产生这个 bug」比判断「测试台报不报错」重要得多：
这一轮三个真 bug，**两个测试台在坏掉的状态下全部报 PASS**。

### 18. 判据读不到的计数器 = 没有判据

`tb_e2e` 的 `line_miss`（内容比对的失败计数）是 `compare_frame` 的**局部变量**，
而判据读的是 `pre_fail` 和 `seq_bad`。于是**720 行内容全错也能打印
`PASS: end-to-end content exact on every frame`**，这个假 PASS 在文档里挂了一整轮。

同一个文件里已经有同类前科（坑 14：拿两个 0 比 0）。**两次都是「判据本身没看东西」，
不是「判据看了东西没看出来」。**

**规则**：判据里出现的每个计数器，都要能指到**产生它的那个赋值**。
局部变量、被 `| Out-Null` 吞掉的输出、`-Quiet` 掉的日志，都是同一个坑的不同外衣。

### 19. 同一个 `always` 块里「清零」和「递增」撞在同一拍 → 后写的赢

`scaler_720` 在 `frame_start` 清 `lines_in_frame`（`:305`），在 `line_start` 递增（`:357`）。
`cam_vs` 的上升沿与第一条有效行的 `cam_hs` **同拍**（硬约束，见 17），所以这两条赋值
落在**同一拍**，**后面那条赢，清零永远不生效**。实测六帧后 `lines_in_frame = 6479`
（= 6×1080 − 1），`src_h` 是垃圾，`locked_q` 永不置位 ⇒ **上电黑屏**。

厂商自己的 `sdi_status.v:203` 有同样的场景，它的写法是**在一个分支里解决**、
同拍时**种 1 而不是清 0**。这不是风格问题，是这类计数器的唯一正确写法。

**判据**：一个 `always` 块里对同一个变量有两条赋值路径时，先问「它们会不会同拍」。

### 20. 「每行都有 `hs`」——消隐行也是行

`frame_convertor` 在每个 SAV 重启水平计数器，而**垂直消隐行同样带 SAV**，
所以 `cam_hs` 在**每一条行**上都会拉高（1080p 是 1125 次，不是 1080）。
按 `hs` 上升沿数行数得到 1125，垂直方向被拉伸 4%。

同一个原因制造了第二个坑：有效区之后的第一条消隐行会让 `px_in_line` 重载成 0，
而 `src_w` 当时是从 `px_in_line` 在 `frame_start` 锁存的 ⇒ **读到 0** ⇒ `locked_q` 永不置位。
修法是在**有像素的那一行的行尾**锁存一个独立的 `src_w_meas`
（`line_end && px_in_line != 0`），而不是在帧头从「当前行计数器」里取。

**规则**：从「跨行的活计数器」里读一个**跨帧的量**，几乎总是错的。
要么在量刚好完整的那一拍锁存，要么单独维护。

### 21. Verilator：`-CFLAGS "-O2"` 不是可选项

mingw64 的 GCC 16 在 `-Os`（Verilator 默认）下**不导出 `std::basic_string` 的移动构造**，
链接期报未定义符号。加 `-CFLAGS "-O2"` 解决，与功能无关。

另外 `--exe` 的 C++ 侧要提供 `double sc_time_stamp() { return 0.0; }`，
`--binary` 生成的 main 要它。

### 22. Verilog-2001 不拼接相邻字符串字面量

```verilog
$display("a" "b", x);     // Verilator: unexpected STRING, expecting ')'
$display({"a", "b"}, x);  // 对
```

`"a" & "b"` 这种按位与写法 xsim 收下了，但不要依赖它。

### 23. 时间 0 就 `$finish` ≠ 测试台坏了

`tb_scaler_720` 在 Verilator 下「跑不起来」了很久，真相是**默认 plusarg 选了一个
比输出还小的源**（96×54 → 1280×720 是**放大**），代码走进 SKIP 分支打印一句就退出。
换掉默认值 + 传上真 plusarg 之后，同一个二进制跑得好好的。

**规则**：`$finish` 出现在时间 0，先找**有没有一条提前退出的路径**，再看测试台结构。
同理，「跑得起来但判据是 SKIP」比跑不起来更危险 —— 它可能被当成 PASS。

### 24. 帧相位：行槽环给不出 0 偏移，而且偏移**跨帧边界**

`hdmi_out` 是 8 个行槽的**环**，读端的帧边界是它自己的 `vsync`，**槽里没有行号**，
所以显示帧相对生产者第 0 行必然有一个固定偏移（= 环的占用）。1080p60→720p60 实测 **2 行**，
且恒定（两个帧周期都恰好 1 237 500 拍）。

判据改成「**在最佳帧相位上逐像素全等**，且**相位不许自己漂移**」。
漂移 = 滚动，那才是真故障。要求偏移为 0 是要求一个这套结构给不出来的东西。

**但第一版判据还是错的，而且只有真实视频能把它证伪。** 偏移 2 行意味着显示帧**最上面 2 行
来自上一帧的最后 2 行**（偏移是「往回」的，不是「往前」的），而第一版黄金模型
把 capture 第 r 行对到 `golden[(r + off) % 720]` —— **单帧内循环移位**，
永远对不上那 2 行。

代价：真实视频第一次跑 FAIL 2345/921600 像素，而
`[bisect] scaler stream : 0 of 921600 pixels differ`（缩放器流本身一个像素不差）
——判据在冤枉一个正确的设计。

**合成图案完全看不见这个 bug**：图案是**逐帧不变**的（种子固定），
`golden(f) == golden(f-1)`，所以忽略上一帧的模型照样通过。
判据要**跨两帧**取黄金（`rot_best_pair(cap, golden(f), golden(f-1))`），
而**要证明它错了，只能用真实视频**。这是「为什么必须找真实源」的实证。

### 25. 帧率硬锁的**两条**等式：帧周期 + active 窗口

`scaler_720` 每源帧推出恰好 720 行，`hdmi_out` 每输出帧消耗恰好 720 行，
**中间没有帧缓存**。所以源光栅要同时满足：

```
active 窗口 = 有效行数 × 总宽度 = 720 × 3300 = 2 376 000 camclk
帧  周期   = 总行数   × 总宽度 =       1 237 500 rclk = 2 475 000 camclk
```

对 1080 行的源，这两条**联立只有一个解：2200 × 1125**（1080p 标准消隐）。
实测（`--geom2` 切到该光栅，10 帧）：

| 源光栅 | active 窗口 | 帧周期 | 结果 |
|---|---|---|---|
| 2200×1125（1080p60） | ✅ | ✅ | ✅ 本设计的目标 |
| 1440×1080×2200×1125 | ✅ | ✅ | ✅ 通过（水平消隐变宽而已） |
| 2250×1100 | ❌ 2 430 000 | ✅ | ❌ 426/720 行错 |
| 2376×1125（1080p50） | ❌ | ❌ 慢 8% | ⚠️ 读侧断流，重复行 |
| 1650×750（720 级） | ❌ | ❌ 快一倍 | ⚠️ 写侧溢出，丢行 |

**只对帧周期是不够的**（2250×1100 就是帧周期对、active 窗口不对的 FAIL）。
「只对帧周期」这个说法曾经写进文档，是**半条**契约。
失败模式是**降级**（丢行/重复行）而不是挂死，`stat_dropped` / 背压计数看得见。

**没验的**：720p60 源。它和输出同帧率，**应该**能用，但它需要 `cam_clk = 74.25 MHz`，
而测试台把 `cam_clk` 固定在 148.5 MHz、HDMI 时钟取它的一半 —— 这个 1:1 的时钟关系
测试台的相位表表达不了。

### 26. 换几何的用例要跟着换黄金模型

校机的 C++ 测试台支持运行中途换源几何（`--geom2`）。第一版**只换了激励、没重算黄金**，
报了一堆假失败。而且换尺寸会改变「一帧多少字节」，除零要挡。

还要注意：换几何的**用例本身**也得是合法光栅，否则量到的是契约违反（见 25）。
第一版把 `--geom2 1440x1080x2475x1125` 当「合法几何变化」，它其实是 12.5% 的
active 窗口失配，通过与否说明不了几何切换本身。

### 27. Verilator 里读子模块内部信号：要 include 根类头

Verilator 把子层次**摊平**进根对象，`Vvlt_top` 里没有 `u_scaler` 这个成员，
内部寄存器要走 `du->rootp->vlt_top__DOT__u_scaler__DOT__lines_in_frame`；
而且 `Vvlt_top.h` 只有前置声明，**必须再 include `Vvlt_top___024root.h`**，
否则报 `invalid use of incomplete type 'class Vvlt_top___024root'`。

测试台里用一个宏收住这串名字，别在判定路径上依赖它：

```cpp
#define SC(name) (du->rootp->vlt_top__DOT__u_scaler__DOT__##name)
```

**放在 `vlt_top` 端口上的信号才是稳定接口**（`src_w`/`src_h`/`stat_dropped`…），
内部探针只在 `--diag` 里用。

### 28. 校机 MSYS2：脚本里不 export PATH，二进制起不来

`obj_harness/harness` 会报
`error while loading shared libraries: libstdc++-6.dll: cannot open shared object file`，
**这不是构建失败**，是脚本头少了一行：

```bash
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
```

这一轮踩了两次（第二次是 `suite.sh` 里加了、`resetlong.sh` 里漏了），
两次都表现为「日志是空的」，很容易误判成测试台崩了。

### 29. 驱动/消费两侧的帧边界**没有对齐机制** —— 只有约 ±7 行相位差是吸得住的

这条是**设计问题**，不是测试台问题，记在这里是因为它是这一轮的带队结论，
而且是**上板阻塞项**。

实测（`sim/suite_school_window.sh`，16 个源相位、每个 12 帧、取后 4 帧稳态；
读侧一行 = 3300 camclk、帧周期 = 2 475 000 camclk）：

| 源相位 | 折算 | 稳态丢弃/重复 | 判定 |
|---|---|---|---|
| 0 … 20 000 | 0 … 6.1 行 | 0 / 0 | ✅ |
| 26 000 / 26 400 | 7.9 / 8.0 行 | 1 280 / 1 280（1 行） | ❌ |
| 50 000 | 15.2 行 | 10 240 / 10 240（8 行） | ❌ |
| 100 000 | 30.3 行 | 29 440 / 29 440（23 行） | ❌ |
| 1 237 500（半帧） | 375 行 | 30 720 / 30 720（24 行） | ❌ |
| 2 465 000（= −10 000） | −3.0 行 | 0 / 0 | ✅ |

**窗口就是「环的槽数 − 1」那一档**（8 个槽给的上界是 ±8 行 = 26 400 camclk，
实测 20 000 = 6.1 行干净、26 000 = 7.9 行就脏）；越界之后损失随偏差增大但有上界（约 24 行/帧），
**稳定、不漂移、不会自愈**（解锁也不行）。中途复位之所以必然落进这个状态，
就是因为它把源的帧相位挪到了窗口外（那一例稳态损失 `29440 px = 23 行/帧`，
反推相位差约 30 行——和相位表里 100 000 camclk 那一点重合）。

故障定位很干净：`[bisect] scaler stream : 0 of 921600 pixels differ`，
`[bisect] hdmi capture : 72630 of 921600 pixels differ` ——
**写侧一个像素不差，全部差异在行槽环这一侧。**

数据、机制与修法见 `doc/02-verification.md` 第四节第 3 小节。

**规则**：只测「上电能出图」会漏掉这一类。**事件恢复要单独测**，
而且要看**稳态**（十几帧之后还在不在），不能只看复位后头两帧。
还有一个便宜的定位手法：把「写侧流」和「显示侧」分开各比一次黄金模型，
一眼就能看出故障在链的哪一半（这一轮就是靠它把 `scaler_720` 摘干净的）。

### 30. 测试台默认的相位是**真板产生不出来的** —— 一次假 PASS 的完整复盘

这条比 29 更值钱，因为 29 是设计缺陷，**这一条是判据缺陷**：它让整整两轮套件
给出「上电是干净的」这个错误结论，并写进了三份文档。

经过：

1. 第一、二轮套件的相位表是 **8 个点全 PASS、0 损失**，于是写下
   「上电路径实测干净，不挡上板」。
2. 为了修一行提示文字（见 31）重建了 `obj_harness/harness`，同一张表**变成
   「只有相位 0 干净」**，7 个点全是 23 行/帧级别的损失。
3. 先怀疑不确定性，做了对照：同一二进制跑两遍、再从同一份源码重新构建跑一遍，
   **三次逐字节相同** ⇒ 模型是确定性的，不是随机、也不是编译器的锅。
   那次「全过」只能是**旧二进制**给的假 PASS（旧构建对应的源码版本已不可考）。
4. 再追问「为什么相位 0 一定是干净的」——因为 **`--start-phase 0` 时源的第 0 帧
   和光栅的第 0 帧是同一个复位释放点同时开始的**（harness 里两者都由 `rst_n` 释放驱动），
   相位差天然≈0 行。**真板上做不到**：SDI 是自由运行的外部输入，
   FPGA 配置完光栅就先跑，源是后来才锁上的，相位任意。
5. 于是补了窗口扫描（`sim/suite_school_window.sh`），把窗口量成 **约 ±7 行**（上界 ±8 行），
   并确认损失随偏差单调、稳定、对称。

**代价**：所有 PASS 用例（真实视频 30/60/12 帧、12 种图案、60 帧长跑、边界表）
都是在**板子产生不出来的相位**下跑的 ⇒ 它们证明的是「**对齐之后**逐像素正确」，
而「对齐本身」恰恰是没验过的那个前提。这就是坑 17 的同一个毛病，第二次犯，
而且这次犯在**相位**这个更隐蔽的维度上。

**规则**：

- 测试台的**默认值**也是激励的一部分。写默认值时问一句「板上这个量是谁决定的」——
  凡是**外部输入**（源相位、源制式、源是否存在）都由**对方**决定，测试台必须去扫，
  不能选一个方便值当默认。
- 判据「全过」时要问「**这组点为什么全过**」。8 个点全过、而且连趋势都没有，
  本身就是可疑信号——真实系统里相位失配通常是**越大越坏**的连续函数。
- 有疑问先做**确定性对照**（同二进制跑两遍 + 重建跑一遍），再谈结论。
  这次只花了两次 8 帧运行就把「不确定性」排除掉了。

### 31. 判据打印的**结论行**也要能被它自己的数字支持

还是那个 bisect，但错在最后一行提示文字。原来的写法是

```cpp
if (sb != cb) say("=> the scaler stream is already wrong; hdmi_out is not the one to fix\n");
```

`sb` 是写侧流与黄金的差异、`cb` 是显示侧的。于是**最典型的下游故障**
（`sb = 0`、`cb = 72630`）恰好命中 `sb != cb`，打印出来的结论是**反的**：
数据说「写侧一个像素不差」，结论说「写侧已经错了，别改 `hdmi_out`」。
真正的条件应该是 `sb > 0` 才算写侧有错。

代价：这一条**差一点把方向带偏**——当时正是在追「复位后画面为什么撕裂」，
如果顺手信了这行结论，接下来就会去查一个已经证明是对的模块。

**规则**：判据里的每一行**结论**（不只是每一个计数器）都要能被同一段的数字推出来。
打印结论时把条件一起写出来（`sb=0 cb=72630`），或者干脆只打数字、不打结论。

**更一般的形式**：别用 `!=` 表达「谁更差」。`sb != cb` 只在「两个量必须相等」时成立，
而这里的物理含义是**「`sb` 必须为 0」**。`sb = 5, cb = 0`（写侧错、显示侧恰好更好）
与 `sb = 0, cb = 5` 在 `!=` 下无法区分——而这两种情况的处置是**相反**的。
比较运算符要照着**物理含义**写：谁必须为零、谁只要不增长、谁与谁必须相等。

### 32. 测试台「等输出帧」的等待循环会把源**停住** —— 一次信号中断，把刚修好的相位又造了回来

修好对齐机制之后，16 个相位里还有 2 个（2 400 000、2 448 000）**每帧都重新校正一遍**，
幅度还每次都对（`add` 731 = 727 + 4、746 = 742 + 4，测出来的 `p` 和预测一字不差）——
**测量对、装载对，相位就是不动**。

原因在测试台：harness 每帧的流程是「驱动 1125×2200 camclk 的源 → 等一个输出帧完成」，
而那个「等」是**只推时钟、不驱动源**的：

```cpp
while (g_frames_out < want) { one_cam_period(); }   // 期间源信号全部冻住
```

正常情况下这个等待是 0（驱动窗口正好 750 行，里面必然有一个输出帧边界）。
但**对齐机制把一帧拉长到近 1500 行**（实测最长 746 行 ⇒ 1496 行）时，750 行的窗口里可能**一个输出帧边界都没有**，
于是等待最长跑到 ~731 行 = **16 ms 的源停机**。源一停，它的帧边界相对光栅就**在时间上挪了**，
而挪掉的距离正好等于刚被校正掉的那段 ⇒ 下一帧测出来还是同一个 `p` ⇒ 再校正一次 ⇒ **极限环**。

实测签名：15 帧里 15 次 stretch、每次幅度相同；每帧 `held ≈ 719 行`、`dropped ≈ 22 行/帧`。

修法（不是改设计，是改测试台的激励模型）：

- **帧背靠背驱动**，每帧严格 1125×2200 camclk，不多不少；
- 比较对象改成「**最新一个完整输出帧**」，没有新输出帧的这一轮**不比较**（拉长后的一帧差不多是
  源帧的两倍长，有些源帧天生就没有配得上它的输出帧）；
- 一次 stretch 当成一次**事件窗口**：拉长期间环被抽干、约一帧的内容不可见地穿过去，
  帧映射**合法地**移一位，之后重新锁存延迟与相位（和注入复位/失锁同一套处理）。

结果：同一张 16 点表 **16/16 PASS、`dropped 0 / held 0`**。
（判据同时补了两条硬检查：**最近 3 帧里不许再有 stretch**——「还在校正」不算收敛；
以及**比较过的帧数下限**——没有输出帧的静默空跑不算证据。）

**规则**：测试台的「等待」也是激励的一部分。**真 SDI 源不能暂停**——它不知道对面在等，
一停就是一次信号中断。凡是 DUT 的契约里写了「源是连续的」，测试台在等待期间也必须继续驱动它。
另一条便宜的判据：**如果一个校正每帧都以同样的幅度重复出现，先问「是什么把输入又造了回来」**，
不要先怀疑校正器算错了——测量和装载都对的时候，答案通常在环境里。

### 33. Verilator 会把「只写不读」的诊断寄存器优化掉

对齐循环里为了探针加了 `align_pos` / `align_add`（`vcnt` 采样值、算出的校正量）。
它们在 RTL 里**没有任何功能读者**，Verilator 的优化器直接把它们删掉，
于是 harness 通过扁平化层次读这两个名字**读不到**（旧构建树因此整个重建）。

修法：诊断改用**功能信号**——`wf_s3`（标记同步后的电平）和 `v_extra`（正在拉长的行数），
它们本来就被设计逻辑读，谁也不会删。事件计数也改成看它们：`v_extra` 的 0→非 0 沿就是一次校正。

**规则**：没有功能读者的信号不是信号。要在 Verilator 里探针一个量，
就让这个量在**设计逻辑里真的被用**，别指望层次化路径能读到被优化掉的名字。

### 34. 新加一条 CDC，就要同时给它一条（靶向的）假路径

本工程的时序约束是**靶向 `set_false_path`**（按单元到单元），不是一刀切
`set_clock_groups`（理由见 §六 第 3 步）。

对齐机制新增了一条 CDC：`scaler_720.out_frame`（camclk 域）→ `hdmi_out` 的
`wf_s1` 两级同步器（rclk 域）。**新 CDC 不跟着加约束的后果**是：工具会按
「两个时钟有固定相位关系」去算这条路径——而它们没有。那条路径上的「违例」是**假的**；
比假违例更糟的是**照着假违例去改设计**。

加的时候写法也要对齐既有约定：按**单元到单元**过滤
（`*u_scaler/out_frame_reg*` → `*u_hdmi_out/wf_s1_reg*`）；
之前有一轮按引脚（`/Q`）过滤，**一个单元都没匹配上**，等于没约束（§六 第 3 步）。

加约束后的实现结果：**WNS +0.026 ns、WHS +0.083 ns、失败端点 0 / 13 526**。

**规则**：CDC 和它的约束是**同一件事的两半**，加 CDC 的那次改动就要把约束一起加，
并沿用同一条命名/过滤约定——否则「约束到底生没生效」这件事本身没人验。

### 35. 用 `ROOT = SCRIPT_DIR` 的构建脚本**不能挪窝**

一次仓库整理把 `build.tcl` / `build_synth.tcl` / `impl_only.tcl` / `compile*.ps1`
搬进了 wiki 仓库。`build.tcl` 的第一行就是

```tcl
set ROOT [file normalize [file join [file dirname [info script]] ..]]
```

它算出来的是**脚本自己所在的位置**——搬到 wiki 仓库之后，那个位置下面没有 `.v`、没有 `.xdc`，
**构建脚本原地失效**。处置：脚本**正本回到设计树里**（`fpga-src/sdi2hdmi/`，
md5 与 `MOVE-MANIFEST.md` 对得上），wiki 里的那一份只当**流程文档**看。

**规则**：构建脚本和它构建的东西**放在一起**；实在要挪，就得把根目录做成参数
（`-ROOT` / 环境变量），而不是从 `SCRIPT_DIR` 推。

### 36. 激励旋钮的单位没换算 —— 三次不同的输入，逐字节相同的输出

给 `tb_e2e` 加「源起始相位」旋钮时，`SRC_HOLD_LINES` 的语义是**源行数**
（1 源行 = 2200 cam_clk = 2/3 光栅行），而空闲计数的递减是**每 cam_clk 一次**。
装载时忘了乘 `SRC_TOTAL_W`，于是 `hold=1091` 实际只停 1091 个 cam_clk ≈ 1/3 行 ——
**三个不同的 hold 值都退化成相位 0**。

危险的地方在于它**全绿**：`720/720 rows exact`、`dropped 0`、`1 frames stretched`、
`settled want=0` —— 因为相位 0 本来就是最干净的那一档。三次运行的区别只体现在
`first add=` 这一个诊断读数和 `start phase` 一行打印上，而两次运行的其他所有数字**逐字节相同**。

**识别它的信号**：
1. **几个不同的激励值给出完全相同的读数** —— 正常的设计对相位是连续的、单调的响应，
   三个值全一样说明**激励根本没到 DUT**；
2. 打印的 `start phase` 只证明**参数被解析**，不证明**它被换算成了时间**；
   要让打印带上换算结果（`+hold=1091 lines = 2400200 cam_clk`）才叫证据。

**规则**：给测试台加激励旋钮时，**打印它的物理量**（换算后的时间/行数），
并且**拿两个差别足够的取值各跑一次、先确认输出确实不同**，再去解释输出。

同一轮还抓到一个**读数**陷阱（同一类，属于「监看会撒谎」）：`settled want` 打印的是
**打印时刻**的 `align_want` —— 自由运行的光栅行号、任意瞬间的值，看着像「收敛到别处」；
而判据里根本没有读收敛相位。修法是监看在**标记到达那一拍**采样
（拉长期间的标记 `p` 没有意义，跳过），并把「最后一个干净标记的 `want` ∈ 死区
`{0,1,749}`」写进 PASS/FAIL。

**规则**：监看的值要在**它有意义的那一拍**采样；一个判据从不读的读数不是证据。

---

## 七、上板

位流**运行时刷不进去**——三条重载通道全断（见 wiki `PL位流重载通道失效.md`）。
目前唯一可行的是 **BOOT.bin 位流手术**（wiki `BOOTbin位流替换手术.md`）：

1. 官方 `BOOT.bin` 的位流槽位长度**固定 5 979 868 B**（由器件配置决定，不是设计大小决定），
   而本设计的位流包是 **5 980 026 B，比槽大 158 B**，按位流槽位流程处理时要先解决这 158 B。
2. 替换后需五项独立复验（见 wiki 第五节），不能只信脚本自检。
3. 换一次要重启。

**上板前还欠三件事**（详见 `doc/02-verification.md` 第七节）：

1. ~~**行槽环的帧边界对齐**（阻塞项）~~ **✅ 已修（2026-10-17）**：一次性消隐插入，
   16 点窗口表全 0 损失、复位/失锁/换几何全部恢复。机制与代价见第四节第 3b/3c 小节；
   含修复的位流已重出（`dist/sdi2hdmi_20261017_155133.bit`，md5 `3CDB1284…`，
   WNS +0.026 ns、失败端点 0 / 13 526）。
2. `overflow` / `stat_dropped` 没接到引脚（要先查板级引脚表找空闲 LED）。
3. 板子从未点亮过显示器。仿真全过、时序全过，但那是**必要条件不是充分条件**。
   位流本身已经是最新的（含对齐修复）；上板要走 BOOT.bin 手术，而**包比槽大 158 B
   与设计无关**（`.bit` 大小只由器件决定，修复前后都是 5 980 026 B），
   只能在烧写流程里按槽位长度处理。

> 上面第一条（相位窗口）修完之前，它的严重性在于**不是概率问题**：
> 修前板上的相位几乎不可能落在窗口里（750 行里只有约 14 行的机会，≈2%），
> 也就是修前的 RTL 上板**大概率就是带横带的画面**。见坑 30 的复盘。
> 现在这一条已经修掉：16 点窗口表全过，剩下的上板风险落在第 2、3 条。

> 原来这里还有第三条「`hdmi_out` 和 `scaler_720` 没一起跑过、720 供 750 耗的供需
> 关系要先确认」——**已经确认了**：读端是**每有效行取一个槽**，不是每帧 750 个，
> 所以稳态是 720 供 720 耗 0 丢弃，实测见 `doc/02-verification.md` 第三节。

---

## 相关文档

- `doc/01-architecture.md` — 为什么这么接
- `doc/02-verification.md` — 实测读数
- `S:\work\WCIS\wiki\md\技术文档\位流构建与SDI信号检测.md` — 厂商 demo 的 SDI 取证