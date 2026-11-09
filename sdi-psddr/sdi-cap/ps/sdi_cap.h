/*============================================================================
 * sdi_cap.h -- 寄存器定义 + 驱动 API（悟净 FMQL30TAI SDI 数据搬运通路）
 *
 * 基址 0x8000_0000（PS 侧 GP1 AXI 窗口）。
 * ★ 寄存器窗口 4 KiB（RTL 的 C_S_AXI_ADDR_WIDTH=12，按 4 KiB 译码）★
 *   2026-11-10 修：此前这里写"64 KiB"，与 RTL 不符。GP1 的 4 GiB 地址空间
 *   里 0x8000_0000..0x8000_0FFF 归这块寄存器，超出 4 KiB 的访问行为未定义
 *   （落进下一个从设备的译码区间）。见 docs/寄存器手册.md §二。
 *
 * ★ 这个块不做格式判断 ★
 *   寄存器里没有"目标幅面""目标帧率"这类会影响数据通路的配置。
 *   SDI 口进来什么像素，PL 就往 PS DDR 写什么像素，一个字节都不改、
 *   一帧都不丢。格式解释是软件的事。
 *
 *   软件想知道源是什么，只读这几组：
 *     MEAS_W / MEAS_H / MEAS_FPER / FPS_X100 / RX_*  —— 实测值
 *   软件要控制，只写这几项：
 *     CTRL.ENABLE / BUF_ADDR / RING_BYTES / REARM    —— 开、地址、环长、重新装载
 *
 * 板级前提：SDI 前端固定在 HD-SDI 1.485 Gb/s，接收时钟恒为 74.25 MHz。
 * 所以帧率是实测帧周期除出来的（fps = 74250000 / MEAS_FPER），不是查表。
 *==========================================================================*/
#ifndef SDI_CAP_H
#define SDI_CAP_H

#include <stdint.h>
#include <stddef.h>   /* size_t，驱动 API 用 */

#define SDI_CAP_BASE          0x80000000u
#define SDI_CAP_MAGIC         0x53444943u   /* 'SDIC' */
#define SDI_CAP_VERSION       0x00010000u

/* --- 寄存器偏移（窗口 4 KiB，0x000..0x074 已定义，其余保留） --- */
#define SDI_CAP_ID            0x00
#define SDI_CAP_VERSION_R     0x04
#define SDI_CAP_CTRL          0x08
#define SDI_CAP_STATUS        0x0C
#define SDI_CAP_MEAS_W        0x10   /* 实测有效像素/行 */
#define SDI_CAP_MEAS_H        0x14   /* 实测有效行/帧 */
#define SDI_CAP_MEAS_FPER     0x18   /* 实测帧周期，单位像素时钟 */
#define SDI_CAP_FPS_X100      0x1C   /* 实测帧率 x100，3000 = 30.00 */
#define SDI_CAP_RX_MODE       0x20
#define SDI_CAP_RX_FAMILY     0x24
#define SDI_CAP_RX_RATE       0x28
#define SDI_CAP_EXP_FPS       0x2C   /* 软件声明的期望，仅用于对比，不门控 */
#define SDI_CAP_FPS_CLASS     0x30   /* 实测帧率归类 */
#define SDI_CAP_FPS_MATCH     0x34   /* 实测 == 声明 ? */
#define SDI_CAP_ROW_BYTES     0x38   /* 建议行字节数 = MEAS_W*2 */
#define SDI_CAP_FRAME_BYTES   0x3C   /* 建议帧字节数 = MEAS_H*MEAS_W*2 */
#define SDI_CAP_BUF_ADDR_L    0x40
#define SDI_CAP_BUF_ADDR_H    0x44   /* ★ 2026-11-10 注（M3）：仅存储不参与译码。
                               * 写帧器只用低 32 位（sdi_stream_wr.v:152）——
                               * PS DDR 只有 1 GB，够用；写高 32 位没有效果，
                               * 读回的只是寄存器影子。留给将来的器件。 */
#define SDI_CAP_REARM         0x48   /* 写 1：按当前 BUF_ADDR 重新开始写 */
#define SDI_CAP_FRAME_CNT     0x4C   /* vsync 次数 */
#define SDI_CAP_FRAME_ADDR    0x50   /* 上一次 vsync 那一拍的字节地址（低 32 位）*/
#define SDI_CAP_WR_ADDR       0x54   /* 下一拍将写到的字节地址（低 32 位）*/
#define SDI_CAP_BEATS         0x58   /* 累计写了多少个 64bit 拍（= 4 像素 = 8 字节）*/
#define SDI_CAP_ERR_STAT      0x5C
#define SDI_CAP_INT_STATUS    0x60
#define SDI_CAP_INT_ENABLE    0x64
#define SDI_CAP_PIXCLK_HZ     0x68   /* 帧率换算用；HD-SDI 恒为 74250000 */
#define SDI_CAP_RING_BYTES    0x6C   /* 0 = 不环绕 */
#define SDI_CAP_LINE_CNT      0x70   /* 行计数（自由运行） */
#define SDI_CAP_WR_IDLE       0x74

/* --- 写帧器排空状态 ---
 * PS 侧看不到 S_AXI_HP2 上的在途事务数（没有 AFI，也没有 RCOUNT/RACOUNT），
 * AXI 协议本身也不定义这种信号，所以"能不能复位 PL / 能不能重配置"
 * 只能靠 PL 自己报出来。复位或重配置前必须等这个位变成 1。
 * 注意：IDLE=1 只说明没有在途写事务，不代表 FIFO 空了 ——
 * 源停下来时最多 15 拍（120 字节）会合法地留在 FIFO 里。 */
#define SDI_CAP_WR_IDLE_IDLE  (1u << 0)

/* --- CTRL --- */
#define SDI_CAP_CTRL_ENABLE   (1u << 0)
#define SDI_CAP_CTRL_IRQ_EN   (1u << 1)
/* ★ 2026-11-10 注（M10）：IRQ_EN 只开 PS 侧的位，
 * 还必须写 INT_ENABLE（0x64）选择中断源，s_axi_intr 才会真的动作。
 * 驱动的 start() 不再替用户置 IRQ_EN——不上中断的应用置了它只会
 * 白白多一条悬空的 pending 位。要用中断就自己写 INT_ENABLE。 */

/* --- STATUS --- */
#define SDI_CAP_ST_ENABLE     (1u << 8)
#define SDI_CAP_ST_BUSY       (1u << 9)
#define SDI_CAP_ST_SIG_LOCKED (1u << 10)  /* SDI 传输格式已锁（只上报，不门控） */
#define SDI_CAP_ST_GEOM_VALID (1u << 11)
#define SDI_CAP_ST_STARVING   (1u << 12)  /* 长时间没有像素进来 */
#define SDI_CAP_ST_ERR        (1u << 13)

/* --- EXP_FPS / FPS_CLASS --- */
#define SDI_CAP_FPS_UNSPEC    0u
#define SDI_CAP_FPS_25        1u
#define SDI_CAP_FPS_30        2u

#define SDI_CAP_FPSCLS_UNKNOWN 0u
#define SDI_CAP_FPSCLS_25      1u
#define SDI_CAP_FPSCLS_30      2u
#define SDI_CAP_FPSCLS_50      3u
#define SDI_CAP_FPSCLS_60      4u

/* --- RX_MODE ---
 * bit1:0 = 制式：00=HD 01=SD 10=3G（厂商 sdi_status 的 mode 字段）
 * bit2   = /1.001 标志（厂商 rx_m，SMPTE 的 "M" 位）：置位表示标称帧率
 *          还要除以 1.001 —— 29.97/59.94/119.88 那类。比较制式时**必须
 *          只看 bit1:0**，把 bit2 掩掉，否则 29.97 Hz 的源会被误判。
 * bit3.. 保留（读 0）。 */
#define SDI_CAP_MODE_MASK     3u          /* 制式 = RX_MODE & 3 */
#define SDI_CAP_MODE_M        (1u << 2)   /* /1.001 标志 */
#define SDI_CAP_MODE_HD       0u   /* HD-SDI 1.485G, SMPTE 292M */
#define SDI_CAP_MODE_SD       1u
#define SDI_CAP_MODE_3G       2u

/* --- RX_FAMILY --- */
#define SDI_CAP_FAM_ST274     0x0   /* 1920x1080 */
#define SDI_CAP_FAM_ST296     0x1   /* 1280x720  */
#define SDI_CAP_FAM_2048_2    0x2
#define SDI_CAP_FAM_ST295     0x3
#define SDI_CAP_FAM_NTSC      0x8   /* 720x486 */
#define SDI_CAP_FAM_PAL       0x9   /* 720x576 */

/* --- ERR_STAT（只读粘滞）---
 * 注意：**写它没有用**。这两个位住在写帧器里（clk_100m 域），
 * 清零的唯一办法是写 REARM（见寄存器手册 §六）。
 * ★ 2026-11-10 注（M5）：FIFO_FULL 指的是 PL 侧打包 FIFO（4 像素/拍那级）
 * 溢出丢整拍 —— DDR 环被软件读慢了**不会**在这置位（环形覆盖是设计内
 * 行为，PL 不知道软件读没读）。判断"读太慢"要用 FRAME_CNT / WR_ADDR
 * 自己算圈数。 */
#define SDI_CAP_ERR_FIFO_FULL (1u << 0)  /* PL 打包 FIFO 满，整拍（8 字节）被丢 */
#define SDI_CAP_ERR_AXI_RESP  (1u << 1)  /* AXI 写响应不是 OKAY */

/* --- INT_STATUS（置位锁存，写 1 清零）--- */
#define SDI_CAP_INT_FRAME     (1u << 0)  /* 收到一次 vsync */
#define SDI_CAP_INT_WR_ERR    (1u << 1)
#define SDI_CAP_INT_STARVING  (1u << 2)
#define SDI_CAP_INT_NO_SIGNAL (1u << 3)  /* 没有 SDI 信号 */

/* --- 默认值 --- */
#define SDI_CAP_PIXCLK_HZ_DEF 74250000u
#define SDI_CAP_ROW_BYTES_1080 (1920u * 2u)
#define SDI_CAP_FBYTES_1080   (1920u * 1080u * 2u)

/*===========================================================================
 * 驱动 API（实现在 sdi_cap.c）
 *===========================================================================*/

/* 打开后的句柄。内容是驱动私有的，调用方不要摸字段。 */
typedef struct {
    int      memfd;               /* /dev/mem 的 fd（寄存器窗口用），-1 = 未打开 */
    int      ringfd;              /* /dev/udmabuf0 的 fd（环映射用），-1 = 走了 /dev/mem 兜底 */
    volatile uint32_t *regs;      /* 寄存器窗口映射，NULL = 未映射 */
    void    *ring_va;             /* 环缓冲只读映射，NULL = 未映射 */
    uint64_t ring_pa;             /* 环缓冲物理地址 */
    uint64_t ring_off;            /* 环在 udmabuf 设备内的偏移（/dev/mem 兜底时为 0） */
    uint32_t ring_len;            /* 环缓冲字节数（必须 8 的倍数，见 open） */
    char     sync_cpu[200];       /* u-dma-buf 的 sync_for_cpu 路径，空 = 不需要同步 */
} sdi_cap_t;

/* 一次状态快照（sdi_cap_get_info 填充）。 */
typedef struct {
    int      sig_locked;          /* SDI 传输格式已锁 */
    int      geom_valid;          /* 幅面已测出（GEOM_VALID） */
    int      busy;                /* 写帧器状态机不空闲 */
    int      starving;            /* 长时间没有像素进来 */
    int      rx_m;                /* RX_MODE bit2：标称帧率还要 /1.001（29.97 类） */
    unsigned width, height;       /* 实测幅面 */
    unsigned row_bytes;           /* = width*2 */
    uint64_t frame_bytes;         /* = height*width*2 */
    unsigned fps_x100;            /* 实测帧率 x100 */
    unsigned fps_class;           /* FPSCLS_* */
    unsigned family;              /* FAM_* */
    unsigned rx_mode;             /* 制式 = RX_MODE & MODE_MASK（bit2 在 rx_m） */
    uint32_t frames;              /* FRAME_CNT：收到的 vsync 数 */
    uint32_t beats;               /* BEATS：累计 64bit 拍数 */
    uint32_t frame_addr;          /* FRAME_ADDR：当前正在写的帧的起始地址 */
    uint32_t wr_addr;             /* WR_ADDR：下一拍将写的地址 */
    uint32_t err;                 /* ERR_STAT */
    uint32_t int_status;          /* INT_STATUS */
} sdi_cap_info;

/* 物理地址区间检查（必须整体落在 PS DDR 内，不回绕）。0 = 通过。 */
int sdi_cap_check_buffer(unsigned long pa, size_t len);

/* 打开 /dev/mem，映射寄存器窗口与环缓冲（只读）。
 * ring_pa 必须页对齐；ring_len 必须 ≥ 8 字节且 **8 的倍数**——写帧器的
 * 末尾突发按整 8 字节拍向上取整，非 8 倍数的环会被写越界最多 7 字节。
 * 返回 0 = 成功；-1 = 参数/系统错误；-2 = 位流没加载（magic 不对）。 */
int  sdi_cap_open(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len);

/* 释放映射。对未打开（或打开失败）的句柄调用是安全的。 */
void sdi_cap_close(sdi_cap_t *c);

/* 配置并启动。内部：先停 + 排空在途事务（M8）→ 写地址/环长 →
 * 等跨域同步落位（M6）→ REARM → 使能。不置 IRQ_EN（见 CTRL 注释）。
 * 返回 0 = 成功；-ETIMEDOUT = 旧事务没排空（别重配，先查 PL 状态）。 */
int  sdi_cap_start(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len);

/* 停止（CTRL=0）并等写帧器排空。返回 0 = 已排空；-ETIMEDOUT = 超时。 */
int  sdi_cap_stop(sdi_cap_t *c);

/* 等写帧器空闲（inflight=0 且状态机回 IDLE）。见 sdi_cap_stop。 */
int  sdi_cap_wait_drained(sdi_cap_t *c, unsigned timeout_ms);

/* 读一轮状态寄存器进 *i。 */
void sdi_cap_get_info(sdi_cap_t *c, sdi_cap_info *i);

/* 人话打印一份 info（无返回值，出错面靠 get_info 的字段）。 */
void sdi_cap_print_info(const sdi_cap_info *i);

const char *sdi_cap_family_name(unsigned f);
const char *sdi_cap_fps_class_name(unsigned c);

/* 把 [frame_addr, frame_addr + w*h*2) 这帧从环缓冲拷到 dst，
 * 环尾自动回绕。frame_addr 必须落在环内；w*h*2 不得超过环长。
 * 返回 0 = 成功；-1 = 参数/地址越界（宁可失败也不读环外的内存）。 */
int  sdi_cap_grab(const sdi_cap_t *c, uint32_t frame_addr,
                  unsigned w, unsigned h, void *dst);

/* 4:2:2 里取 Y' 存成 PGM（肉眼验收用）。 */
int  sdi_cap_dump_pgm(const void *frame, unsigned w, unsigned h, const char *path);

#endif /* SDI_CAP_H */
