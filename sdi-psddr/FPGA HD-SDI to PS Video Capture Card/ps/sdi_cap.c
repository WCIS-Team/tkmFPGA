/*============================================================================
 * sdi_cap.c -- 数据搬运通路的 userspace 驱动。
 *
 * 做什么：
 *   1. 通过 /dev/mem 配置与读状态（板上没有这个 PL 块的驱动，也不该为了
 *      第一次点亮去加一个）
 *   2. 把 PS DDR 里的缓冲映射给进程，让帧可以被直接读走，不需要拷贝
 *
 * ★ 帧格式 ★
 *   PL 写进来的是**逐字节等于 SDI 口收到的 Y'CbCr 4:2:2 8bit**，
 *   16 bit/像素，小端：
 *     像素偶数列：[15:8]=Y'  [7:0]=Cb 或 Cr
 *     像素奇数列：[15:8]=Y'  [7:0]=另一个色度
 *   没有做色彩空间转换、没有做缩放、没有做任何滤波。
 *
 * ★ 帧边界 ★
 *   PL 不切帧，只在 vsync 到达时记下当时的写地址（FRAME_ADDR）。
 *   软件轮询 FRAME_ADDR：值变了就是一帧开始。帧长用
 *   ROW_BYTES = MEAS_W*2、FRAME_BYTES = MEAS_H*MEAS_W*2 自己算。
 *   帧和帧之间是连续的，中间没有空洞——写帧器从不停止。
 *
 *   所以读帧时要注意环形回绕：地址要自己加环长取模。
 *
 * 板上编译（不需要容器，板上有 gcc）：
 *   gcc -O2 -DSDI_CAP_DEMO -o demo sdi_cap.c
 *   ./demo 10 frame.pgm 0x<udmabuf 的物理地址>
 *==========================================================================*/
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/ioctl.h>   // _IOWR，给 udmabuf 的 ioctl 号用
#include <stdint.h>
#include <time.h>

#include "sdi_cap.h"

/* udmabuf ioctl, 见 include/uapi/linux/udmabuf.h */
#define UDMABUF_CREATE_CMD  _IOWR(100, 1, struct udmabuf_create)
#define UDMABUF_SYNC_CMD    _IOWR(100, 3, struct udmabuf_sync)

struct udmabuf_create {
    uint64_t memfd;
    uint64_t offset;
    uint64_t size;
    uint64_t flags;
};

struct udmabuf_sync {
    uint64_t buffer;
    uint64_t flags;
    uint32_t status;
};
#define UDMABUF_SYNC_WRITE  (1U << 0)

#define SDI_CAP_DRAM_BASE   0x00000000UL
#define SDI_CAP_DRAM_SIZE   0x40000000UL   /* PS DDR 1 GB */

/* sdi_cap_check_buffer() 里没有写 "pa < SDI_CAP_DRAM_BASE" 这个下界测试，
 * 因为它在这里是恒假的死代码（gcc -Wtype-limits 会报）。
 * 一旦哪天 PS DDR 不再从 0 开始，静态断言会挡下来，而不是让检查悄悄失效。 */
_Static_assert(SDI_CAP_DRAM_BASE == 0UL,
               "check_buffer dropped the lower-bound test; re-add it");

/*---------------------------------------------------------------------------*/
typedef struct {
    int      memfd;
    volatile uint32_t *regs;
    void    *ring_va;
    uint64_t ring_pa;
    uint32_t ring_len;
} sdi_cap_t;

static inline uint32_t rd(sdi_cap_t *c, unsigned off)
{
    return c->regs[off >> 2];
}
static inline void wr(sdi_cap_t *c, unsigned off, uint32_t v)
{
    c->regs[off >> 2] = v;
}

/*---------------------------------------------------------------------------*/
int sdi_cap_check_buffer(unsigned long pa, size_t len)
{
    /* 顺序很重要：先排除溢出，再判下界，最后判上界。**绝不能先算 pa+len**。
     *
     * ARM 上 unsigned long 是 32 位，pa + len 会回绕：
     *     pa = 0xFFFFFF00, len = 0x200  ->  pa + len = 0x100
     * 回绕之后 0x100 <= 0x40000000，于是这个明显越界的地址被当成
     * "合法的 DDR 起始地址"放行，用户拿到的是一个指向别处的指针。
     *
     * gcc 的 -Wtype-limits 会报 "pa < SDI_CAP_DRAM_BASE 恒为假"：
     * 那是对的，Zynq-7000 的 PS DDR 物理地址从 0 开始。但那个下界测试
     * 恰恰是最不需要写的那个 —— 写成对称的样子只是让人误以为这里有检查。
     * 下面的静态断言保证它一旦不是 0，编译就会失败提醒补回来。 */
    const unsigned long end = SDI_CAP_DRAM_BASE + SDI_CAP_DRAM_SIZE;

    if (len == 0) {
        fprintf(stderr, "sdi_cap: buffer length is zero\n");
        return -1;
    }
    if (pa + len < pa) {                 /* unsigned 回绕 */
        fprintf(stderr,
                "sdi_cap: buffer 0x%lx + %lu wraps around\n", pa, (unsigned long)len);
        return -1;
    }
    if (pa + len > end) {
        fprintf(stderr,
                "sdi_cap: buffer 0x%lx..0x%lx is outside PS DDR (0x%lx..0x%lx)\n",
                pa, pa + len, SDI_CAP_DRAM_BASE, end);
        return -1;
    }
    return 0;
}

/*---------------------------------------------------------------------------*/
/* mmap 的 offset 必须页对齐。用 sysconf 问内核，不依赖 PAGE_SIZE 宏 ——
 * glibc 只在 __USE_MISC 下才从 <limits.h> 暴露它，换个 -std 或换个 libc
 * 就没了。而且某些内核/配置下页不是 4 KiB，写死 4096 会是错的。 */
static long sdi_cap_page_size(void)
{
    static long ps = 0;
    if (ps == 0) {
        ps = sysconf(_SC_PAGESIZE);
        if (ps <= 0) ps = 4096;
    }
    return ps;
}

int sdi_cap_open(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len)
{
    memset(c, 0, sizeof(*c));
    c->memfd  = -1;
    c->ring_pa = ring_pa;
    c->ring_len = ring_len;

    if (sdi_cap_check_buffer((unsigned long)ring_pa, ring_len) != 0) return -1;

    c->memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (c->memfd < 0) { perror("open /dev/mem"); return -1; }

    void *r = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED,
                   c->memfd, SDI_CAP_BASE);
    if (r == MAP_FAILED) { perror("mmap regs"); close(c->memfd); return -1; }
    c->regs = (volatile uint32_t *)r;

    uint32_t id = rd(c, SDI_CAP_ID);
    if (id != SDI_CAP_MAGIC) {
        fprintf(stderr,
                "sdi_cap: bad magic 0x%08x at 0x%08x (expected 0x%08x)\n"
                "         -> 位流没加载，或者这块位流不是采集通路\n",
                id, SDI_CAP_BASE, SDI_CAP_MAGIC);
        munmap((void *)c->regs, 0x1000);
        close(c->memfd);
        return -2;
    }

    /* 只读映射：帧是 PL 写的，用户侧不需要写权限。
     *
     * mmap 的 offset 必须是页对齐的。udmabuf 给的偏移通常是对齐的，但这里
     * 不校验就直接调 mmap 的话，一旦不对齐，内核返回 EINVAL，
     * perror 只会打一句 "Invalid argument"，看不出是哪里不对。
     * 先自己查清楚。 */
    const unsigned long pgsz = (unsigned long)sdi_cap_page_size();
    if ((ring_pa % (uint64_t)pgsz) != 0) {
        fprintf(stderr,
                "sdi_cap: buffer 0x%lx is not %lu-byte page aligned\n",
                ring_pa, pgsz);
        munmap((void *)c->regs, 0x1000);
        close(c->memfd);
        return -1;
    }
    if (ring_pa > (uint64_t)INT64_MAX) {
        fprintf(stderr, "sdi_cap: buffer 0x%lx does not fit an off_t\n", ring_pa);
        munmap((void *)c->regs, 0x1000);
        close(c->memfd);
        return -1;
    }

    /* 环至少要装得下一整帧，否则每一帧都在覆盖上一帧，永远看不到完整的一帧。
     * 1080p 的 4:2:2 是 1920*1080*2 = 4147200 字节（不含消隐，因为 PL 只写
     * 有效像素）。这不拦下来，只警告 —— 调试时故意用小环是合理的。 */
    if (ring_len < 1920u * 1080u * 2u) {
        fprintf(stderr,
                "sdi_cap: WARNING ring is %u bytes, less than one 1080p 4:2:2 frame "
                "(%u); every frame will overwrite the previous one\n",
                ring_len, 1920u * 1080u * 2u);
    }

    c->ring_va = mmap(NULL, ring_len, PROT_READ, MAP_SHARED, c->memfd,
                      (off_t)ring_pa);
    if (c->ring_va == MAP_FAILED) {
        perror("mmap ring");
        munmap((void *)c->regs, 0x1000);
        close(c->memfd);
        return -1;
    }
    return 0;
}

void sdi_cap_close(sdi_cap_t *c)
{
    if (c->ring_va) munmap(c->ring_va, c->ring_len);
    if (c->regs)    munmap((void *)c->regs, 0x1000);
    if (c->memfd >= 0) close(c->memfd);
}

/*---------------------------------------------------------------------------*/
/* 开始搬运。
 *
 * 注意这里**没有**幅面参数、**没有**帧率参数——PL 不需要知道源是什么格式。
 * 软件要判断格式，自己读 MEAS_* / FPS_X100 / RX_* 就行。
 *---------------------------------------------------------------------------*/
int sdi_cap_start(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len)
{
    wr(c, SDI_CAP_CTRL, 0);                      /* 先停，避免半配置状态开跑 */
    wr(c, SDI_CAP_INT_STATUS, 0xFFFFFFFFu);      /* INT_STATUS 是写 1 清零 */
    /* ERR_STAT 是只读的：往它写 1 什么也不会发生，清零靠下面的 REARM */

    wr(c, SDI_CAP_BUF_ADDR_L, (uint32_t)(ring_pa & 0xFFFFFFFFu));
    wr(c, SDI_CAP_BUF_ADDR_H, (uint32_t)(ring_pa >> 32));
    wr(c, SDI_CAP_RING_BYTES,  ring_len);

    wr(c, SDI_CAP_REARM, 1);                    /* 装载起始地址、清计数器与 ERR_STAT */
    wr(c, SDI_CAP_CTRL, SDI_CAP_CTRL_ENABLE | SDI_CAP_CTRL_IRQ_EN);
    return 0;
}

/* 从 t0 到 now 经过的毫秒数，纳秒借位要处理 */
static long elapsed_ms(const struct timespec *t0, const struct timespec *now)
{
    long s  = (long)(now->tv_sec - t0->tv_sec);
    long ns = (long)(now->tv_nsec - t0->tv_nsec);

    if (ns < 0) { s -= 1; ns += 1000000000L; }
    return s * 1000L + ns / 1000000L;
}

int sdi_cap_wait_drained(sdi_cap_t *c, unsigned timeout_ms)
{
    /* 厂商《PS-PL AXI HP 接口：事务计数与复位语义》里 L1/L3/L4 三种场景
     * 都要求"复位落在链路上"之前先把接口排空，而 PS 侧没有在途事务计数
     * （没有 AFI，也没有 RCOUNT/RACOUNT），判空只能问 PL。
     * 这里读的是写帧器自己报的 idle 位：inflight==0 且状态机已回空闲。
     *
     * idle 是 cam_clk 域过来的单 bit（跨域用了两级同步），最坏可能比真实
     * 状态晚几个 fclk0 周期，所以不能读到一次 1 就返回，要求连续
     * DRAIN_STABLE 次都是 1 才认。 */
    const unsigned DRAIN_STABLE = 3;
    struct timespec t0, now;
    unsigned stable = 0;

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        if (rd(c, SDI_CAP_WR_IDLE) & SDI_CAP_WR_IDLE_IDLE) {
            if (++stable >= DRAIN_STABLE)
                return 0;
        } else {
            stable = 0;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (elapsed_ms(&t0, &now) >= (long)timeout_ms)
            return -ETIMEDOUT;
    }
}

int sdi_cap_stop(sdi_cap_t *c)
{
    wr(c, SDI_CAP_CTRL, 0);
    return sdi_cap_wait_drained(c, 100);
}

/*---------------------------------------------------------------------------*/
typedef struct {
    int      sig_locked;
    int      geom_valid;
    int      busy;
    int      starving;
    unsigned width, height;        /* 实测 */
    unsigned row_bytes;            /* = width*2 */
    uint64_t frame_bytes;
    unsigned fps_x100;
    unsigned fps_class;
    unsigned family;
    unsigned rx_mode;
    uint32_t frames;
    uint32_t beats;
    uint32_t frame_addr;
    uint32_t wr_addr;
    uint32_t err;
    uint32_t int_status;
} sdi_cap_info;

void sdi_cap_get_info(sdi_cap_t *c, sdi_cap_info *i)
{
    uint32_t st = rd(c, SDI_CAP_STATUS);
    memset(i, 0, sizeof(*i));
    i->sig_locked = (st & SDI_CAP_ST_SIG_LOCKED) != 0;
    i->geom_valid = (st & SDI_CAP_ST_GEOM_VALID) != 0;
    i->busy       = (st & SDI_CAP_ST_BUSY)       != 0;
    i->starving   = (st & SDI_CAP_ST_STARVING)   != 0;
    i->width      = rd(c, SDI_CAP_MEAS_W);
    i->height     = rd(c, SDI_CAP_MEAS_H);
    i->row_bytes  = rd(c, SDI_CAP_ROW_BYTES);
    i->frame_bytes= rd(c, SDI_CAP_FRAME_BYTES);
    i->fps_x100   = rd(c, SDI_CAP_FPS_X100);
    i->fps_class  = rd(c, SDI_CAP_FPS_CLASS);
    i->family     = rd(c, SDI_CAP_RX_FAMILY) & 0xF;
    i->rx_mode    = rd(c, SDI_CAP_RX_MODE) & SDI_CAP_MODE_MASK;
    i->frames     = rd(c, SDI_CAP_FRAME_CNT);
    i->beats      = rd(c, SDI_CAP_BEATS);
    i->frame_addr = rd(c, SDI_CAP_FRAME_ADDR);
    i->wr_addr    = rd(c, SDI_CAP_WR_ADDR);
    i->err        = rd(c, SDI_CAP_ERR_STAT);
    i->int_status = rd(c, SDI_CAP_INT_STATUS);
}

const char *sdi_cap_family_name(unsigned f)
{
    switch (f) {
    case SDI_CAP_FAM_ST274:  return "SMPTE 274M  1920x1080";
    case SDI_CAP_FAM_ST296:  return "SMPTE 296M  1280x720";
    case SDI_CAP_FAM_2048_2: return "SMPTE 2048-2 2048x1080";
    case SDI_CAP_FAM_ST295:  return "SMPTE 295M  1920x1080 sqpix";
    case SDI_CAP_FAM_NTSC:   return "NTSC        720x486";
    case SDI_CAP_FAM_PAL:    return "PAL         720x576";
    default:                 return "unknown";
    }
}

const char *sdi_cap_fps_class_name(unsigned c)
{
    static const char *n[] = { "unknown", "~25", "~30", "~50", "~60" };
    return c < 5 ? n[c] : "?";
}

void sdi_cap_print_info(const sdi_cap_info *i)
{
    printf("signal     : %s\n",
           i->sig_locked ? "SDI transport LOCKED" : "no lock (格式没认出来)");
    printf("link       : %s\n",
           i->rx_mode == SDI_CAP_MODE_HD ? "HD-SDI 1.485G (SMPTE 292M)" :
           i->rx_mode == SDI_CAP_MODE_SD ? "SD-SDI 270M  (SMPTE 259M)" :
                                           "3G-SDI  2.97G  (SMPTE 424M)");
    printf("family     : %s (0x%x)\n", sdi_cap_family_name(i->family), i->family);
    printf("geometry   : %ux%u  row=%u B  frame=%llu B  %s\n",
           i->width, i->height, i->row_bytes,
           (unsigned long long)i->frame_bytes,
           i->geom_valid ? "(valid)" : "(还没测出)");
    printf("frame rate : %u.%02u fps -> %s\n",
           i->fps_x100 / 100, i->fps_x100 % 100,
           sdi_cap_fps_class_name(i->fps_class));
    printf("frames     : %u   beats written: %u\n", i->frames, i->beats);
    printf("addresses  : last frame @0x%08x, next write @0x%08x\n",
           i->frame_addr, i->wr_addr);
    printf("writer     : %s%s\n", i->busy ? "busy" : "idle",
           i->starving ? "  (starving: 长时间没有像素进来)" : "");
    if (i->err)
        printf("errors     : 0x%08x%s%s\n", i->err,
               (i->err & SDI_CAP_ERR_FIFO_FULL) ? " FIFO_FULL" : "",
               (i->err & SDI_CAP_ERR_AXI_RESP)  ? " AXI_RESP"  : "");
    if (i->int_status)
        printf("interrupts : 0x%08x\n", i->int_status);
}

/*---------------------------------------------------------------------------*/
/* 取一帧。
 *
 * FRAME_ADDR 是"上一次 vsync 时的写地址"。读到它就说明一整帧已经写完了
 * （前提是软件读得比 PL 写得快，否则环形回绕会覆盖）。
 *
 * 返回值 0 表示成功。
 *---------------------------------------------------------------------------*/
int sdi_cap_grab(const sdi_cap_t *c, uint32_t frame_addr,
                 unsigned w, unsigned h, void *dst)
{
    const uint8_t *base = (const uint8_t *)c->ring_va;
    size_t row = (size_t)w * 2;
    uint32_t off = frame_addr - (uint32_t)c->ring_pa;

    /* 行会跨越环尾，逐行处理 */
    for (unsigned y = 0; y < h; y++) {
        size_t src = off + (size_t)y * row;
        if (src + row <= c->ring_len) {
            memcpy((uint8_t *)dst + (size_t)y * row, base + src, row);
        } else {
            size_t first = c->ring_len - src;
            memcpy((uint8_t *)dst + (size_t)y * row, base + src, first);
            memcpy((uint8_t *)dst + (size_t)y * row + first, base, row - first);
        }
    }
    return 0;
}

/*---------------------------------------------------------------------------*/
/* 存成 PGM 便于肉眼验收。4:2:2 的 Y' 就是每个像素对的第一个字节，
 * 不需要任何色彩转换。 */
int sdi_cap_dump_pgm(const void *frame, unsigned w, unsigned h, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); return -1; }
    fprintf(f, "P5\n%u %u\n255\n", w, h);
    const uint8_t *p = (const uint8_t *)frame;
    for (unsigned y = 0; y < h; y++)
        for (unsigned x = 0; x < w; x++)
            fputc(p[(size_t)y * w * 2 + x * 2], f);
    fclose(f);
    return 0;
}

#ifdef SDI_CAP_DEMO
int main(int argc, char **argv)
{
    unsigned      seconds  = 10;
    const char   *out_pgm  = "frame.pgm";
    unsigned long ring_pa  = 0;     /* 必须是用户态导出的 udmabuf */
    uint32_t      ring_len = 32u * 1024u * 1024u;   /* 32 MB，够存 8 帧 1080p */

    if (argc > 1) seconds   = (unsigned)atoi(argv[1]);
    if (argc > 2) out_pgm   = argv[2];
    if (argc > 3) ring_pa   = strtoul(argv[3], NULL, 0);
    if (argc > 4) ring_len  = (uint32_t)strtoul(argv[4], NULL, 0);

    if (ring_pa == 0) {
        fprintf(stderr,
"usage: %s [seconds] [out.pgm] [ring_phys_addr] [ring_bytes]\n"
"\n"
"ring_phys_addr 必须是用户态导出的 udmabuf。这里没有安全的默认值：\n"
"PS DDR 只有 1 GB 而且内核住在里面，写死一个物理地址很可能踩到在用的内存，\n"
"而且失败现象是一帧莫名其妙的花屏而不是报错。\n"
"\n"
"导出方法（见 sdi_cap.c 顶部注释 / docs/上板检查.md）：\n"
"    int fd = open(\"/dev/udmabuf0\", O_RDWR);\n"
"    struct udmabuf_create c = { .memfd=(uint64_t)fd, .offset=0,\n"
"                                .size=len, .flags=0 };\n"
"    ioctl(fd, UDMABUF_CREATE_CMD, &c);\n"
"    ioctl(fd, UDMABUF_SYNC_CMD, &c);   /* c.flags = UDMABUF_SYNC_WRITE */\n"
"    pa = c.offset;\n", argv[0]);
        return 2;
    }

    sdi_cap_t cap;
    if (sdi_cap_open(&cap, ring_pa, ring_len) != 0) return 1;

    sdi_cap_info i;
    sdi_cap_get_info(&cap, &i);
    printf("--- before start ---\n"); sdi_cap_print_info(&i);

    sdi_cap_start(&cap, ring_pa, ring_len);

    printf("\n--- streaming for %u s into 0x%lx (%u MB) ---\n",
           seconds, ring_pa, ring_len >> 20);
    uint32_t last_f = 0, last_b = 0;
    for (unsigned s = 0; s < seconds; s++) {
        usleep(1000000);
        sdi_cap_get_info(&cap, &i);
        printf("[%3us] frames=%-5u (+%u)  %ux%u  %u.%02u fps  "
               "wr@0x%08x  err=0x%x%s\n",
               s + 1, i.frames, i.frames - last_f, i.width, i.height,
               i.fps_x100 / 100, i.fps_x100 % 100, i.wr_addr, i.err,
               i.starving ? " STARVING" : "");
        last_f = i.frames; last_b = i.beats;
    }
    (void)last_b;

    sdi_cap_get_info(&cap, &i);
    printf("\n--- final ---\n"); sdi_cap_print_info(&i);

    if (i.geom_valid && i.width && i.height && i.height < 100000) {
        size_t need = (size_t)i.width * i.height * 2;
        void  *frame = malloc(need);
        if (frame && sdi_cap_grab(&cap, i.frame_addr, i.width, i.height, frame) == 0) {
            sdi_cap_dump_pgm(frame, i.width, i.height, out_pgm);
            printf("\nwrote %s (%ux%u, PGM = Y' only)\n", out_pgm, i.width, i.height);
        }
        free(frame);
    } else {
        printf("\n幅面还没测出来，没抓帧。\n"
               "  sig_locked=%d  meas_w=%u meas_h=%u\n"
               "  没锁定的话先去查 OBS 是不是把摄像机切到 CVBS 了，\n"
               "  以及跳线 J26/J27 在不在 SDI 位。\n",
               i.sig_locked, i.width, i.height);
    }

    sdi_cap_stop(&cap);
    sdi_cap_close(&cap);
    return 0;
}
#endif /* SDI_CAP_DEMO */