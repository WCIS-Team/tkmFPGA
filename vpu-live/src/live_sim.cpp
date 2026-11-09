//==============================================================================
// live_sim.cpp -- 直播编码核的 PS 侧自测：不接 PL、不碰相机、不碰寄存器。
//
// 为什么要有这颗
// --------------
// 直播那条链的取帧口现在收不到相机帧（板上实测 data_in_num=0），所以"编码核到底能不能
// 跑"这件事没法从真链上验。这颗程序把同一套代码（VpuLiveCore + StreamToSegFileSink）
// 单独跑起来，帧由 PS 端自己造，指针是普通堆内存：
//   vpu.h:890 那条 memcpy 证明 enqueueDataPtr 本来就往驱动自己的 mmap 缓冲里拷，
//   所以"喂 udmabuf chunk"与"喂堆内存"对编码会话是同一件事，测出来的码流可以外推。
// 它验的是：会话能不能建、streamon 能不能等到、码流能不能持续出来、段能不能按 IDR 切开、
// 固定 QP 那两个私有 ioctl（VIDIOC_S_MVX_RATE_CONTROL／VIDIOC_S_MVX_QP_EPR）在这颗驱动
// 上认不认——这两条以前只在源码里见过，板上从没发过。
//
// 用法（板上）：
//   ./live_sim --w 960 --h 540 --fps 30 --frames 120 --out /dev/shm/h264sim
//   ./live_sim --fmt nv12 --src raw:/root/vpu/nv12_720.raw --w 1280 --h 720 --frames 60
// 退出码：0＝出过段且核还活着；1＝没出段；2＝参数／素材错。
//==============================================================================
#include "pipeline/live/vpu_live_core.hpp"
#include "pipeline/io/output/stream2segfile.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <linux/videodev2.h>

using namespace std::chrono_literals;

namespace
{

    struct Opt
    {
        int w = 960;
        int h = 540;
        int fps = 30;
        int frames = 120;
        int buffers = 4;
        int seg = 30;
        int seg_ms = 2000;
        int keep = 6;
        int qp = -1;
        bool nv12 = false;
        std::string out = "/dev/shm/h264sim";
        std::string src = "bars"; // bars | raw:<file>
        std::string device = "/dev/video0";
        bool loop = false; // raw 素材放完回到开头，不停
        bool reuse = false; // 只造第一帧，之后反复喂同一张：把 CPU 侧造帧的开销从编码速率里摘出去
    };

    Opt parse(int argc, char **argv)
    {
        Opt o;
        for (int i = 1; i < argc; ++i)
        {
            std::string a = argv[i];
            auto nx = [&](int &d) { if (i + 1 < argc) d = std::atoi(argv[++i]); };
            auto ns = [&](std::string &d) { if (i + 1 < argc) d = argv[++i]; };
            if (a == "--w") nx(o.w);
            else if (a == "--h") nx(o.h);
            else if (a == "--fps") nx(o.fps);
            else if (a == "--frames") nx(o.frames);
            else if (a == "--buffers") nx(o.buffers);
            else if (a == "--seg") nx(o.seg);
            else if (a == "--seg-ms") nx(o.seg_ms);
            else if (a == "--keep") nx(o.keep);
            else if (a == "--qp") nx(o.qp);
            else if (a == "--out") ns(o.out);
            else if (a == "--device") ns(o.device);
            else if (a == "--src") ns(o.src);
            else if (a == "--fmt") o.nv12 = (i + 1 < argc && std::string(argv[++i]) == "nv12");
            else if (a == "--loop") o.loop = true;
            else if (a == "--reuse") o.reuse = true;
            else if (a == "-h" || a == "--help")
            {
                printf("usage: %s [--w N] [--h N] [--fps N] [--frames N] [--buffers N]\n"
                       "          [--seg N] [--seg-ms N] [--keep N] [--qp N] [--fmt uyvy|nv12]\n"
                       "          [--src bars|raw:FILE] [--loop] [--reuse] [--out DIR] [--device PATH]\n",
                       argv[0]);
                exit(0);
            }
        }
        if (o.w < 32 || o.h < 32 || (o.w & 1) || (o.h & 1))
        {
            printf("ERR: w/h must be >=32 and even (got %dx%d)\n", o.w, o.h);
            exit(2);
        }
        if (o.fps < 1 || o.fps > 120) o.fps = 30;
        if (o.buffers < 2 || o.buffers > 6) o.buffers = 4; // >6 = MMU ABORT（15.4d）
        if (o.frames < 1) o.frames = 1;
        return o;
    }

    void yuvFromRgb(int r, int g, int b, uint8_t *y, uint8_t *cb, uint8_t *cr)
    {
        double Y = 16.0 + 65.481 * r / 255.0 + 128.553 * g / 255.0 + 24.966 * b / 255.0;
        double Cb = 128.0 - 37.797 * r / 255.0 - 74.203 * g / 255.0 + 112.0 * b / 255.0;
        double Cr = 128.0 + 112.0 * r / 255.0 - 93.786 * g / 255.0 - 18.214 * b / 255.0;
        *y = (uint8_t)(Y < 0 ? 0 : (Y > 255 ? 255 : Y));
        *cb = (uint8_t)(Cb < 0 ? 0 : (Cb > 255 ? 255 : Cb));
        *cr = (uint8_t)(Cr < 0 ? 0 : (Cr > 255 ? 255 : Cr));
    }

    const int BAR_R[8] = { 255, 255, 255, 0, 0, 0, 255, 128 };
    const int BAR_G[8] = { 255, 255, 0, 255, 0, 0, 0, 128 };
    const int BAR_B[8] = { 255, 0, 0, 0, 255, 255, 0, 128 };

    // 造一张会动的测试图：八条竖色条 + 一个横向移动的黑块 + 顶部一排随帧号变化的白条。
    // 必须有运动，否则静态图编出来的字节数只能证明"能编"，证不出持续出流。
    void genBars(const Opt &o, long n, uint8_t *dst)
    {
        const int w = o.w, h = o.h;
        const int bx = (int)((n * (w / 8)) % (w - w / 6)); // 黑块左边界，每帧走 1/8 宽
        const int ticks = (int)(n % 17);                   // 顶部白条根数
        for (int y = 0; y < h; ++y)
        {
            for (int x = 0; x < w; x += 2)
            {
                uint8_t y0, u0, v0, y1, u1, v1;
                for (int k = 0; k < 2; ++k)
                {
                    int xx = x + k;
                    int bar = (xx * 8) / w;
                    if (bar > 7) bar = 7;
                    int r = BAR_R[bar], g = BAR_G[bar], b = BAR_B[bar];
                    if (y < h / 12)
                    {
                        // 顶带：第 t 根白格亮，其余黑 -> 帧号可视化
                        int t = (xx * 17) / w;
                        bool on = (t < ticks);
                        r = g = b = on ? 255 : 0;
                    }
                    if (y > h / 6 && y < h / 3 && xx >= bx && xx < bx + w / 6)
                        r = g = b = 0; // 中段黑块
                    if (k == 0) yuvFromRgb(r, g, b, &y0, &u0, &v0);
                    else yuvFromRgb(r, g, b, &y1, &u1, &v1);
                }
                // 4:2:0 色度由偶数列决定（UYVY 里 U/V 就是这对像素共享的）
                const uint8_t U = u0, V = v0;
                if (o.nv12)
                {
                    size_t row = (size_t)y * w;
                    dst[row + x] = y0;
                    dst[row + x + 1] = y1;
                    if ((y & 1) == 0)
                    {
                        size_t crow = (size_t)(h + y / 2) * w;
                        dst[crow + x] = U;
                        dst[crow + x + 1] = V;
                    }
                }
                else
                {
                    size_t row = (size_t)y * w * 2;
                    dst[row + x * 2] = U;
                    dst[row + x * 2 + 1] = y0;
                    dst[row + x * 2 + 2] = V;
                    dst[row + x * 2 + 3] = y1;
                }
            }
        }
    }

    size_t frameBytes(const Opt &o)
    {
        // UYVY＝2 字节/像素，NV12＝1.5 字节/像素。驱动按 sizeimage 从我们指针里 memcpy，
        // 少算一个字节就是越界写：10-15 板上这一行写成 *2/2 直接把堆打穿到线程栈护栏页。
        return (size_t)o.w * o.h * (o.nv12 ? 3 : 4) / 2;
    }
}

int main(int argc, char **argv)
{
    Opt o = parse(argc, argv);
    const size_t fbytes = frameBytes(o);

    std::unique_ptr<FILE, int (*)(FILE *)> raw(nullptr, &fclose);
    if (o.src.rfind("raw:", 0) == 0)
    {
        raw.reset(fopen(o.src.c_str() + 4, "rb"));
        if (!raw)
        {
            printf("ERR: cannot open %s\n", o.src.c_str() + 4);
            return 2;
        }
    }

    fpai::VpuLiveConfig cfg;
    cfg.device = o.device;
    cfg.width = o.w;
    cfg.height = o.h;
    cfg.fps = o.fps;
    cfg.buffers = o.buffers;
    cfg.input_format = o.nv12 ? V4L2_PIX_FMT_NV12 : V4L2_PIX_FMT_UYVY;
    cfg.codec_format = V4L2_PIX_FMT_H264;
    cfg.qp = o.qp;

    StreamToSegFileSink::Config sc;
    sc.dir = o.out;
    sc.seg_frames = o.seg;
    sc.seg_ms = o.seg_ms;
    sc.keep = o.keep;
    sc.fps = o.fps;
    auto sink = std::make_unique<StreamToSegFileSink>(0, sc);
    StreamToSegFileSink *sink_raw = sink.get();

    fpai::VpuLiveCore core(cfg, std::move(sink));
    core.start();

    std::vector<uint8_t> fb(fbytes);
    printf("[SIM] %dx%d %s -> H264, fps=%d frames=%d buffers=%d seg=%d/%dms out=%s src=%s\n",
           o.w, o.h, o.nv12 ? "NV12" : "UYVY", o.fps, o.frames, o.buffers, o.seg, o.seg_ms,
           o.out.c_str(), o.src.c_str());
    fflush(stdout);

    uint64_t t0 = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now().time_since_epoch())
                      .count();
    auto clk = [] {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
    };
    // 造帧是纯 CPU 活，喂帧会被驱动的消费速度顶住。两段分开计时，否则 fps_eff 里混的是
    // 仿真器自己的开销，读不出编码核的速率上限。
    uint64_t gen_ms = 0, push_ms = 0, push_max_ms = 0;
    int fed = 0;
    for (int i = 0; i < o.frames; ++i)
    {
        if (raw)
        {
            size_t rd = fread(fb.data(), 1, fbytes, raw.get());
            if (rd != fbytes)
            {
                if (!o.loop)
                {
                    printf("[SIM] raw exhausted at frame %d (got %zu/%zu)\n", i, rd, fbytes);
                    break;
                }
                rewind(raw.get());
                rd = fread(fb.data(), 1, fbytes, raw.get());
                if (rd != fbytes)
                {
                    printf("[SIM] raw unreadable even after rewind\n");
                    break;
                }
            }
        }
        else if (!o.reuse || i == 0)
        {
            uint64_t g0 = clk();
            genBars(o, i, fb.data());
            gen_ms += clk() - g0;
        }

        uint64_t p0 = clk();
        bool ok = core.pushFrame(fb.data());
        uint64_t pd = clk() - p0;
        push_ms += pd;
        if (pd > push_max_ms)
            push_max_ms = pd;
        if (!ok)
        {
            printf("[SIM] pushFrame failed at frame %d: %s\n", i, core.why().c_str());
            break;
        }
        ++fed;

        uint64_t due = t0 + (uint64_t)((fed * 1000.0) / o.fps);
        uint64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count();
        if (now < due)
            std::this_thread::sleep_for(std::chrono::milliseconds(due - now));

        if (fed % 30 == 0)
        {
            printf("[SIM] fed=%d in=%ld chunks=%ld segs=%ld frames=%ld bytes=%ld head_bytes=%ld alive=%d\n",
                   fed, (long)core.frames_in.load(), (long)core.chunks_out.load(),
                   (long)sink_raw->segs.load(), (long)sink_raw->frames.load(),
                   (long)sink_raw->bytes.load(), (long)sink_raw->head_bytes.load(),
                   (int)core.alive());
            fflush(stdout);
        }
    }

    // 喂完不等于编完：给取流线一点时间把在飞的帧排空
    std::this_thread::sleep_for(1500ms);
    core.stop();

    uint64_t span = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now().time_since_epoch())
                        .count() - t0;
    printf("[SIM] RESULT fed=%d in=%ld chunks=%ld segs=%ld pic=%ld bytes=%ld head_bytes=%ld "
           "wait_streamon_ms=%ld span_ms=%llu gen_ms=%llu push_ms=%llu push_avg_ms=%.1f "
           "push_max_ms=%llu fps_eff=%.2f fps_push=%.2f kbps=%.1f alive=%d why='%s'\n",
           fed, (long)core.frames_in.load(), (long)core.chunks_out.load(),
           (long)sink_raw->segs.load(), (long)sink_raw->frames.load(),
           (long)sink_raw->bytes.load(), (long)sink_raw->head_bytes.load(),
           (long)core.wait_streamon_ms.load(), (unsigned long long)span,
           (unsigned long long)gen_ms, (unsigned long long)push_ms,
           fed ? (double)push_ms / fed : 0.0, (unsigned long long)push_max_ms,
           span ? fed * 1000.0 / (double)span : 0.0,
           push_ms ? fed * 1000.0 / (double)push_ms : 0.0,
           span ? (double)sink_raw->bytes.load() * 8.0 / ((double)span / 1000.0) / 1000.0 : 0.0,
           (int)core.alive(), core.why().c_str());
    fflush(stdout);

    if (!core.alive())
        return 1;
    return sink_raw->segs.load() > 0 && sink_raw->bytes.load() > 0 ? 0 : 1;
}
