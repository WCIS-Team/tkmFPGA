# SHL-2.1 适用范围（tkmFPGA）

本仓库中由 **takomitkm** 原创的 FPGA 硬件设计与配套内容，采用根目录
[Solderpad Hardware License v2.1](LICENSE)（SPDX：`Apache-2.0 WITH SHL-2.1`）。

Copyright (c) 2026 takomitkm

根目录 SHL-2.1 **不覆盖** 下列内容，它们各自保留原条款，不受本许可影响：

| 范围 | 说明 |
|---|---|
| `sdi-psddr/FPGA HD-SDI to PS Video Capture Card/` | 冻结的厂商参考设计快照（只读归档），权利归原厂商/权利人 |
| `pl_eth_psgem1_emio/rtl_a2_patched/ai7030_edif_top.v`、`ps_ai_peripheral.sv`、`ps_ai_wrapper.sv` | 上海复旦微电子（fmsh）"Confidential" 厂商文件 |
| 各项目下的 Vivado 生成物（`.xpr` / `.xci` / `.dcp` / `.bit` 等）与厂商 IP | 工具/厂商产物，非本许可的原创表达 |
| 任何带自身 LICENSE / NOTICE / README 署名的第三方或衍生内容（如 `sdi2hdmi` 视频链路相关署名） | 以上游/原权利人条款为准；**不得**用 takomitkm 名义替换原作者 |
| `vpu-live` 随附的媒体/日志样本（`.h264` / `.jpg` / `.png` / `.ts` / `.log` 等） | 各自来源与版权保留 |

权属判断以具体文件头、同目录 LICENSE/NOTICE、上游来源记录为准；权属不清时不推定
takomitkm 有权替他人授权。
