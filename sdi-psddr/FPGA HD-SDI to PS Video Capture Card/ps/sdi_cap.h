/*============================================================================
 * sdi_cap.h -- 寄存器定义（悟净 FMQL30TAI SDI 数据搬运通路，顶层 sdi_cap_top）
 *
 * 基址 0x8000_0000（PS 侧 GP1 AXI 窗口），寄存器窗口 64 KiB。
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

#define SDI_CAP_BASE          0x80000000u
#define SDI_CAP_MAGIC         0x53444943u   /* 'SDIC' */
#define SDI_CAP_VERSION       0x00010000u

/* --- 寄存器偏移 --- */
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
#define SDI_CAP_BUF_ADDR_H    0x44
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

/* --- 写帧器排空状态 --- */
  /* PS 侧看不到 S_AXI_HP2 上的在途事务数（没有 AFI，也没有 RCOUNT/RACOUNT），
   * AXI 协议本身也不定义这种信号，所以"能不能复位 PL / 能不能重配置"
   * 只能靠 PL 自己报出来。复位或重配置前必须等这个位变成 1。
   * 注意：IDLE=1 只说明没有在途写事务，不代表 FIFO 空了 ——
   * 源停下来时最多 15 拍（120 字节）会合法地留在 FIFO 里。 */
  #define SDI_CAP_WR_IDLE       0x74
  #define SDI_CAP_WR_IDLE_IDLE  (1u << 0)

  /* --- CTRL --- */
#define SDI_CAP_CTRL_ENABLE   (1u << 0)
#define SDI_CAP_CTRL_IRQ_EN   (1u << 1)

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

/* --- RX_MODE --- */
#define SDI_CAP_MODE_MASK     3u
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
 * 清零的唯一办法是写 REARM（见寄存器手册 §六）。 */
#define SDI_CAP_ERR_FIFO_FULL (1u << 0)  /* FIFO 满，整拍（8 字节）被丢掉 */
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

#endif /* SDI_CAP_H */