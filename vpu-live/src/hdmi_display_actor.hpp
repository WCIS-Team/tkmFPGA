/**
 * @brief An actor responsible for displaying raw image data on an HDMI output.
 *
 * This class acts as a final sink in a pipeline, taking image data from its
 * input queue and sending it to an HDMI display. It is designed for simple
 * display tasks without any AI post-processing. Its primary function is to
 * read the raw image data from a buffer (e.g., a udma_buf) into its internal
 * display buffer (`display_data_`) and then use the `RGB565HDMIDisplay`
 * object to render it on the screen.
 */
#pragma once
#include "bit_masks.hpp"

#include "pipeline/io/output/hdmi_display.hpp"
#include "pipeline/io/base/output_sink.hpp"
#include "pipeline/base/messages.hpp"
#include "pipeline/base/thread_safe_queue.hpp"
#include "pipeline/base/enums.hpp"
#include "pipeline/actor/base_actors.hpp"
#include "pipeline/memory/buffer_manager.hpp"
#include "pipeline/vpu/vpu.h"
#include <sys/stat.h>

#include <opencv2/opencv.hpp>
#include <thread>
#include <vector>
#include <memory>
#include <atomic>
#include <variant>
#include <mutex>
#include <condition_variable>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <fstream>

namespace fpai
{
    struct LivePump
    {
        std::mutex mu;
        std::condition_variable cv;
        std::vector<uint8_t> stage;
        int cols = 0;
        int rows = 0;
        bool ready = false;
        std::thread th;
        std::atomic<long> sent {0};
    };

    // ---- VPU 硬编出流：把 display_data_ 的 RGB565 转成 NV12 喂 /dev/video0，按 IDR 切片 ----
    struct H264Pump
    {
        std::mutex mu;
        std::condition_variable cv;
        std::vector<uint8_t> stage;
        int cols = 0;
        int rows = 0;
        bool ready = false;
        bool quit = false;
        std::thread th;
        std::atomic<long> segs {0};
        std::atomic<long> frames {0};
        std::atomic<long> out_chunks {0};
        std::atomic<long> bytes {0};
        std::atomic<long> drops {0};
        std::atomic<bool> dead {false};
    };

    // Annex-B：返回本块里第一个"可作为片头"的 NAL（IDR=5 或 SPS=7）的起始码偏移，没有则 -1
    inline int h264KeyOffset(const uint8_t *p, int size)
    {
        for (int i = 0; i + 4 < size; ++i)
        {
            int sc = 0;
            if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1)
                sc = 4;
            else if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)
                sc = 3;
            else
                continue;
            if (i + sc < size)
            {
                int t = p[i + sc] & 0x1f;
                if (t == 5 || t == 7)
                    return i;
            }
            i += sc;
        }
        return -1;
    }

    inline int h264IdrOffset(const uint8_t *p, int size)
    {
        for (int i = 0; i + 4 < size; ++i)
        {
            int sc = 0;
            if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1)
                sc = 4;
            else if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)
                sc = 3;
            else
                continue;
            if (i + sc < size && (p[i + sc] & 0x1f) == 5)
                return i;
            i += sc;
        }
        return -1;
    }

    inline void h264PumpMain(H264Pump &hp)
    {
        const int fps = []
        {
            const char *v = getenv("HDMI_H264_FPS");
            int t = v ? atoi(v) : 30;
            return (t >= 1 && t <= 120) ? t : 30;
        }();
        const long min_seg = []
        {
            const char *v = getenv("HDMI_H264_SEG");
            long t = v ? atol(v) : 30;
            return t > 0 ? t : 30;
        }();
        const int buffers = []
        {
            const char *v = getenv("HDMI_H264_BUFFERS");
            int t = v ? atoi(v) : 6;
            return (t >= 2 && t <= 6) ? t : 6;
        }();
        const std::string dir = []
        {
            const char *v = getenv("HDMI_H264_DIR");
            return (v && *v) ? std::string(v) : std::string("/dev/shm/h264");
        }();
        mkdir(dir.c_str(), 0755);

        auto flat = [](std::string s)
        {
            for (auto &ch : s)
                if (ch == '\n' || ch == '\r')
                    ch = ' ';
            return s;
        };

        auto now_ms = []
        {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now().time_since_epoch())
                .count();
        };

        std::vector<uint8_t> nv12, hdr;
        cv::Mat bgr, i420;
        FILE *cur = nullptr;
        std::string part_path, final_path;
        long seq = 0;
        long frames_in_seg = 0;
        bool hdr_done = false;

        auto writeState = [&]
        {
            char buf[260];
            int len = snprintf(buf, sizeof(buf),
                               "seq=%ld fps=%d seg_frames=%ld bytes_total=%ld frames=%ld out_chunks=%ld drops=%ld dead=%d pid=%d unix=%ld\n",
                               seq, fps, min_seg, (long)hp.bytes.load(), (long)hp.frames.load(),
                               (long)hp.out_chunks.load(),
                               (long)hp.drops.load(), (int)hp.dead.load(), (int)getpid(), (long)time(nullptr));
            std::ofstream s(dir + "/state", std::ios::binary | std::ios::trunc);
            s.write(buf, len);
        };
        auto killPump = [&hp](const char *why)
        {
            spdlog::warn("[H264] pump stopping: {}", why);
            hp.dead.store(true);
            std::lock_guard<std::mutex> g(hp.mu);
            hp.quit = true;
            hp.cv.notify_all();
        };
        auto openSeg = [&]
        {
            part_path = dir + "/seg" + std::to_string(seq) + ".part";
            final_path = dir + "/seg" + std::to_string(seq) + ".h264";
            cur = std::fopen(part_path.c_str(), "wb");
            frames_in_seg = 0;
            if (cur && !hdr.empty())
                std::fwrite(hdr.data(), 1, hdr.size(), cur);
        };
        auto closeSeg = [&]
        {
            if (!cur)
                return;
            std::fflush(cur);
            std::fclose(cur);
            cur = nullptr;
            {
                char ib[48];
                int il = snprintf(ib, sizeof(ib), "frames=%ld unix=%ld\n",
                                  frames_in_seg, (long)time(nullptr));
                std::ofstream s(dir + "/seg" + std::to_string(seq) + ".info", std::ios::binary | std::ios::trunc);
                s.write(ib, il);
            }
            std::rename(part_path.c_str(), final_path.c_str());
            hp.segs.store(seq + 1);
            writeState();
            ++seq;
        };

        vpu::Encoder *enc = nullptr;
        std::thread w;
        std::atomic<bool> wstop {false};

        try
        {
            for (;;)
            {
                std::vector<uint8_t> raw;
                int r = 0, c = 0;
                {
                    std::unique_lock<std::mutex> g(hp.mu);
                    hp.cv.wait(g, [&hp] { return hp.ready || hp.quit || hp.dead.load(); });
                    if (hp.quit)
                        break;
                    raw.swap(hp.stage);
                    r = hp.rows;
                    c = hp.cols;
                    hp.ready = false;
                }
                if (r < 32 || c < 32)
                    continue;

                if (!enc)
                {
                    enc = new vpu::Encoder("/dev/video0", r, c,
                                           V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_NV12,
                                           V4L2_BUF_TYPE_VIDEO_CAPTURE, V4L2_PIX_FMT_H264,
                                           buffers);
                    spdlog::info("[H264] session up {}x{} in=NV12 out=H264 buffers={} fps={}", c, r, buffers, fps);
                    try
                    {
                        enc->setFrameRate(fps);
                    }
                    catch (const std::exception &e)
                    {
                        spdlog::warn("[H264] setFrameRate({}) failed: {}", fps, flat(e.what()));
                    }
                    w = std::thread(
                        [&]
                        {
                            uint64_t tw = now_ms();
                            while (!enc->streamon_flag_.load() && !wstop.load() && now_ms() - tw < 20000)
                                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                            if (!enc->streamon_flag_.load())
                            {
                                spdlog::warn("[H264] no streamon after 20 s, frames={} out={}",
                                             (long)hp.frames.load(), (long)hp.out_chunks.load());
                                wstop.store(true);
                                killPump("capture queue never started");
                                return;
                            }
                            spdlog::info("[H264] streamon after {} ms, frames={}", (uint64_t)(now_ms() - tw),
                                         (long)hp.frames.load());
                            while (!wstop.load())
                            {
                                void *p = nullptr;
                                int s = 0;
                                bool more = true;
                                try
                                {
                                    more = enc->getOutput(p, s);
                                }
                                catch (const std::exception &e)
                                {
                                    spdlog::warn("[H264] getOutput ended: {}", flat(e.what()));
                                    killPump("getOutput threw");
                                    break;
                                }
                                if (s > 0 && p)
                                {
                                    long oc = hp.out_chunks.fetch_add(1) + 1;
                                    if (oc == 1)
                                        spdlog::info("[H264] first output chunk size={}", s);
                                    const uint8_t *b = reinterpret_cast<const uint8_t *>(p);
                                    if (!hdr_done)
                                    {
                                        int io = h264IdrOffset(b, s);
                                        hdr.assign(b, b + (io < 0 ? s : io));
                                        hp.bytes.fetch_add(s);
                                        if (io < 0)
                                            continue;
                                        hdr_done = true;
                                        openSeg();
                                        if (!cur)
                                        {
                                            spdlog::warn("[H264] cannot open {}", part_path);
                                            wstop.store(true);
                                            killPump("segment file open failed");
                                            break;
                                        }
                                        if (s > io)
                                            std::fwrite(b + io, 1, s - io, cur);
                                        frames_in_seg = 1;
                                        if (!more)
                                            break;
                                        continue;
                                    }
                                    int ko = h264KeyOffset(b, s);
                                    if (ko >= 0 && frames_in_seg >= min_seg)
                                    {
                                        if (cur && ko > 0)
                                            std::fwrite(b, 1, ko, cur);
                                        closeSeg();
                                        openSeg();
                                        if (!cur)
                                        {
                                            spdlog::warn("[H264] cannot open {}", part_path);
                                            wstop.store(true);
                                            killPump("segment file open failed");
                                            break;
                                        }
                                        if (s > ko)
                                            std::fwrite(b + ko, 1, s - ko, cur);
                                        frames_in_seg = 1;
                                    }
                                    else
                                    {
                                        if (!cur)
                                            openSeg();
                                        if (!cur)
                                        {
                                            spdlog::warn("[H264] cannot open {}", part_path);
                                            wstop.store(true);
                                            killPump("segment file open failed");
                                            break;
                                        }
                                        std::fwrite(b, 1, s, cur);
                                        ++frames_in_seg;
                                    }
                                    hp.bytes.fetch_add(s);
                                }
                                if (!more)
                                    break;
                            }
                        });
                }

                if (hp.dead.load())
                    break;

                cv::Mat src(r, c, CV_8UC2, raw.data());
                cv::cvtColor(src, bgr, cv::COLOR_BGR5652BGR);
                cv::cvtColor(bgr, i420, cv::COLOR_BGR2YUV_I420);
                const size_t yb = (size_t)r * c;
                nv12.resize(yb + yb / 2);
                const uint8_t *ip = i420.data;
                memcpy(nv12.data(), ip, yb);
                const uint8_t *up = ip + yb;
                const uint8_t *vp = ip + yb + yb / 4;
                for (size_t i = 0; i < yb / 4; ++i)
                {
                    nv12[yb + 2 * i] = up[i];
                    nv12[yb + 2 * i + 1] = vp[i];
                }
                enc->enqueueDataPtr(reinterpret_cast<char *>(nv12.data()));
                if (hp.frames.fetch_add(1) % 30 == 29)
                    writeState();
            }
        }
        catch (const std::exception &e)
        {
            spdlog::warn("[H264] pump stopped by exception: {}", flat(e.what()));
            hp.dead.store(true);
        }

        wstop.store(true);
        if (enc)
        {
            try
            {
                enc->streamOff();
            }
            catch (...)
            {
            }
        }
        if (w.joinable())
            w.join();
        if (cur)
        {
            std::fflush(cur);
            std::fclose(cur);
            std::remove(part_path.c_str());
            cur = nullptr;
        }
        if (enc)
            delete enc;
        spdlog::info("[H264] pump exited, segs={} frames={}", (long)hp.segs.load(), (long)hp.frames.load());
    }

    template <typename DeviceType, typename InputMsgType>
    class HDMIDisplayActor : public BaseActor<InputMsgType, void>
    {
    public:
        static constexpr std::string_view LogP = "[HDMI]";
        constexpr static int OPT_DEBUG_FLAGS = BIT_MASK_0 | BIT_MASK_1; // 调试标志位

        // 定义后处理函数类型别名
        using PostProcessingFunc = std::function<void(const InputMsgType &, cv::Mat &)>;

    public:
        HDMIDisplayActor(int id,
                         std::unique_ptr<RGB565HDMIDisplay<DeviceType>> display,
                         DeviceType &device,
                         BufferManager &buffer_manager,
                         std::string chunk_group_id,
                         PostProcessingFunc post_processor = nullptr)
            : BaseActor<InputMsgType, void>(buffer_manager),
              device_(device),
              sink_id_(id),
              display_(std::move(display)),
              display_data_(display_->getBufferSize()),
              chunk_group_id_(chunk_group_id),
              post_processor_{std::move(post_processor)} // 存储后处理函数
        {
        }
        // 虚析构函数是好习惯
        ~HDMIDisplayActor()
        {
            this->stop();
        };

    protected:
        void loop() override
        {
            while (!this->stop_flag_)
            {
                auto t_start = std::chrono::steady_clock::now();
                InputMsgType msg;
                this->input_queue_->wait_and_pop(msg);
                auto t_wait_pop_end = std::chrono::steady_clock::now();
                auto t_wait_pop_duration = std::chrono::duration_cast<std::chrono::microseconds>(t_wait_pop_end - t_start);

                // buffer_index 是基类成员，可以直接访问。
                if (msg.meta.buffer_index < 0)
                    continue; // 安全检查
                if (msg.meta.error_input)
                {
                    spdlog::warn("HDMIDisplayActor received an error frame, skipping display.");
                    // 归还 buffer index
                    this->buffer_manager_.returnIndex(chunk_group_id_, msg.meta.buffer_index);
                    continue;
                }
                // 1. 读取数据
                auto &chunk = this->buffer_manager_.getChunk(chunk_group_id_, msg.meta.buffer_index);
                readout_udma_memchunk(chunk);
                auto t_read_end = std::chrono::steady_clock::now();
                auto t_read_duration = std::chrono::duration_cast<std::chrono::microseconds>(t_read_end - t_wait_pop_end);
                // 2. 可选的后处理
                if (msg.meta.error_input)
                {
                    LOG_ERROR(LogP, "[{}][Buff{}] Skip post-processing due to error input frame.",
                              msg.meta.source_id,
                              msg.meta.buffer_index);
                }
                else if (post_processor_)
                {
                    // The format check is useful, but for RGB565, the type is CV_8UC2
                    if (display_->getCameraFmt() != camera_fmt::RGB565)
                    {
                        spdlog::error("HDMIDisplayActor only support RGB565 format for post processing");
                        throw std::invalid_argument("HDMIDisplayActor only support RGB565 format for post processing");
                    }
                    cv::Mat current_frame = cv::Mat(display_->getFrameHeight(), display_->getFrameWidth(), CV_8UC2, display_data_.data());
                    // cv::Mat current_frame = cv::Mat(display_->getFrameHeight(), display_->getFrameWidth(), CV_8UC2, chunk->begin.cptr());
                    post_processor_(msg, current_frame);
                }
                auto t_post_end = std::chrono::steady_clock::now();
                auto t_post_duration = std::chrono::duration_cast<std::chrono::microseconds>(t_post_end - t_read_end);

                // 3. 直接显示
                display_->show(display_data_.data()); // 将内部向量的数据发送到 HDMI 显示器
                // display_->show(chunk); // 将内部向量的数据发送到 HDMI 显示器

                if (OPT_DEBUG_FLAGS & BIT_MASK_1)
                {
                    static std::atomic<long> frame_seq = 0;
                    static LivePump lp;
                    static bool lp_booted = false;
                    static long live_every = 0;
                    static double live_scale = 0.5;

                    if (!lp_booted)
                    {
                        lp_booted = true;
                        if (const char *e = getenv("HDMI_LIVE_EVERY")) live_every = atol(e);
                        if (const char *e = getenv("HDMI_LIVE_SCALE")) live_scale = atof(e);
                        if (live_every < 0) live_every = 0;
                        if (live_scale <= 0.0 || live_scale > 1.0) live_scale = 1.0;
                        if (live_every > 0)
                        {
                            lp.th = std::thread(
                                [&lp, live_scale]()
                                {
                                    const int quality = []
                                    {
                                        const char *q = getenv("HDMI_LIVE_QUALITY");
                                        int v = q ? atoi(q) : 70;
                                        return (v >= 1 && v <= 100) ? v : 70;
                                    }();
                                    std::vector<int> prm {cv::IMWRITE_JPEG_QUALITY, quality};
                                    long last_emit = -1;
                                    for (;;)
                                    {
                                        std::vector<uint8_t> raw;
                                        int r = 0, c = 0;
                                        {
                                            std::unique_lock<std::mutex> g(lp.mu);
                                            lp.cv.wait(g, [&lp] { return lp.ready; });
                                            raw.swap(lp.stage);
                                            r = lp.rows;
                                            c = lp.cols;
                                            lp.ready = false;
                                        }
                                        auto t0 = std::chrono::steady_clock::now();
                                        cv::Mat src(r, c, CV_8UC2, raw.data());
                                        cv::Mat bgr, scaled;
                                        cv::cvtColor(src, bgr, cv::COLOR_BGR5652BGR);
                                        if (live_scale < 1.0)
                                        {
                                            cv::resize(bgr, scaled, cv::Size(), live_scale, live_scale, cv::INTER_AREA);
                                            bgr = scaled;
                                        }
                                        std::vector<uint8_t> jpg;
                                        if (!cv::imencode(".jpg", bgr, jpg, prm) || jpg.empty()) continue;
                                        std::ofstream f("/tmp/live.jpg.part", std::ios::binary | std::ios::trunc);
                                        f.write(reinterpret_cast<const char *>(jpg.data()), jpg.size());
                                        f.close();
                                        rename("/tmp/live.jpg.part", "/tmp/live.jpg");
                                        long cnt = lp.sent.fetch_add(1) + 1;
                                        auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                                            std::chrono::steady_clock::now() - t0).count();
                                        if (cnt == 1 || cnt - last_emit >= 30)
                                        {
                                            last_emit = cnt;
                                            char buf[200];
                                            int len = snprintf(buf, sizeof(buf),
                                                               "sent=%ld jpeg_bytes=%zu enc_us=%ld out=%dx%d src=%dx%d q=%d pid=%d unix=%ld\n",
                                                               cnt, jpg.size(), us, bgr.cols, bgr.rows, c, r, quality,
                                                               (int)getpid(), (long)time(nullptr));
                                            std::ofstream s("/tmp/live.stat", std::ios::binary | std::ios::trunc);
                                            s.write(buf, len);
                                        }
                                    }
                                });
                            lp.th.detach();
                        }
                    }

                    static H264Pump hp;
                    static bool hp_booted = false;
                    static long h264_every = 1;

                    if (!hp_booted)
                    {
                        hp_booted = true;
                        if (const char *e = getenv("HDMI_H264_EVERY")) h264_every = atol(e);
                        if (h264_every < 0) h264_every = 0;
                        if (h264_every > 0)
                        {
                            hp.th = std::thread(h264PumpMain, std::ref(hp));
                            hp.th.detach();
                        }
                    }

                    long n = frame_seq.fetch_add(1);

                    if (live_every > 0 && (n % live_every) == 0)
                    {
                        bool pushed = false;
                        {
                            std::lock_guard<std::mutex> g(lp.mu);
                            if (!lp.ready)
                            {
                                const size_t bytes = display_data_.size();
                                lp.stage.resize(bytes);
                                memcpy(lp.stage.data(), display_data_.data(), bytes);
                                lp.rows = display_->getFrameHeight();
                                lp.cols = display_->getFrameWidth();
                                lp.ready = true;
                                pushed = true;
                            }
                        }
                        if (pushed) lp.cv.notify_one();
                    }

                    if (h264_every > 0 && !hp.dead.load() && (n % h264_every) == 0)
                    {
                        bool pushed = false;
                        {
                            std::lock_guard<std::mutex> g(hp.mu);
                            if (!hp.ready)
                            {
                                const size_t bytes = display_data_.size();
                                hp.stage.resize(bytes);
                                memcpy(hp.stage.data(), display_data_.data(), bytes);
                                hp.rows = display_->getFrameHeight();
                                hp.cols = display_->getFrameWidth();
                                hp.ready = true;
                                pushed = true;
                            }
                        }
                        if (pushed)
                            hp.cv.notify_one();
                        else
                            hp.drops.fetch_add(1);
                    }
                }

                // 4. 归还 buffer index
                this->buffer_manager_.returnIndex(chunk_group_id_, msg.meta.buffer_index);
                auto t_end = std::chrono::steady_clock::now();
                auto t_duration = std::chrono::duration_cast<std::chrono::microseconds>(t_end - t_start);
                if (OPT_DEBUG_FLAGS & BIT_MASK_0)
                {
                    spdlog::info("[POST][{}] T({:.2f}ms)=pop({:.2f}ms)+read({:.2f}ms)+post({:.2f}ms); buff[{}]: {}",
                                 msg.meta.source_id,
                                 float(t_duration.count()) / 1000,
                                 float(t_wait_pop_duration.count()) / 1000,
                                 float(t_read_duration.count()) / 1000,
                                 float(t_post_duration.count()) / 1000,
                                 msg.meta.buffer_index,
                                 this->buffer_manager_.getStatusString(chunk_group_id_));
                }
            }
        }

        void readout_udma_memchunk(const icraft::xrt::MemChunk &memchunk)
        {
            memchunk.read(reinterpret_cast<char *>(display_data_.data()), 0, display_data_.size());
        }

        int sink_id_;
        std::unique_ptr<RGB565HDMIDisplay<DeviceType>> display_;
        std::vector<int8_t> display_data_;
        std::string chunk_group_id_;
        PostProcessingFunc post_processor_;
        DeviceType &device_;
    };
}
