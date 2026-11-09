#pragma once
#include "pipeline/io/output/istream_sink.hpp"
#include "pipeline/vpu/mvx-v4l2-controls.h"
#include "pipeline/vpu/vpu.h"

#include <spdlog/spdlog.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <linux/videodev2.h>

namespace fpai
{

    /**
     * @brief 直播编码核的构造参数。全部是 PS 侧就能决定的东西，不含任何 PL 寄存器。
     *
     * input_format 只有两种在这板上枚举过的可用值（十五条 15.2，A）：
     *   V4L2_PIX_FMT_UYVY  ＝每像素 2 字节，PL 直出或 PS 模拟都行，不用转色；
     *   V4L2_PIX_FMT_NV12  ＝每像素 1.5 字节，PL 出 RGB565 时要先转。
     * buffers 上限 6：>6 触发内核 MMU ABORT（15.4d，A）。
     */
    struct VpuLiveConfig
    {
        std::string device = "/dev/video0";
        int width = 960;
        int height = 540;
        int fps = 30;
        int buffers = 4;
        uint32_t input_format = V4L2_PIX_FMT_UYVY;
        uint32_t codec_format = V4L2_PIX_FMT_H264;
        int qp = -1; // >=0 才去试固定 QP；这颗的码率控制在用户态打不开（15.9）
    };

    /**
     * @brief 只做"裸帧进、Annex-B 出"这件事的核。厂商 VPUEncoderActor 的 PS-only 拆法：
     * 编码会话＋一条取流线程＋一个 IStreamSink，不碰 BufferManager、不碰 Device、不碰寄存器，
     * 所以喂进来的帧指针可以是 udmabuf 的 chunk，也可以是普通堆内存（vpu.h:890 本来就要
     * memcpy 进驱动自己的 mmap 缓冲，"零拷贝"只到用户态这一层）。
     */
    class VpuLiveCore
    {
    public:
        VpuLiveCore(const VpuLiveConfig &config, std::unique_ptr<IStreamSink> sink)
            : config_(config),
              sink_(std::move(sink))
        {
            if (config_.buffers > 6)
                config_.buffers = 6;
            enc_ = std::make_unique<AccessEncoder>(
                config_.device.c_str(),
                config_.height, config_.width,
                V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, config_.input_format,
                V4L2_BUF_TYPE_VIDEO_CAPTURE, config_.codec_format,
                config_.buffers);
            try
            {
                enc_->setFrameRate(config_.fps);
            }
            catch (const std::exception &e)
            {
                spdlog::warn("[LIVE] setFrameRate({}) failed: {}", config_.fps, e.what());
            }
            if (config_.qp >= 0)
                enc_->rateOffAndPinQp(config_.qp);
            spdlog::info("[LIVE] session up {}x{} in={:#x} out={:#x} buffers={} fps={} qp={}",
                         config_.width, config_.height, config_.input_format,
                         config_.codec_format, config_.buffers, config_.fps, config_.qp);
        }

        ~VpuLiveCore()
        {
            stop();
        }

        VpuLiveCore(const VpuLiveCore &) = delete;
        VpuLiveCore &operator=(const VpuLiveCore &) = delete;

        void start()
        {
            drain_ = std::thread(&VpuLiveCore::streamOutLoop, this);
        }

        /**
         * @brief 塞一张裸帧给编码器。非阻塞（驱动侧满不满由 enqueueDataPtr 自己管）。
         * @return  false＝驱动抛异常，核已经判死，调用方该停流
         */
        bool pushFrame(const void *data)
        {
            if (dead_.load() || !data)
                return false;
            try
            {
                enc_->enqueueDataPtr(const_cast<char *>(static_cast<const char *>(data)));
                frames_in.fetch_add(1);
                return true;
            }
            catch (const std::exception &e)
            {
                fail("enqueueDataPtr", e.what());
                return false;
            }
        }

        void stop()
        {
            if (stopping_.exchange(true))
                return;
            if (enc_)
            {
                try
                {
                    enc_->streamOff(); // 唤醒阻塞在 DQBUF 上的取流线（厂商 :317 同一条关键动作）
                }
                catch (...)
                {
                }
            }
            if (drain_.joinable())
                drain_.join();
            if (sink_)
                sink_->close();
        }

        bool alive() const { return !dead_.load(); }
        std::atomic<long> frames_in { 0 };
        std::atomic<long> chunks_out { 0 };
        std::atomic<long> wait_streamon_ms { 0 };
        const std::string &why() const { return why_; }

    private:
        /** fd_ 是 protected，子类拿去发私有 ioctl——vpu_br.cpp／sdi_live.cpp 同一手法。*/
        class AccessEncoder : public vpu::Encoder
        {
        public:
            using vpu::Encoder::Encoder;

            bool rateOffAndPinQp(int qp)
            {
                bool ok = false;
                v4l2_rate_control rc {};
                rc.rc_type = V4L2_OPT_RATE_CONTROL_MODE_OFF;
                if (0 == ioctl(fd_, VIDIOC_S_MVX_RATE_CONTROL, &rc))
                {
                    spdlog::info("[LIVE] MVX rate control OFF (fixed-QP path)");
                    ok = true;
                }
                else
                    spdlog::warn("[LIVE] VIDIOC_S_MVX_RATE_CONTROL rejected: {}", strerror(errno));

                int q = qp;
                if (0 == ioctl(fd_, VIDIOC_S_MVX_QP_EPR, &q))
                {
                    spdlog::info("[LIVE] fixed QP={} via VIDIOC_S_MVX_QP_EPR", qp);
                    ok = true;
                }
                else
                    spdlog::warn("[LIVE] VIDIOC_S_MVX_QP_EPR rejected: {}", strerror(errno));
                return ok;
            }
        };

        void fail(const char *where, const char *what)
        {
            if (!dead_.exchange(true))
            {
                why_ = std::string(where) + ": " + what;
                spdlog::warn("[LIVE] core dying at {}: {}", where, what);
            }
        }

        void streamOutLoop()
        {
            // 厂商 VPUEncoderActor::stream_out_loop 同构，只改一处：等 streamon 那个循环
            // 原版是无条件忙等、既不查停止也不超时（vpu_encoder_actor.hpp:299-301），
            // 一帧都没喂进来就永远转。这里带 20 s 上限并且查 stopping_。
            uint64_t t0 = nowMs();
            while (!enc_->streamon_flag_.load() && !stopping_.load() &&
                   nowMs() - t0 < 20000)
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            wait_streamon_ms.store((long)(nowMs() - t0));
            if (!enc_->streamon_flag_.load())
            {
                if (!stopping_.load())
                    fail("streamon", "capture queue never started");
                return;
            }
            spdlog::info("[LIVE] streamon after {} ms", wait_streamon_ms.load());

            if (!sink_ || 0 != sink_->open(""))
            {
                fail("sink.open", "stream sink open failed");
                return;
            }

            void *ptr = nullptr;
            int size = 0;
            while (!stopping_.load())
            {
                bool more = true;
                try
                {
                    more = enc_->getOutput(ptr, size);
                }
                catch (const std::exception &e)
                {
                    // stop() 调 streamOff() 之后 DQBUF 必然报错，那是正常收流不是死亡
                    if (stopping_.load())
                        break;
                    fail("getOutput", e.what());
                    break;
                }
                if (size > 0 && ptr)
                {
                    chunks_out.fetch_add(1);
                    SinkPacket packet;
                    packet.data = ptr;
                    packet.size = (size_t)size;
                    int ret = sink_->handlePacket(packet);
                    if (ret != 0)
                    {
                        spdlog::warn("[LIVE] sink returned {}, stopping stream", ret);
                        try
                        {
                            enc_->streamOff(); // 唤醒可能阻塞在 DQBUF 上的自己
                        }
                        catch (...)
                        {
                        }
                        break;
                    }
                }
                if (!more)
                    break;
            }
            spdlog::info("[LIVE] drain exited: in={} out={}", (long)frames_in.load(),
                         (long)chunks_out.load());
        }

        static uint64_t nowMs()
        {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now().time_since_epoch())
                .count();
        }

        VpuLiveConfig config_;
        std::unique_ptr<AccessEncoder> enc_;
        std::unique_ptr<IStreamSink> sink_;
        std::thread drain_;
        std::atomic<bool> stopping_ { false };
        std::atomic<bool> dead_ { false };
        std::string why_;
    };
}
