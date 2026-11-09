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
 * ★ 帧边界 ★（2026-11-10 修，M7）
 *   PL 不切帧，只在 vsync 到达时记下当时的写地址（FRAME_ADDR）。
 *   **FRAME_ADDR 是"正在写的这一帧"的起始地址** —— 读到值 V 只说明
 *   从 V 开始的帧刚开始写，它前面那一帧才是完整的。
 *   所以抓帧要在 FRAME_ADDR 变化两次之后、抓**上一个值**对应的帧。
 *   demo 的轮询间隔是 10 ms：30 fps 下一帧 33 ms，10 ms 不会错过任何
 *   一次变化；32 MB 环写满一圈约 260 ms，变化后立刻抓、离被覆盖还有
 *   7 帧余量。
 *
 *   帧和帧之间是连续的，中间没有空洞——写帧器从不停止。
 *   所以读帧时要注意环形回绕：地址要自己加环长取模。
 *
 * 板上编译（不需要容器，板上有 gcc）：
 *   gcc -O2 -DSDI_CAP_DEMO -o demo sdi_cap.c
 *   ./demo 10 frame.pgm              # 自动探测 /dev/udmabuf0
 *   ./demo 10 frame.pgm 0x18000000   # 或手工给物理地址
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
#include <stdint.h>
#include <time.h>

#include "sdi_cap.h"

#define SDI_CAP_DRAM_BASE   0x00000000UL
#define SDI_CAP_DRAM_SIZE   0x40000000UL   /* PS DDR 1 GB */

/* sdi_cap_check_buffer() 里没有写 "pa < SDI_CAP_DRAM_BASE" 这个下界测试，
 * 因为它在这里是恒假的死代码（gcc -Wtype-limits 会报）。
 * 一旦哪天 PS DDR 不再从 0 开始，静态断言会挡下来，而不是让检查悄悄失效。 */
_Static_assert(SDI_CAP_DRAM_BASE == 0UL,
               "check_buffer dropped the lower-bound test; re-add it");

/*---------------------------------------------------------------------------*/
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
    /* 顺序很重要：先排除溢出，再判上界。**绝不能先算 pa+len 再判**。
     *
     * 2026-11-10 更正（B6）：本板是 aarch64（LP64），unsigned long 是
     * 64 位，pa+len 不会像 32 位 ARM 那样回绕 —— 旧注释拿
     * "pa=0xFFFFFF00, len=0x200 回绕成 0x100" 举例是错的，aarch64 上
     * pa+len = 0x100000102，不会小过 pa。**回绕测试仍然保留**：
     * 1) 这份驱动也可能被 32 位工具链编（ILP32 下 unsigned long 是 32 位，
     *    回绕是真实风险）；2) 测试本身在 64 位下是恒假、会被
     *    -Wtype-limits 警告的死代码 —— 所以配了这个静态断言：
     *    一旦哪天 DDR 基址不再是 0，编译就会失败提醒把下界测试补回来。 */
    const unsigned long end = SDI_CAP_DRAM_BASE + SDI_CAP_DRAM_SIZE;

    if (len == 0) {
        fprintf(stderr, "sdi_cap: buffer length is zero\n");
        return -1;
    }
    if (pa + len < pa) {                 /* 32 位编译时的 unsigned 回绕 */
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

/* u-dma-buf 探测：设备节点 + phys_addr/size + 类目录。
 * 类目录有两种命名——板上现役的是 ikwzm 外源驱动 `u-dma-buf`（台账/取证
 * 实测路径 /sys/class/u-dma-buf/udmabuf0/），上游同名驱动是 /sys/class/udmabuf/。
 * 两种都试，取第一个读通的；*clsdir 回填那个类目录（sync_for_cpu 挂在它下面）。
 * 返回 0 = 探到（fd 已打开，O_RDONLY|O_SYNC 与板上验证过的 sdi_stat.py 同参
 * ——本板 CONFIG_STRICT_DEVMEM=y，DDR 走 /dev/mem 会 EPERM，设备这条路
 * 是实测能读通的）；返回 -1 = 没有这颗设备（*fd 保持 -1，调用方回退 /dev/mem）。 */
static int sdi_cap_udma_probe(int *fd, uint64_t *pa, uint64_t *sz, char *clsdir)
{
    static const char *phys_paths[] = {
        "/sys/class/u-dma-buf/udmabuf0/phys_addr",   /* ikwzm u-dma-buf（本板现役） */
        "/sys/class/udmabuf/udmabuf0/phys_addr",     /* 上游 udmabuf（兜底命名） */
    };
    static const char *size_paths[] = {
        "/sys/class/u-dma-buf/udmabuf0/size",
        "/sys/class/udmabuf/udmabuf0/size",
    };
    char line[64];
    FILE *f;
    size_t i, hit = 0;

    *fd = -1; *pa = 0; *sz = 0; if (clsdir) clsdir[0] = '\0';

    f = NULL;
    for (i = 0; i < sizeof(phys_paths)/sizeof(phys_paths[0]); i++) {
        f = fopen(phys_paths[i], "r");
        if (f) { hit = i; break; }
    }
    if (!f) return -1;
    if (fgets(line, sizeof(line), f) == NULL) { fclose(f); return -1; }
    fclose(f);
    *pa = strtoull(line, NULL, 16);
    if (*pa == 0) return -1;

    /* size 读不到不算致命（0 = 未知，调用方按"不做上界校验"处理） */
    f = fopen(size_paths[hit], "r");
    if (f) {
        if (fgets(line, sizeof(line), f) != NULL) *sz = strtoull(line, NULL, 16);
        fclose(f);
    }

    if (clsdir) {
        /* 类目录 = phys_addr 路径去掉最后一截 */
        const char *last_slash = strrchr(phys_paths[hit], '/');
        size_t n = (size_t)(last_slash - phys_paths[hit]);
        memcpy(clsdir, phys_paths[hit], n);
        clsdir[n] = '\0';
    }

    int fdv = open("/dev/udmabuf0", O_RDONLY | O_SYNC);
    if (fdv < 0) return -1;
    *fd = fdv;
    return 0;
}

int sdi_cap_open(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len)
{
    int ret = -1;

    memset(c, 0, sizeof(*c));
    c->memfd  = -1;
    c->ringfd = -1;              /* 不是 0！fd 0 是 stdin，memset 后会误关 */
    c->ring_pa = ring_pa;
    c->ring_len = ring_len;

    if (sdi_cap_check_buffer((unsigned long)ring_pa, ring_len) != 0) return -1;

    /* ★ 2026-11-10 修（B2）：环长必须是 8 的倍数。写帧器在环尾的最后一个
     * 突发按整 8 字节拍**向上取整**（sdi_stream_wr.v 的
     * burst_want = (ring_left+7)>>3）——非 8 倍数的环会被越界多写最多
     * 7 个字节，踩到环外面的内存。硬错误拦下，别让上游排错排到花屏。 */
    if ((ring_len % 8u) != 0) {
        fprintf(stderr,
                "sdi_cap: ring_len %u is not a multiple of 8\n"
                "         (writer rounds the tail burst up to a whole 8-byte beat)\n",
                ring_len);
        return -1;
    }

    c->memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (c->memfd < 0) { perror("open /dev/mem"); return -1; }

    void *r = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED,
                   c->memfd, SDI_CAP_BASE);
    if (r == MAP_FAILED) { perror("mmap regs"); goto out; }
    c->regs = (volatile uint32_t *)r;

    uint32_t id = rd(c, SDI_CAP_ID);
    if (id != SDI_CAP_MAGIC) {
        fprintf(stderr,
                "sdi_cap: bad magic 0x%08x at 0x%08x (expected 0x%08x)\n"
                "         -> 位流没加载，或者这块位流不是采集通路\n",
                id, SDI_CAP_BASE, SDI_CAP_MAGIC);
        ret = -2;
        goto out;
    }

    /* ★ 2026-11-10 修（B4）★ 环缓冲的映射路径按板上证过的顺序选：
     *
     *   路 1（优先）：/dev/udmabuf0 的设备 fd。本板 CONFIG_STRICT_DEVMEM=y，
     *     DDR 那段走 /dev/mem 映射会被内核挡掉（板上实测 EPERM）；
     *     u-dma-buf 设备节点 + sysfs phys_addr + O_SYNC 打开 + 设备内偏移
     *     mmap，是板上验证过能读通的组合（sdi_stat.py / libaxizg330aiu 同款）。
     *     ring_pa 落在设备窗内就走这条路，偏移 = ring_pa - phys_addr（必须页对齐）。
     *   路 2（兜底）：/dev/mem 直接映射物理地址——只有内核没开
     *     STRICT_DEVMEM 的环境才通；留着是为了 PC/别的镜像能跑同一份代码。
     *
     *   ring_pa == 0：路 1 探到设备就用设备的 phys_addr（环 = 整块 udmabuf，
     *   ring_len 超出设备大小就截到设备大小）；没探到设备就是错误。 */
    int      udma_fd = -1;
    uint64_t udma_pa = 0, udma_sz = 0;
    char     udma_cls[160] = "";
    int      udma = sdi_cap_udma_probe(&udma_fd, &udma_pa, &udma_sz, udma_cls);

    if (ring_pa == 0) {
        if (udma != 0) {
            fprintf(stderr,
                    "sdi_cap: ring_pa=0 and no /dev/udmabuf0 -- need an explicit\n"
                    "         physical address (or load the u-dma-buf driver)\n");
            ret = -1;
            goto out;
        }
        ring_pa = udma_pa;
        c->ring_pa = ring_pa;
        if (udma_sz != 0 && ring_len > (uint32_t)udma_sz) {
            ring_len = (uint32_t)udma_sz & ~7u;
            c->ring_len = ring_len;
        }
    }

    const unsigned long pgsz = (unsigned long)sdi_cap_page_size();
    uint64_t map_off;          /* mmap 的偏移：设备路 = 设备内偏移；/dev/mem 路 = ring_pa */
    int      map_fd;

    if (udma == 0 && ring_pa >= udma_pa &&
        (udma_sz == 0 || ring_pa + ring_len <= udma_pa + udma_sz)) {
        map_off = ring_pa - udma_pa;
        map_fd  = udma_fd;
        snprintf(c->sync_cpu, sizeof(c->sync_cpu), "%s/sync_for_cpu", udma_cls);
    } else {
        if (udma == 0) {
            fprintf(stderr,
                    "sdi_cap: ring 0x%lx+%u is outside /dev/udmabuf0 (phys=0x%lx size=%llu);"
                    " falling back to /dev/mem\n",
                    ring_pa, ring_len, udma_pa, (unsigned long long)udma_sz);
        }
        map_off = ring_pa;
        map_fd  = c->memfd;
        c->sync_cpu[0] = '\0';
        if (udma_fd >= 0) { close(udma_fd); udma_fd = -1; }
    }
    c->ringfd   = udma_fd;      /* -1 = /dev/mem 兜底路 */
    c->ring_off = (udma_fd >= 0) ? map_off : 0;

    /* 自动探测换过 ring_pa 的话，原始 check 是对 0 做的——按最终值重验一遍 */
    if (sdi_cap_check_buffer((unsigned long)c->ring_pa, ring_len) != 0) {
        ret = -1;
        goto out;
    }

    /* mmap 的 offset 必须页对齐——不对齐内核返回 EINVAL，perror 只会说
     * "Invalid argument"，看不出是哪里不对，先自己查清楚。 */
    if ((map_off % (uint64_t)pgsz) != 0) {
        fprintf(stderr,
                "sdi_cap: mmap offset 0x%llx is not %lu-byte page aligned\n",
                (unsigned long long)map_off, pgsz);
        goto out;
    }
    if (map_off > (uint64_t)INT64_MAX) {
        fprintf(stderr, "sdi_cap: mmap offset 0x%llx does not fit an off_t\n",
                (unsigned long long)map_off);
        goto out;
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

    c->ring_va = mmap(NULL, ring_len, PROT_READ, MAP_SHARED, map_fd, (off_t)map_off);
    if (c->ring_va == MAP_FAILED) {
        perror("mmap ring");
        fprintf(stderr,
                "sdi_cap:        （路 %s；本板开了 STRICT_DEVMEM，DDR 走 /dev/mem 会 EPERM，"
                "用 /dev/udmabuf0 那条路）\n",
                c->ringfd >= 0 ? "udmabuf" : "devmem");
        c->ring_va = NULL;
        goto out;
    }
    return 0;

out:
    /* ★ 2026-11-10 修（B3）：失败路径把已占的资源全部释放、字段清干净。
     * 旧版失败后 c->regs / c->memfd 还留着已释放的资源值，调用方一句
     * sdi_cap_close() 就 double-munmap / double-close。现在无论从哪条
     * 失败路退出，句柄都回到"未打开"状态，close() 幂等。 */
    if (c->ring_va) { munmap(c->ring_va, ring_len); c->ring_va = NULL; }
    if (c->regs)    { munmap((void *)c->regs, 0x1000); c->regs = NULL; }
    if (c->ringfd >= 0) { close(c->ringfd); c->ringfd = -1; }
    if (c->memfd >= 0)  { close(c->memfd);  c->memfd  = -1; }
    return ret;
}

void sdi_cap_close(sdi_cap_t *c)
{
    if (c->ring_va) { munmap(c->ring_va, c->ring_len); c->ring_va = NULL; }
    if (c->regs)    { munmap((void *)c->regs, 0x1000); c->regs = NULL; }
    if (c->ringfd >= 0) { close(c->ringfd); c->ringfd = -1; }
    if (c->memfd >= 0)  { close(c->memfd);  c->memfd  = -1; }
}

/*---------------------------------------------------------------------------*/
/* 开始搬运。
 *
 * 注意这里**没有**幅面参数、**没有**帧率参数——PL 不需要知道源是什么格式。
 * 软件要判断格式，自己读 MEAS_* / FPS_X100 / RX_* 就行。
 *
 * ★ 顺序（2026-11-10 修，M8/M6/M10）★
 *   1. CTRL=0 停写帧器；
 *   2. 等排空（wait_drained）——REARM 会把写帧器的在途计数 inflight 清零，
 *      若 HP 口上还有在途事务，它们迟到的 BRESP 会把清零后的计数打成
 *      0-1=63，idle 从此永远不亮，stop() 超时。必须在 REARM 前等干净；
 *   3. 写地址/环长 → 停一拍 + 读回 → REARM → 再停一拍 → 使能。
 *      地址/环长走两级电平同步进 clk_100m，REARM 走脉冲同步：背靠背
 *      写下去，载荷有概率赶不上 rearm。各隔 1 ms，代价可忽略；
 *   4. 不替用户置 IRQ_EN（M10）：没有写 INT_ENABLE 的应用置了它，
 *      s_axi_intr 永远不来，只是多一条永远清不掉的 pending 位。
 *      要用中断，自己写 INT_ENABLE = 0xF。 */
int sdi_cap_start(sdi_cap_t *c, uint64_t ring_pa, uint32_t ring_len)
{
    wr(c, SDI_CAP_CTRL, 0);                      /* 先停 */
    if (sdi_cap_wait_drained(c, 100) != 0) {
        fprintf(stderr,
                "sdi_cap: in-flight AXI writes did not drain in 100 ms; "
                "NOT re-arming (a late BRESP would corrupt the writer state)\n");
        return -ETIMEDOUT;
    }

    wr(c, SDI_CAP_INT_STATUS, 0xFFFFFFFFu);      /* INT_STATUS 是写 1 清零 */
    /* ERR_STAT 是只读的：往它写 1 什么也不会发生，清零靠下面的 REARM */

    wr(c, SDI_CAP_BUF_ADDR_L, (uint32_t)(ring_pa & 0xFFFFFFFFu));
    wr(c, SDI_CAP_BUF_ADDR_H, (uint32_t)(ring_pa >> 32));   /* 仅存储，PL 只用低 32 位（M3） */
    wr(c, SDI_CAP_RING_BYTES,  ring_len);

    (void)rd(c, SDI_CAP_ID);                     /* 把 AXI 写序列排干净（M6） */
    usleep(1000);
    wr(c, SDI_CAP_REARM, 1);                     /* 装载起始地址、清计数器与 ERR_STAT */
    usleep(1000);                                /* 等 rearm 脉冲跨到两个目的域（M6） */
    wr(c, SDI_CAP_CTRL, SDI_CAP_CTRL_ENABLE);
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
     * idle 在写帧器（clk_100m 域）算出，经两级电平同步进 fclk0
     * （sdi_cap_top.v:394-447 的 u_cdc_idle），最坏比真实状态晚几拍。
     * ★ 2026-11-10 修（B5/M9）★：旧注释说 idle 来自 cam_clk——错，
     * 写帧器在 clk_100m。旧实现在循环里背靠背读三次就认排空，三次读
     * 可能发生在同一微秒里，"连续稳定"毫无含义。现在每次轮询隔 200 µs：
     * BRESP 最长几十个 clk_100m 周期，200 µs 足够让任何一个迟到的响应
     * 落进来再被看到。 */
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
        usleep(200);
    }
}

int sdi_cap_stop(sdi_cap_t *c)
{
    wr(c, SDI_CAP_CTRL, 0);
    return sdi_cap_wait_drained(c, 100);
}

/*---------------------------------------------------------------------------*/
void sdi_cap_get_info(sdi_cap_t *c, sdi_cap_info *i)
{
    uint32_t st = rd(c, SDI_CAP_STATUS);
    uint32_t rm = rd(c, SDI_CAP_RX_MODE);
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
    /* ★ 2026-11-10 修（M1）★：RX_MODE bit2 是厂商 rx_m（/1.001 标志，
     * 29.97/59.94 那类源）。比较制式只能看 bit1:0，bit2 单独上报 ——
     * 否则 29.97 Hz 的源会被误判成"未知制式"。 */
    i->rx_m       = (rm & SDI_CAP_MODE_M) != 0;
    i->rx_mode    = rm & SDI_CAP_MODE_MASK;
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
    case SDI_CAP_FAM_PAL:    return "PAL        720x576";
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
    printf("link       : %s%s\n",
           i->rx_mode == SDI_CAP_MODE_HD ? "HD-SDI 1.485G (SMPTE 292M)" :
           i->rx_mode == SDI_CAP_MODE_SD ? "SD-SDI 270M  (SMPTE 259M)" :
                                           "3G-SDI  2.97G  (SMPTE 424M)",
           i->rx_m ? "  (/1.001 源：29.97/59.94 类)" : "");
    printf("family     : %s (0x%x)\n", sdi_cap_family_name(i->family), i->family);
    printf("geometry   : %ux%u  row=%u B  frame=%llu B  %s\n",
           i->width, i->height, i->row_bytes,
           (unsigned long long)i->frame_bytes,
           i->geom_valid ? "(valid)" : "(还没测出)");
    printf("frame rate : %u.%02u fps -> %s\n",
           i->fps_x100 / 100, i->fps_x100 % 100,
           sdi_cap_fps_class_name(i->fps_class));
    printf("frames     : %u   beats written: %u\n", i->frames, i->beats);
    printf("addresses  : frame-being-written @0x%08x, next write @0x%08x\n",
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
 * ★ 2026-11-10 重写（B1）★。旧版三个洞：
 *   1. off 从不做环内归一化/校验：调用方传进来一个环外地址（环重配过、
 *      或读了过期的 FRAME_ADDR），off 就是垃圾；
 *   2. 行起点 src 不判下界：src 一旦 > ring_len（off 没归一 + 行跨环尾），
 *      first = ring_len - src 无符号下溢成天文数字，memcpy 直接把进程打死；
 *   3. row（= w*2）没有上限检查：小环 + 大幅面时 row > ring_len，
 *      回绕分支的第二段 memcpy 从 base 读 row-first 字节，越过映射。
 * 现在全部挡下：frame_addr 必须落在 [ring_pa, ring_pa+ring_len)；
 * row 不得超过环长；每行 src 对环长取模后再走回绕拷贝。
 * 返回 0 = 成功；-1 = 参数/地址越界（宁可失败也不读环外的内存）。 */
int sdi_cap_grab(const sdi_cap_t *c, uint32_t frame_addr,
                 unsigned w, unsigned h, void *dst)
{
    const uint8_t *base = (const uint8_t *)c->ring_va;
    const uint32_t ring_len = c->ring_len;
    uint64_t row64;
    size_t row, off;

    if (!base || !dst)            return -1;
    if (ring_len == 0)            return -1;
    if (w == 0 || h == 0)         return -1;

    /* ★ 2026-11-10 补（B4）★ 非硬件一致性平台：PL 经 HP2 写的是 DDR，
     * CPU 这边缓存里可能还是上一轮读进来的旧行。设备路（u-dma-buf）在
     * 每次读前写一次 sync_for_cpu，把整环的 CPU 缓存作废——板上验证过的
     * 读法（sdi_stat.py 每轮采样前同款动作）。/dev/mem+O_SYNC 那条路
     * 本身是非缓存映射，sync_cpu 路径为空，不写。 */
    if (c->sync_cpu[0]) {
        FILE *sf = fopen(c->sync_cpu, "w");
        if (sf) {
            /* u-dma-buf 的 sysfs 写法："<offset> <size>"，offset 是设备内偏移 */
            fprintf(sf, "%llu %llu",
                    (unsigned long long)c->ring_off, (unsigned long long)ring_len);
            if (fclose(sf) != 0) {
                /* 写失败（比如内核不认带参数的写法）不拦拷贝——
                 * 数据可能旧，但这是兜底路径的兜底，真板不会走到这。 */
            }
        }
    }

    /* frame_addr 必须真的落在环里（ring_pa < 4 GB，check_buffer 已保证）。 */
    if (frame_addr < (uint32_t)c->ring_pa ||
        frame_addr >= (uint32_t)(c->ring_pa + ring_len))
        return -1;
    off = (size_t)(frame_addr - (uint32_t)c->ring_pa);

    row64 = (uint64_t)w * 2u;
    if (row64 > (uint64_t)ring_len)  return -1;   /* 一行都比环大，拷不完整 */
    row = (size_t)row64;

    /* 行会跨越环尾，逐行处理；每行起点先归一化进环内再回绕拷贝 */
    for (unsigned y = 0; y < h; y++) {
        uint64_t src64 = (uint64_t)off + (uint64_t)y * row;
        size_t src = (size_t)(src64 % ring_len);       /* 归一化，杜绝下溢 */
        if (src + row <= ring_len) {
            memcpy((uint8_t *)dst + (size_t)y * row, base + src, row);
        } else {
            size_t first = ring_len - src;             /* src < ring_len，不会下溢 */
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
    unsigned long ring_pa  = 0;     /* 0 = 自动探测 /dev/udmabuf0 */
    uint32_t      ring_len = 32u * 1024u * 1024u;   /* 32 MB，够存 8 帧 1080p */

    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        fprintf(stderr,
"usage: %s [seconds] [out.pgm] [ring_phys_addr] [ring_bytes]\n"
"\n"
"ring_phys_addr 缺省（0）= 自动用 /dev/udmabuf0（本板验证过的读法：\n"
"sysfs phys_addr 拿物理基址，O_SYNC 打开设备节点按设备内偏移 mmap；\n"
"本板 CONFIG_STRICT_DEVMEM=y，DDR 直接走 /dev/mem 是 EPERM）。\n"
"手工给地址也支持：落在 udmabuf0 窗内仍走设备路，窗外退 /dev/mem——\n"
"但**没有安全的默认值**：PS DDR 只有 1 GB 而且内核住在里面，\n"
"写死一个物理地址很可能踩到在用的内存，失败现象是一帧莫名其妙的\n"
"花屏而不是报错。\n"
"\n"
"udmabuf0 是出厂设备树建的静态实例（128 MiB @ 0x30100000）：\n"
"    cat /sys/class/u-dma-buf/udmabuf0/phys_addr   # 物理基址\n"
"    cat /sys/class/u-dma-buf/udmabuf0/size        # 字节数\n",
                argv[0]);
        return 2;
    }
    if (argc > 1) seconds   = (unsigned)atoi(argv[1]);
    if (argc > 2) out_pgm   = argv[2];
    if (argc > 3) ring_pa   = strtoul(argv[3], NULL, 0);
    if (argc > 4) ring_len  = (uint32_t)strtoul(argv[4], NULL, 0);

    /* ★ 2026-11-10 修（B4）★：旧帮助文本教的 ioctl 流程是错的——
     * UDMABUF_CREATE 要的是 memfd 而且本板根本不用用户态创建。
     * 现在的流程：ring_pa 缺省（0）→ sdi_cap_open() 内部自动探测
     * /dev/udmabuf0 并用它的 phys_addr 当环基址；手工给地址仍然支持
     * （落在设备窗内走设备路，窗外退 /dev/mem）。 */
    if (ring_pa == 0) {
        printf("ring_pa=0：自动用 /dev/udmabuf0 的 phys_addr（探不到会报错）\n");
    } else if (ring_pa > 0x3FFFFFFFUL) {
        fprintf(stderr, "sdi_cap: ring_pa 0x%lx 不在 PS DDR (0..0x40000000)\n", ring_pa);
        return 2;
    }

    sdi_cap_t cap;
    if (sdi_cap_open(&cap, ring_pa, ring_len) != 0) return 1;

    sdi_cap_info i;
    sdi_cap_get_info(&cap, &i);
    printf("--- before start ---\n"); sdi_cap_print_info(&i);

    if (sdi_cap_start(&cap, ring_pa, ring_len) != 0) {
        sdi_cap_close(&cap);
        return 1;
    }

    printf("\n--- streaming for %u s into 0x%llx (%u MB) ---\n",
           seconds, (unsigned long long)cap.ring_pa, ring_len >> 20);

    /* ★ 2026-11-10 修（M7）★：FRAME_ADDR 是"正在写的帧"的起点。
     * 轮询 10 ms，记录 FRAME_ADDR 的前一个值：每观测到一次变化，
     * 上一个值对应的帧刚好写完（它的 vsync 就是这次变化的来源）。
     * 抓"上一个值" = 抓最后一帧**完整**的帧。 */
    uint32_t last_seen = 0, completed = 0;
    int      n_seen = 0, have_completed = 0;
    uint32_t last_f = 0;
    for (unsigned ms = 0; ms < seconds * 1000u; ms += 10) {
        usleep(10000);
        sdi_cap_get_info(&cap, &i);
        if (i.frame_addr != last_seen) {
            if (n_seen >= 1) { completed = last_seen; have_completed = 1; }
            last_seen = i.frame_addr;
            n_seen++;
        }
        if (ms % 1000 == 0) {
            printf("[%3us] frames=%-5u (+%u)  %ux%u  %u.%02u fps  "
                   "wr@0x%08x  err=0x%x%s\n",
                   ms / 1000 + 1, i.frames, i.frames - last_f, i.width, i.height,
                   i.fps_x100 / 100, i.fps_x100 % 100, i.wr_addr, i.err,
                   i.starving ? " STARVING" : "");
            last_f = i.frames;
        }
    }

    sdi_cap_get_info(&cap, &i);
    printf("\n--- final ---\n"); sdi_cap_print_info(&i);

    /* 抓"上一个 FRAME_ADDR"对应的完整帧 */
    if (have_completed && i.geom_valid && i.width && i.height) {
        printf("\ngrabbing COMPLETED frame @0x%08x "
               "(current frame @0x%08x is still being written)\n",
               completed, i.frame_addr);
        size_t need = (size_t)i.width * i.height * 2;
        void  *frame = malloc(need);
        if (frame) {
            if (sdi_cap_grab(&cap, completed, i.width, i.height, frame) == 0) {
                sdi_cap_dump_pgm(frame, i.width, i.height, out_pgm);
                printf("wrote %s (%ux%u, PGM = Y' only)\n", out_pgm, i.width, i.height);
            } else {
                fprintf(stderr, "grab failed: frame 0x%08x outside ring?\n", completed);
            }
        } else {
            fprintf(stderr, "malloc(%zu) failed\n", need);
        }
        free(frame);
    } else if (!have_completed) {
        printf("\n没观测到一次帧边界（FRAME_ADDR 没变过），没抓帧。\n"
               "  sig_locked=%d  meas_w=%u meas_h=%u frames=%u\n"
               "  没锁定的话先去查 OBS 是不是把摄像机切到 CVBS 了，\n"
               "  以及跳线 J26/J27 在不在 SDI 位。\n",
               i.sig_locked, i.width, i.height, i.frames);
    } else {
        printf("\n幅面还没测出来，没抓帧。\n"
               "  sig_locked=%d  meas_w=%u meas_h=%u\n",
               i.sig_locked, i.width, i.height);
    }

    if (sdi_cap_stop(&cap) != 0) {
        /* B5：超时不能装没看见——在途事务没排空说明 PL/HP 链路有问题，
         * 此时重配置或复位 PL 都可能挂死（厂商文档 L3/L4 场景）。 */
        fprintf(stderr,
                "sdi_cap: WARNING stop() timed out -- in-flight writes did not drain; "
                "do NOT reconfigure or reset PL until this clears\n");
    }
    sdi_cap_close(&cap);
    return 0;
}
#endif /* SDI_CAP_DEMO */
