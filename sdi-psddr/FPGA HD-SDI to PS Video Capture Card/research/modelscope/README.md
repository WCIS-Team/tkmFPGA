---
frameworks:
- other
license: Apache License 2.0
tags: []
tasks:
- image-object-detection
---

# FPAI 参考实现

本仓库提供基于 FPAI 芯片和 Icraft 工具链的嵌入式 AI 参考工程，覆盖 SDI、PCIe、网络摄像头和文件输入，以及 HDMI 显示、VPU 编码、网络推流和结果保存。当前分支 `func_icraft3.36` 的主线 SDK/Runtime 为 **Icraft 3.36.1**，采用 C++17 functional pipeline；个别模型及示例的版本例外见下文。

| CMake 平台 | 架构 / 芯片 | 主要使用场景 |
| --- | --- | --- |
| `BY` | Buyi / 100TAI | 单路、多路 YOLOv5，检测跟踪，双输入融合 |
| `ZG` | Zhuge / 30TAI（ZG330） | 单路、多路 YOLOv5，INT8 / FP16 模型输入输出适配 |

**接入自己的业务，从示例的 `src/*.cpp` 开始。** Context 保存设备、buffer pool、队列、Network/Session 和算法状态；公共 actor 管理线程、消息和槽位生命周期。输入预处理、模型初始化、NPU step 和后处理在顶层 cpp 中定义，通过 lambda 直接传入 actor 工厂。

- 选择参考工程：见下方支持矩阵。
- 修改输入和算法：见 [顶层 cpp 集成指南](deps/modelzoo_utils/integration.md)。
- 理解 Webcam/MVX 多会话、线程、buffer 和低延时策略：见 [VPU pipeline 软件架构](deps/modelzoo_utils/vpu_pipeline.md)。
- 查看耗时、Session 网络和张量：见 [调试开关说明](deps/modelzoo_utils/debugging.md)。
- 查公共模块：见 [modelzoo_utils 导航](repos/Icraft-ModelZoo-yolov5/fpai_demo_app/deps/modelzoo_utils/readme.md)。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| [examples/0_datapath](examples/0_datapath) | 不依赖 AI 模型的数据通路，以及 ImageMake / FPGA NMS 调试程序 |
| [examples/1_single_input+ai](examples/1_single_input+ai) | 单输入 YOLOv5、YOLOv5 + SiamFC++ 检测跟踪 |
| [examples/2_pcie_hostin+ai](examples/2_pcie_hostin+ai) | PCIe Host 输入、NPU 推理与结果回传 |
| [examples/3_multi_inputs](examples/3_multi_inputs) | 多路独立推理、双输入 CFT、文件输入 YOLOv5 + TarDAL |
| [deps/modelzoo_utils](deps/modelzoo_utils) | Functional pipeline、采集/输出适配、模型辅助函数与测试 |
| [deps/thirdparty](deps/thirdparty) | OpenCV、FFmpeg、LIVE555 等随包头文件和库 |
| [tools](tools) | FTMP 分析、图像比较、计时及批量构建脚本 |
| [.agents/skills](.agents/skills) | 模型准备、接入、板端调试、性能优化与交付流程 |

各示例是独立的 CMake 工程，通常包含 `src/`、`configs/` 和可选的 `imodel/`；仓库根目录没有统一的 CMake 工程。

## 参考实现支持矩阵

整理日期：2026-09-11，按当前分支已提交的源码、CMake、配置和模型资产核对。✅ 表示提供相应平台的参考实现及必要的模型配置；— 表示当前未提供。基础 Webcam 工程使用共用 VPU 数据通路源码。

| 类别 | 示例目录 | BY | ZG | 数据流与使用边界 |
| --- | --- | :---: | :---: | --- |
| 数据通路 | [DebugDemos](examples/0_datapath/DebugDemos) | ✅ | ✅ | 默认 `test_plin_imagemake`；`test_fpga_nms` 需匹配 CustomOp 位流并开启 `FPAI_BUILD_FPGA_NMS` |
| 数据通路 | [PCIeHostin+VPU](examples/0_datapath/PCIeHostin+VPU) | ✅ | ✅ | PCIe → 内存 / VPU 编解码 |
| 数据通路 | [PLin+HDMI](examples/0_datapath/PLin+HDMI) | ✅ | ✅ | SDI → HDMI |
| 数据通路 | [PLin+VPU](examples/0_datapath/PLin+VPU) | ✅ | ✅ | SDI → VPU → 文件 / RTMP / RTSP |
| 数据通路 | [Webcam+VPU](examples/0_datapath/Webcam+VPU) | ✅ | ✅ | 单路 / 双路 RTSP → VPU 解码、编码 → 文件 / RTSP；解码路径仍在优化 |
| 单输入 AI | [PLin+MultiNets+HDMI](examples/1_single_input+ai/PLin+MultiNets+HDMI) | ✅ | — | YOLOv5 检测 → SiamFC++ 跟踪 → HDMI；模型及算子边界仅提供 BY 版本 |
| 单输入 AI | [PLin+MultiNets+VPU](examples/1_single_input+ai/PLin+MultiNets+VPU) | ✅ | — | YOLOv5 检测 → SiamFC++ 跟踪 → VPU |
| 单输入 AI | [PLin+SingleNet+HDMI](examples/1_single_input+ai/PLin+SingleNet+HDMI) | ✅ | ✅ | SDI → YOLOv5 → HDMI；BY / ZG 使用各自的网络拆分和模型 |
| 单输入 AI | [PLin+SingleNet+VPU](examples/1_single_input+ai/PLin+SingleNet+VPU) | ✅ | ✅ | SDI → YOLOv5 → 文件 / RTMP / RTSP；包含 ZG FP16 模型及配置 |
| 单输入 AI | [Webcam+SingleNet+VPU](examples/1_single_input+ai/Webcam+SingleNet+VPU) | ✅ | ✅ | RTSP → YOLOv5 → 文件 / RTMP / RTSP / Print；ZG 配套位流要求硬件 YUV2RGB |
| PCIe AI | [PCIe+SingleNet+PCIe](examples/2_pcie_hostin+ai/PCIe+SingleNet+PCIe) | ✅ | ✅ | PCIe → YOLOv5 → PCIe；需配套 Host 握手与位流 |
| 多输入 AI | [MultiPLin+MultiNets+VPU](examples/3_multi_inputs/MultiPLin+MultiNets+VPU) | ✅ | ✅ | 多路 SDI → 多 YOLOv5 → 多 VPU；一个 NPU scheduler 调度，BY 通常 4 路、ZG 通常 2 路，物理端口在 YAML 中指定 |
| 多输入 AI | [MultiPLin+SingleNet+VPU](examples/3_multi_inputs/MultiPLin+SingleNet+VPU) | ✅ | — | 双路 SDI 对齐 → CFT → 单 VPU |
| 多输入 AI | [MultiPSin+SingleNet+VPU](examples/3_multi_inputs/MultiPSin+SingleNet+VPU) | ✅ | — | 双路图片 / FTMP 输入 → CFT → 单 VPU；输入 producer 在 cpp 中定义 |
| 多输入 AI | [MultiPSin+MultiNets+Save2File](examples/3_multi_inputs/MultiPSin+MultiNets+Save2File) | ✅ | — | 成对 RGB / IR 文件 → YOLOv5 检测 → TarDAL 融合 → 保存检测图和融合图；使用独立的 3.31.1 SDK/Runtime |
| 多输入 AI | [MultiWebcams+MultiNets+VPU](examples/3_multi_inputs/MultiWebcams+MultiNets+VPU) | ✅ | ✅ | 双路 RTSP → 多 YOLOv5 → 文件 / Print / RTSP；单核 NPU 调度 |

源码支持、交叉编译、Session 初始化、输出正确性、性能和长稳需要分别记录。矩阵不代表当前提交已完成全部板端回归；部署时应核对实际 target、SDK/Runtime、模型和位流组合。

## 在哪里修改业务

| 集成需求 | 修改位置 |
| --- | --- |
| 更换自己的 input | 在顶层 cpp 定义 Context 和采集回调；固定槽位数据源可用 `make_psin_input_actor`，完整自定义生命周期可用 `make_custom_input_actor` |
| SDI 只负责数据通路 | 使用 `sdi_input.hpp` 的 `make_sdi_input_actor`；基础 input 创建并管理绑定的 buffer pool |
| SDI 使用 ImageMake | 使用 `sdi_imagemake_input.hpp` 的 `make_sdi_imagemake_input_actor`，直接传入 cpp 中的初始化 / 处理 lambda |
| 模型不使用 ImageMake | 在 cpp 的 input 准备回调完成 resize、layout、dtype、量化等预处理，填写消息中的输入张量 |
| 加载自己编译的 JSON/RAW | 在 cpp 的 `initialize_npu` 中加载 Network、拆图、创建和配置 Session |
| 改推理步骤或多网络顺序 | 修改同一 cpp 的 `npu_step` / scheduler 回调 |
| 改结果解码与业务处理 | 修改同一 cpp 的 `post_process` / `yolov5_post_processor`，或 scheduler 中的结果处理段 |

可以从 [SDI YOLOv5 文件输出入口](examples/1_single_input+ai/PLin+SingleNet+VPU/src/sdicamera+yolov5+vpu2file.cpp) 复制单模型流程；顺序执行两个模型可参考 [YOLOv5 + TarDAL 入口](examples/3_multi_inputs/MultiPSin+MultiNets+Save2File/src/psin+yolov5+tardal+save2file.cpp)。具体工厂参数、默认回调和输入内存生命周期见 [集成指南](deps/modelzoo_utils/integration.md)。

ZG YOLOv5 已包含 FP16 `NCHWc16` 和 FP32 `NHWC` 输出解码，并按实际执行的 Session 网络读取张量信息。检测结果 stabilizer 的参数与调用位置沿用已有实现。

Webcam 的每个 VPU session 使用一个 owner worker 处理 input/capture/event，RTSP reader 通过有界 handoff 交包。纯转码支持 MMAP 一次原始帧复制或 DMA-BUF 借帧；Encoder input 回收在其 owner 内完成，Decoder capture 由 Decoder owner 归还。AI 路径通过 latest mailbox、固定 UDMA 槽位和 NPU 队列连接各级，详见 [VPU pipeline 软件架构](deps/modelzoo_utils/vpu_pipeline.md)；各程序和运行命令见 [Webcam + VPU](examples/0_datapath/Webcam+VPU/README.md)。随包 FFmpeg 头文件与链接库 ABI 在打开输入时校验；驱动兼容性、异帧率多会话吞吐和长稳仍需按实际程序版本上板验证。

## 选择一个示例构建和运行

先准备匹配的 AArch64 Linux 交叉工具链、Icraft SDK 和板端 Runtime。获取仓库后，使用 Git LFS 拉取所选示例及依赖所需的大文件；确认 JSON/RAW 已实体化。CMake 必须能找到示例要求的 Icraft package，安装位置非默认时通过 `CMAKE_PREFIX_PATH` 指向实际 SDK。

以下命令在仓库根目录执行，构建 BY 的 SDI YOLOv5 文件输出程序：

```bash
cmake -S 'examples/1_single_input+ai/PLin+SingleNet+VPU' \
  -B build/BY-yolov5 -DTARGET_CHIP=BY \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++
cmake --build build/BY-yolov5 \
  --target 'sdicamera+yolov5+vpu2file' --parallel 2
```

ZG 使用独立构建目录并设置 `-DTARGET_CHIP=ZG`。仅有 BY 资产的示例不能靠切换这个变量完成移植。部分示例固定了工具链路径，迁移环境时还需核对其 `CMakeLists.txt`。

将生成的程序放入板端对应示例目录，并保留 `configs/`、`imodel/` 及配置引用的资源。在该目录运行，YAML 作为位置参数传入：

```bash
./sdicamera+yolov5+vpu2file configs/BY/sdicamera+yolov5+vpu2file.yaml
```

相对资源路径以运行目录为基准。ZG FP16 使用同一文件输出 target 的 ZG 构建，配置为 [sdicamera+yolov5fp16+vpu2file.yaml](examples/1_single_input+ai/PLin+SingleNet+VPU/configs/ZG/sdicamera+yolov5fp16+vpu2file.yaml)。YOLOv5 + TarDAL 的构建目标和运行方法见其 [独立说明](examples/3_multi_inputs/MultiPSin+MultiNets+Save2File/README.md)。

## 模型资产与版本

截至 2026-09-11，已跟踪的各示例 `imodel/` 目录共有 **32 个 JSON、25 个 RAW**。下表版本来自 JSON 元数据；RAW 没有独立版本字段，应按示例配置与 JSON 配对使用。这里统计文件数量，不把不同路径的相同内容去重，也不包括 `model_compile/` 等目录中的编译来源资料。

| 模型范围 | JSON 数量 | 编译器 / XIR 版本 | 使用说明 |
| --- | :---: | --- | --- |
| 主线 BY / ZG 模型，含 ZG FP16 | 29 | `v3.36.1` / `3.36.1.0` | 主线 SDK/Runtime 为 3.36.1；按具体平台、输入尺寸和算子边界选择 |
| [SDI YOLOv5 ZG INT8 资产](examples/1_single_input+ai/PLin+SingleNet+VPU/imodel/ZG/int8) | 1 | `v3.36.0` / `3.36.0.1` | 单独保留的 INT8 模型，不能当作 FP16 配置的替代文件 |
| [YOLOv5 + TarDAL 文件输入资产](examples/3_multi_inputs/MultiPSin+MultiNets+Save2File/imodel/BY) | 2 | `v3.31.0` / `3.31.0.0` | 该示例说明指定 SDK/Runtime 3.31.1，按其独立环境使用 |

BY 的目标字段为 `@buyit`，ZG 为 `@zhuget(330)`。多路 BY 示例可能由多个输入端口 JSON 共用一个 RAW；Webcam BY 同时保留不同输入尺寸的模型。选择资产时同时核对 YAML、JSON、RAW、端口、输入尺寸、dtype/layout 和位流，不能只按文件名判断版本。

新模型接入流程见 [模型准备](.agents/skills/fpai-ref-design-prepare-model/SKILL.md) 和 [模型集成入口](.agents/skills/fpai-ref-design-integrate-model/SKILL.md)。

## 调试与工具

阶段调试沿用 `icraft3.36` 的源码 bitmask：具体 input、NPU 和 output stage 各自定义
`OPT_DEBUG_FLAGS`，直接组合 `BIT_MASK_n` 后重新编译。bit0 是逐帧 DEBUG；bit1 以上才会
导出 ImageMake、Session JSON、tensor 或 FTMP。CMake 和 YAML 不再传递全局调试位。

YAML `sys.profile` 只控制固定窗口性能统计，统计使用 INFO；`sys.log_level` 只控制日志
可见性，默认 `info`。三者的位值、源码入口、输出目录和 ZG 输入替换用法见
[调试说明](deps/modelzoo_utils/debugging.md)。

| 工具 / 流程 | 用途 |
| --- | --- |
| [analyze_ftmp.py](tools/analyze_ftmp.py)、[visualize_ftmp.py](tools/visualize_ftmp.py)、[ftmp2image.py](tools/ftmp2image.py) | 分析、可视化和转换 FTMP |
| [compare_ftmp_binaries.py](tools/compare_ftmp_binaries.py)、[compare_png_binary.py](tools/compare_png_binary.py) | 比较张量及图像结果 |
| [high_precision_clock](tools/high_precision_clock) | 高精度计时工具与说明 |
| [build_all_examples.sh](tools/build_all_examples.sh) | 遍历所有 CMake 工程；不自动过滤平台和 SDK 版本例外，日常集成按上面的命令选择单个工程 |
| [板端调试](.agents/skills/fpai-ref-design-board-debug/SKILL.md)、[CustomOp 调试](.agents/skills/fpai-ref-design-debug-customop/SKILL.md) | 定位初始化、执行与硬算子边界问题 |
| [数据通路验证](.agents/skills/fpai-ref-design-validate-datapath/SKILL.md)、[运行时优化](.agents/skills/fpai-ref-design-optimize-runtime/SKILL.md) | 模型无关通路验证、性能与稳定性分析 |
| [交付流程](.agents/skills/fpai-ref-design-package-delivery/SKILL.md)、[create_delivery_package.sh](create_delivery_package.sh) | 整理客户交付包；脚本中的源路径、平台、示例和版本需按实际交付修改 |


# 位流汇总

## 100TAI(BUYI)

悟空开发板参考实现。

* 单路PLIN+pHDMI显示参考实现(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+pHDMI%e6%98%be%e7%a4%ba%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25060601/)

* 单路PLIN+VPU编码参考实现(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+VPU%e7%bc%96%e7%a0%81%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25060601/)

* 多路PLIN+两路网络摄像头参考设计(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%a4%9a%e8%b7%afPLIN+%e4%b8%a4%e8%b7%af%e7%bd%91%e7%bb%9c%e6%91%84%e5%83%8f%e5%a4%b4%e5%8f%82%e8%80%83%e8%ae%be%e8%ae%a1/25060601/)

* 多路PLIN+VPU编码参考实现(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%a4%9a%e8%b7%afPLIN+VPU%e7%bc%96%e7%a0%81%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25060601/)

* WK单板_Host_IN参考设计_弱Host版本(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/WK%e5%8d%95%e6%9d%bf_Host_IN%e5%8f%82%e8%80%83%e8%ae%be%e8%ae%a1_%e5%bc%b1Host%e7%89%88%e6%9c%ac/25060601/)

* 附：CustomOP集合位流（仅供软件Demo测试用）(ver 25060601)

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e9%99%84%ef%bc%9aCustomOP%e9%9b%86%e5%90%88%e4%bd%8d%e6%b5%81%ef%bc%88%e4%bb%85%e4%be%9b%e8%bd%af%e4%bb%b6Demo%e6%b5%8b%e8%af%95%e7%94%a8%ef%bc%89/25060601/)

## 30TAI(ZHUGE)

悟净开发板参考实现。

说明：v3.36.1版本位流兼容v3.36.1版本的Icraft和参考实现

* 单路PLIN+VPU编码_MIG_axi接口（外置detpost）参考实现（ver 25122301）

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36.1/30TAI/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e5%87%80%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+VPU%e7%bc%96%e7%a0%81_MIG_axi%e6%8e%a5%e5%8f%a3%ef%bc%88%e5%a4%96%e7%bd%aedetpost%ef%bc%89%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25122301/)

* 单路PLIN+pHDMI（外置detpost）参考实现（ver 25122301）

    [下载链接](https://download.fdwxhb.com/data/04_FPAI/02_Icraft/v3.36.1/30TAI/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e5%87%80%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+pHDMI%ef%bc%88%e5%a4%96%e7%bd%aedetpost%ef%bc%89%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25122301/)

* PCIEHOSTIN位流：TODO
