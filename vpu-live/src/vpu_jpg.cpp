// VPU 硬编 JPEG 探针：判定这颗 VPU 能不能真的吐出可用的 JFIF 图，用来决定
// "快照／预览也走硬件"这条路成不成立（十五条 15.2 只有格式声明，JPEG 从未实跑）。
// 用法（板上）：./vpu_jpg <in.raw> <w> <h> <frames> <nv12|uyvy> <outdir> [q] [buffers] [fps] [ri] [mjpeg]
//   <in.raw>   每帧 w*h*3/2 字节（NV12）或 w*h*2 字节（UYVY）的裸帧
//   <outdir>   码流按 DQBUF 的块存成 cNNN.bin，拼出的整图存 imgNNN.jpg
//   [q]        compression_quality(0x009d0903)，不给就不设（驱动默认 0）
//   [ri]       restart_interval(0x009d0902)，不给就不设
//   [mjpeg]    用 V4L2_PIX_FMT_MJPEG 而不是 JPEG
// 两条厂商口径已核：控制必须在第一帧喂进去之前设完（15.9：流开之后再设 codec 类控制
// 会 EINVAL→EIO 打死两侧队列）；capture 队列必须等 input 侧触发 streamon 之后再取
// （15.4b，厂商 vpu_encoder_actor.hpp:299-301 那句忙等）。
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <chrono>
#include <string>
#include <thread>
#include <atomic>
#include <vector>
#include <cerrno>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <linux/videodev2.h>

#include "pipeline/vpu/vpu.h"

#define CID_COMPRESSION_QUALITY 0x009d0903
#define CID_RESTART_INTERVAL 0x009d0902

class PE : public vpu::Encoder
{
public:
    using vpu::Encoder::Encoder;

    void query(uint32_t id)
    {
        v4l2_queryctrl q {};
        q.id = id;
        int r = ioctl(fd_, VIDIOC_QUERYCTRL, &q);
        if (r < 0)
        {
            std::printf("QUERY 0x%x rc=%d errno=%d\n", id, r, errno);
            return;
        }
        std::printf("QUERY 0x%x type=%d flags=0x%x min=%d max=%d step=%d def=%d name='%s'\n",
                    id, q.type, q.flags, (int)q.minimum, (int)q.maximum, q.step,
                    (int)q.default_value, q.name);
    }

    void set(uint32_t id, int32_t v)
    {
        v4l2_control c {};
        c.id = id;
        c.value = v;
        int r = ioctl(fd_, VIDIOC_S_CTRL, &c);
        int se = errno;
        v4l2_control g {};
        g.id = id;
        ioctl(fd_, VIDIOC_G_CTRL, &g);
        std::printf("S_CTRL 0x%x=%d rc=%d errno=%d readback=%d\n",
                    id, v, r, r < 0 ? se : 0, g.value);
    }
};

static uint64_t now_ms()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// 从一块码流里切出所有完整的 SOI..EOI 图，返回切出的张数
static int cutJpeg(const uint8_t *p, int size, const char *outdir, int first_index)
{
    int made = 0;
    int i = 0;
    while (i + 1 < size)
    {
        if (!(p[i] == 0xFF && p[i + 1] == 0xD8))
        {
            ++i;
            continue;
        }
        int j = i + 2;
        int eoi = -1;
        while (j + 1 < size)
        {
            if (p[j] == 0xFF && p[j + 1] == 0xD9)
            {
                eoi = j + 2;
                break;
            }
            ++j;
        }
        if (eoi < 0)
            break;
        char path[512];
        snprintf(path, sizeof(path), "%s/img%03d.jpg", outdir, first_index + made);
        FILE *f = std::fopen(path, "wb");
        if (f)
        {
            std::fwrite(p + i, 1, eoi - i, f);
            std::fclose(f);
            std::printf("IMG %s %d B\n", path, eoi - i);
            ++made;
        }
        i = eoi;
    }
    return made;
}

int main(int argc, char **argv)
{
    if (argc < 7)
    {
        std::printf("usage: %s <in.raw> <w> <h> <frames> <nv12|uyvy> <outdir> [q] [buffers] [fps] [ri] [mjpeg]\n", argv[0]);
        return 2;
    }
    const char *infile = argv[1];
    int w = std::atoi(argv[2]);
    int h = std::atoi(argv[3]);
    int frames = std::atoi(argv[4]);
    bool uyvy = std::string(argv[5]) == "uyvy";
    const char *outdir = argv[6];
    int quality = argc > 7 ? std::atoi(argv[7]) : -1;
    int buffers = argc > 8 ? std::atoi(argv[8]) : 6;
    int fps = argc > 9 ? std::atoi(argv[9]) : 30;
    int restart = argc > 10 ? std::atoi(argv[10]) : -1;
    bool mjpeg = false;
    for (int i = 11; i < argc; ++i)
        if (std::string(argv[i]) == "mjpeg")
            mjpeg = true;

    mkdir(outdir, 0755);

    uint32_t in_fmt = uyvy ? V4L2_PIX_FMT_UYVY : V4L2_PIX_FMT_NV12;
    uint32_t out_fmt = mjpeg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_JPEG;
    // UYVY=2 B/px, NV12=1.5 B/px. Writing (uyvy?2:3)/2 gives UYVY only w*h,
    // which under-allocates by half the frame (10-15 board crash).
    size_t frame_bytes = (size_t)w * h * (uyvy ? 4 : 3) / 2;

    FILE *fi = std::fopen(infile, "rb");
    if (!fi)
    {
        std::printf("ERR cannot open %s\n", infile);
        return 2;
    }

    std::atomic<bool> stop {false};
    std::atomic<int> chunks {0};
    std::atomic<int> images {0};
    std::atomic<uint64_t> bytes_out {0};
    std::atomic<uint64_t> first_out_ms {0};
    std::atomic<uint64_t> last_out_ms {0};

    PE enc("/dev/video0", h, w,
           V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, in_fmt,
           V4L2_BUF_TYPE_VIDEO_CAPTURE, out_fmt,
           buffers);
    std::printf("constructed: %dx%d in=%s out=%s buffers=%d fps=%d\n", w, h,
                uyvy ? "UYVY" : "NV12", mjpeg ? "MJPEG" : "JPEG", buffers, fps);

    enc.query(CID_COMPRESSION_QUALITY);
    enc.query(CID_RESTART_INTERVAL);
    if (quality >= 0)
        enc.set(CID_COMPRESSION_QUALITY, quality);
    if (restart >= 0)
        enc.set(CID_RESTART_INTERVAL, restart);
    try
    {
        enc.setFrameRate(fps);
        std::printf("CTRL frame_rate=%d ok\n", fps);
    }
    catch (const std::exception &e)
    {
        std::printf("CTRL frame_rate(%d) FAILED: %s\n", fps, e.what());
    }

    std::thread writer(
        [&]
        {
            uint64_t tw = now_ms();
            while (!enc.streamon_flag_.load() && !stop.load() && now_ms() - tw < 20000)
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            std::printf("streamon=%d before first getOutput (waited %llu ms)\n",
                        (int)enc.streamon_flag_.load(), (unsigned long long)(now_ms() - tw));
            while (!stop.load())
            {
                void *ptr = nullptr;
                int size = 0;
                bool more;
                try
                {
                    more = enc.getOutput(ptr, size);
                }
                catch (const std::exception &e)
                {
                    std::printf("getOutput stopped: %s\n", e.what());
                    break;
                }
                if (size > 0 && ptr)
                {
                    int n = chunks.fetch_add(1);
                    bytes_out.fetch_add(size);
                    uint64_t t = now_ms();
                    if (n == 0)
                        first_out_ms.store(t);
                    last_out_ms.store(t);
                    char path[512];
                    snprintf(path, sizeof(path), "%s/c%03d.bin", outdir, n);
                    FILE *f = std::fopen(path, "wb");
                    if (f)
                    {
                        std::fwrite(ptr, 1, size, f);
                        std::fclose(f);
                    }
                    std::printf("CHUNK %d size=%d head=%02x%02x %02x%02x\n",
                                n, size, ((uint8_t *)ptr)[0], ((uint8_t *)ptr)[1],
                                ((uint8_t *)ptr)[2], ((uint8_t *)ptr)[3]);
                    int made = cutJpeg((const uint8_t *)ptr, size, outdir, images.load());
                    if (made)
                        images.fetch_add(made);
                }
                if (!more)
                    break;
            }
        });

    std::vector<char> fb(frame_bytes);
    uint64_t t0 = now_ms();
    int fed = 0;
    try
    {
        for (int i = 0; i < frames; ++i)
        {
            size_t rd = std::fread(fb.data(), 1, frame_bytes, fi);
            if (rd != frame_bytes)
            {
                std::printf("input short at frame %d (got %zu of %zu)\n", i, rd, frame_bytes);
                break;
            }
            enc.enqueueDataPtr(fb.data());
            ++fed;
            uint64_t due = t0 + (uint64_t)((fed * 1000.0) / (fps > 0 ? fps : 30));
            uint64_t now = now_ms();
            if (now < due)
                std::this_thread::sleep_for(std::chrono::milliseconds(due - now));
        }
    }
    catch (const std::exception &e)
    {
        std::printf("ENQUEUE failed after %d frames: %s\n", fed, e.what());
    }
    uint64_t wall = now_ms() - t0;

    uint64_t td = now_ms();
    while (chunks.load() < fed && now_ms() - td < 8000)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    stop.store(true);
    try
    {
        enc.streamOff();
    }
    catch (...)
    {
    }
    if (writer.joinable())
        writer.join();
    std::fclose(fi);

    uint64_t span = (chunks.load() > 0) ? (last_out_ms.load() - first_out_ms.load()) : 0;
    std::printf("RESULT %s %dx%d fed=%d chunks=%d images=%d bytes=%llu wall_ms=%llu span_ms=%llu per_frame_B=%.0f mbps=%.2f outdir=%s\n",
                mjpeg ? "MJPEG" : "JPEG", w, h, fed, chunks.load(), images.load(),
                (unsigned long long)bytes_out.load(), (unsigned long long)wall,
                (unsigned long long)span,
                chunks.load() ? (double)bytes_out.load() / chunks.load() : 0.0,
                span ? (double)bytes_out.load() * 8.0 / ((double)span / 1000.0) / 1e6 : 0.0,
                outdir);
    return images.load() > 0 ? 0 : 1;
}
