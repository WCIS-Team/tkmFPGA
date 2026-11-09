#pragma once
#include "pipeline/base/enums.hpp"
#include "pipeline/io/output/istream_sink.hpp"

#include <spdlog/spdlog.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <unistd.h>

/**
 * @brief Annex-B H.264 出流到"定长分段文件环"的 Sink（厂商 StreamToFileSink 的分段版）。
 *
 * 四条契约（前两条是厂商写法，后两条是这板上量出来的，别随意改）：
 *  - 切段只切在 IDR 起始码上，段首必须是可解码图；
 *  - 段先写 .part 再 rename，HTTP 侧永远看不到半截文件；
 *  - 第一个 IDR 之前的块不丢而是先攒着，攒到 IDR 出现时一起写下去。这颗 VPU 的第一个输出块
 *    就是独立的 32 B SPS+PPS（stream2rtmp.hpp:93 厂商注释同一说法），丢了整条码流就没有参数集，
 *    ffprobe 直接判无视频流，测试等于白跑；
 *  - 攒头有上限（head_max_），真出 IDR 前塞满就报错返回 -1，不无声涨内存。
 *
 * 已知没修的：这颗 VPU 的 IDR 间隔在用户态打不开（十五条 15.9，restart_interval/gop_type
 * 设了码流逐字节不变），所以"每段都带 SPS/PPS"做不到，第 2 段起缺参数集＝HLS 那条老问题，
 * 本轮按她的话先不修。
 */
class StreamToSegFileSink : public IStreamSink
{
public:
    struct Config
    {
        std::string dir = "/dev/shm/h264"; // 段与 state 文件所在目录
        int seg_frames = 30;               // 每段最少编满多少张图（只在 IDR 处切）
        int seg_ms = 2000;                 // 或超过这个时长，在下一个 IDR 处切
        int keep = 6;                      // 目录里最多留几段，旧的删掉
        int fps = 30;                      // 只写进 state，给读取侧算口径
    };

    // 没有默认实参：Config 带成员初值，GCC 10 在类内写 = Config() 会报
    // "default member initializer required before the end of its enclosing class"。
    explicit StreamToSegFileSink(int sink_id, const Config &config)
        : IStreamSink(sink_id, OUTPUT_SINK::DISK),
          cfg_(config)
    {
    }

    std::atomic<long> segs { 0 };       // 已封存的段号（下一个要写的段号）
    std::atomic<long> frames { 0 };     // 已写进当前段的图数（累计计数，不含攒着的头）
    std::atomic<long> bytes { 0 };      // 累计写出字节
    std::atomic<long> head_bytes { 0 }; // 首个 IDR 之前攒下的字节（就是 SPS/PPS 那一块）

    int open(const std::string & /*url*/) override
    {
        std::error_code ec;
        std::filesystem::create_directories(cfg_.dir, ec);
        writeState();
        return openSeg();
    }

    int handlePacket(const SinkPacket &packet) override
    {
        if (!cur_)
            return -1;
        const uint8_t *b = reinterpret_cast<const uint8_t *>(packet.data);
        const int s = (int)packet.size;
        if (s <= 0)
            return 0;

        if (!started_) // 先攒头，直到某个块里真的出现 IDR
        {
            int io = firstIdrOffset(b, s);
            if (io < 0)
            {
                if (head_.size() + (size_t)s > head_max_)
                {
                    spdlog::error("[SEG] {} B of head without any IDR -> giving up", head_max_);
                    return -1;
                }
                head_.insert(head_.end(), b, b + s);
                head_bytes.store((long)head_.size());
                return 0;
            }
            started_ = true;
            seg_start_ms_ = nowMs();
            head_bytes.store((long)head_.size());
            if (!head_.empty())
                spdlog::info("[SEG] head={} B, first IDR at offset {}", head_.size(), io);
            int ret = writeOut(head_.data(), (int)head_.size(), 0);
            head_.clear();
            if (ret != 0)
                return ret;
            return writeOut(b + io, s - io, 1);
        }

        // 这颗 VPU 一个输出块就是一张图（10-15 仿真：150 帧出 151 块），所以"本块里第一个
        // IDR"就是"下一张图是不是 IDR"。若驱动哪天改成一块塞多张图，这里会把整块切在第一个
        // IDR 上，段满的判断仍然成立。
        int io = firstIdrOffset(b, s);
        long held = frames_in_seg_.load();
        bool time_over = (nowMs() - seg_start_ms_) >= (uint64_t)cfg_.seg_ms;
        if (io >= 0 && (held >= cfg_.seg_frames || time_over))
        {
            if (io > 0 && cur_.write(reinterpret_cast<const char *>(b), io))
                bytes.fetch_add(io);
            if (0 != closeSeg())
                return -1;
            if (0 != openSeg())
                return -1;
            seg_start_ms_ = nowMs();
            return writeOut(b + io, s - io, 1);
        }
        return writeOut(b, s, countPictures(b, s));
    }

    void close() override
    {
        if (cur_)
            closeSeg();
    }

    std::string statePath() const
    {
        return cfg_.dir + "/state";
    }

private:
    Config cfg_;
    std::ofstream cur_;
    std::string part_path_, final_path_;
    std::atomic<long> frames_in_seg_ { 0 };
    uint64_t seg_start_ms_ = 0;
    bool started_ = false;
    std::vector<uint8_t> head_;
    static constexpr size_t head_max_ = 4096;

    static uint64_t nowMs()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
    }

    int writeOut(const uint8_t *b, int len, long pictures)
    {
        if (len <= 0)
            return 0;
        if (!cur_.write(reinterpret_cast<const char *>(b), len))
        {
            spdlog::error("[SEG] write failed (disk full?) -> sink returns -1");
            return -1;
        }
        cur_.flush();
        bytes.fetch_add(len);
        frames_in_seg_.fetch_add(pictures);
        if (frames.load() % 30 == 0)
            writeState();
        frames.fetch_add(pictures);
        return 0;
    }

    int openSeg()
    {
        long n = segs.load();
        part_path_ = cfg_.dir + "/seg" + std::to_string(n) + ".part";
        final_path_ = cfg_.dir + "/seg" + std::to_string(n) + ".h264";
        cur_.open(part_path_, std::ios::binary | std::ios::trunc);
        if (!cur_.is_open())
        {
            spdlog::error("[SEG] cannot open {}", part_path_);
            return -1;
        }
        frames_in_seg_.store(0);
        return 0;
    }

    int closeSeg()
    {
        if (!cur_.is_open())
            return 0;
        cur_.flush();
        cur_.close();
        std::rename(part_path_.c_str(), final_path_.c_str());
        segs.fetch_add(1);
        writeState();
        pruneOld();
        return 0;
    }

    void pruneOld()
    {
        if (cfg_.keep <= 0)
            return;
        long oldest = segs.load() - cfg_.keep;
        for (long n = 0; n < oldest; ++n)
        {
            std::error_code ec;
            std::filesystem::remove(cfg_.dir + "/seg" + std::to_string(n) + ".h264", ec);
        }
    }

    void writeState()
    {
        char buf[256];
        int len = snprintf(buf, sizeof(buf),
                           "seq=%ld bytes_total=%ld frames=%ld frames_in_seg=%ld head_bytes=%ld "
                           "fps=%d seg_frames=%d seg_ms=%d keep=%d dir=%s pid=%d unix=%ld\n",
                           segs.load(), (long)bytes.load(), (long)frames.load(),
                           (long)frames_in_seg_.load(), (long)head_bytes.load(),
                           cfg_.fps, cfg_.seg_frames, cfg_.seg_ms, cfg_.keep,
                           cfg_.dir.c_str(), (int)getpid(), (long)time(nullptr));
        std::ofstream s(statePath(), std::ios::binary | std::ios::trunc);
        s.write(buf, len);
    }

    // ---- Annex-B 扫描：只认 4 字节起始码在前、3 字节的兜底，与厂商
    //      hdmi_display_actor.hpp:73-111 的 h264KeyOffset/h264IdrOffset 同一套切法 ----

    static int startCodeLen(const uint8_t *p, int size, int i)
    {
        if (i + 4 < size && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1)
            return 4;
        if (i + 3 < size && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)
            return 3;
        return 0;
    }

    // nal_unit_type 就是首字节的低 5 位（forbidden_zero + nal_ref_idc 之后），厂商同款读法；
    // 这颗 VPU 的 H.264 输出不产生 31 号扩展类型，不做扩展分支。
    static int nalType(const uint8_t *p, int size, int i, int sc)
    {
        if (i + sc >= size)
            return -1;
        return p[i + sc] & 0x1f;
    }

    // 第一个 IDR（NAL 5）的起始码偏移；-1＝这块里没有
    static int firstIdrOffset(const uint8_t *p, int size)
    {
        for (int i = 0; i + 3 < size;)
        {
            int sc = startCodeLen(p, size, i);
            if (sc)
            {
                if (nalType(p, size, i, sc) == 5)
                    return i;
                i += sc;
                continue;
            }
            ++i;
        }
        return -1;
    }

    // 一个块里有几张图＝IDR(5) 与非 IDR slice(1) 的个数
    static long countPictures(const uint8_t *p, int size)
    {
        long n = 0;
        for (int i = 0; i + 3 < size;)
        {
            int sc = startCodeLen(p, size, i);
            if (sc)
            {
                int t = nalType(p, size, i, sc);
                if (t == 5 || t == 1)
                    ++n;
                i += sc;
                continue;
            }
            ++i;
        }
        return n ? n : 1;
    }
};
