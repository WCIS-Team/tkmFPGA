#pragma once

#include "pipeline/io/base/input_source.hpp"
#include "pipeline/base/enums.hpp"
#include "et_device.hpp"
#include <stdexcept>

#include "compile_fpai_target.hpp"

namespace fpai
{
    template <typename DeviceType>
    class SDICamera : public IInputSource
    {
    public:
        // Register definitions
        const uint64_t REGADDR_RESIZE_PIX_LEN = 0x7C;
        const uint64_t REGADDR_DONE_2_FETCH_CNT = 0xB4;

    public:
        SDICamera(int source_id, DeviceType &device,
                  int camera_width, int camera_height, camera_fmt fmt,
                  int frame_width, int frame_height, camera_fmt ps_format, crop_position ps_crop,
                  int net_w, int net_h, crop_position pl_crop,
                  uint64_t base_reg_addr_ = 0x40080000,
                  bool vtc_on = false,
                  resize_mode resize_mode = resize_mode::DOWNSAMPLE)
            : IInputSource(source_id, INPUT_SOURCE::SDI, DATA_TYPE::IMAGE), // 继承父类构造函数
              device_(device),
              camera_w_(camera_width),
              camera_h_(camera_height),
              camera_c_(3),
              frame_w_(frame_width), // resized frame size fed to PS
              frame_h_(frame_height),
              net_w_(net_w), // resized image size fed to PL icore
              net_h_(net_h),
              input_format_(fmt),
              ps_format_(ps_format),
              ps_crop_(ps_crop),
              pl_crop_(pl_crop),
              base_reg_addr_(base_reg_addr_),
              resize_mode_(resize_mode)
        {
            if (input_format_ == camera_fmt::RGB565)
            {
                ps_udma_buffer_bytesize_ = frame_w_ * frame_h_ * 2;
            }
            else if (input_format_ == camera_fmt::RGB)
            {
                ps_udma_buffer_bytesize_ = frame_w_ * frame_h_ * 3;
            }
            else if (input_format_ == camera_fmt::RGBA)
            {
                ps_udma_buffer_bytesize_ = frame_w_ * frame_h_ * 4;
            }
            else if (input_format_ == camera_fmt::YUV422)
            {
                ps_udma_buffer_bytesize_ = frame_w_ * frame_h_ * 2;
            }
            else
            {
                throw std::invalid_argument("Unsupported camera format");
            }
            take_addr_ = base_reg_addr_ + 0x04;
            write_addr_ = base_reg_addr_ + 0x50;
            done_addr_ = base_reg_addr_ + 0x58;
            // this->reset(); //为什么初始化的时候reset就会导致imagemake和icore的故障?
            this->resizePS(frame_w_, frame_h_, ps_format_, ps_crop_);
            this->resizePL(net_w_, net_h_, pl_crop_, resize_mode_);
            if (vtc_on)
                this->device_.defaultRegRegion().write(base_reg_addr_ + 0xB4, 1); // enable VTC
            else
                this->device_.defaultRegRegion().write(base_reg_addr_ + 0xB4, 0); // disable VTC
        }

    public:
        void resizePL(const int net_w, const int net_h, crop_position crop, resize_mode mode)
        {
            int RATIO_W, RATIO_H, IMG_W, IMG_H, BIAS_W, BIAS_H;
            int x0, y0, x1, y1;

            if (resize_mode_ == resize_mode::DOWNSAMPLE)
            {
                RATIO_W = camera_w_ / net_w;
                RATIO_H = camera_h_ / net_h;
            }
            else if (mode == resize_mode::NO_RESIZE)
            {
                RATIO_W = 1;
                RATIO_H = 1;
            }
            else
            {
                throw std::invalid_argument("Cannot change resize mode from NO_RESIZE to DOWNSAMPLE");
            }
            IMG_W = RATIO_W * net_w;
            IMG_H = RATIO_H * net_h;
            BIAS_W = (camera_w_ - IMG_W) / 2;
            BIAS_H = (camera_h_ - IMG_H) / 2;
            switch (crop)
            {
            case crop_position::center:
                x0 = (camera_w_ - IMG_W) / 2;
                y0 = (camera_h_ - IMG_H) / 2;
                x1 = camera_w_ - x0 - 1;
                y1 = camera_h_ - y0 - 1;
                break;

            case crop_position::top_left:
                x0 = 0;
                y0 = 0;
                x1 = IMG_W - 1;
                y1 = IMG_H - 1;
                break;

            case crop_position::top_right:
                x0 = camera_w_ - IMG_W;
                y0 = 0;
                x1 = camera_w_ - 1;
                y1 = IMG_H - 1;
                break;

            case crop_position::bottom_left:
                x0 = 0;
                y0 = camera_h_ - IMG_H;
                x1 = IMG_W - 1;
                y1 = camera_h_ - 1;
                break;

            case crop_position::bottom_right:
                x0 = camera_w_ - IMG_W;
                y0 = camera_h_ - IMG_H;
                x1 = camera_w_ - 1;
                y1 = camera_h_ - 1;
                break;
            }

            net_w_ = net_w;
            net_h_ = net_h;
            pl_crop_ = crop;
            hardResizePL<DeviceType>(device_, x0, y0, x1, y1, RATIO_W, RATIO_H, camera_w_, camera_h_, base_reg_addr_);
            ratio_bias_ = std::make_tuple(true, static_cast<float>(RATIO_W), static_cast<float>(RATIO_H), BIAS_W, BIAS_H);
        }

        void resizePS(const int frame_w, const int frame_h, camera_fmt fmt, crop_position crop)
        {
            frame_h_ = frame_h;
            frame_w_ = frame_w;
            ps_format_ = fmt;
            ps_crop_ = crop;

            int ws = camera_w_ / frame_w;
            int hs = camera_h_ / frame_h;
            int IMG_W = ws * frame_w;
            int IMG_H = hs * frame_h;
            int x0, y0, x1, y1;

            switch (crop)
            {
            case crop_position::center:
                x0 = (camera_w_ - IMG_W) / 2;
                y0 = (camera_h_ - IMG_H) / 2;
                x1 = camera_w_ - x0 - 1;
                y1 = camera_h_ - y0 - 1;
                break;

            case crop_position::top_left:
                x0 = 0;
                y0 = 0;
                x1 = IMG_W - 1;
                y1 = IMG_H - 1;
                break;

            case crop_position::top_right:
                x0 = camera_w_ - IMG_W;
                y0 = 0;
                x1 = camera_w_ - 1;
                y1 = IMG_H - 1;
                break;

            case crop_position::bottom_left:
                x0 = 0;
                y0 = camera_h_ - IMG_H;
                x1 = IMG_W - 1;
                y1 = camera_h_ - 1;
                break;

            case crop_position::bottom_right:
                x0 = camera_w_ - IMG_W;
                y0 = camera_h_ - IMG_H;
                x1 = camera_w_ - 1;
                y1 = camera_h_ - 1;
                break;
            }

            device_.defaultRegRegion().write(base_reg_addr_ + 0x18, 1);
            device_.defaultRegRegion().write(base_reg_addr_ + 0x5c, x0 << 16 | x1);
            device_.defaultRegRegion().write(base_reg_addr_ + 0x60, y0 << 16 | y1);
            device_.defaultRegRegion().write(base_reg_addr_ + 0x64, camera_w_ << 16 | camera_h_);
            device_.defaultRegRegion().write(base_reg_addr_ + 0x68, ws << 4 | hs);

            int image_fmt_channel = 4;
            switch (fmt)
            {
            case camera_fmt::RGB565:
                device_.defaultRegRegion().write(base_reg_addr_ + 0x78, 0);
                image_fmt_channel = 2;
                break;

            case camera_fmt::RGB:
                image_fmt_channel = 3;
                break;

            case camera_fmt::RGBA:
                device_.defaultRegRegion().write(base_reg_addr_ + 0x78, 0);
                image_fmt_channel = 4;
                break;

            case camera_fmt::YUV422:
                image_fmt_channel = 2;
                device_.defaultRegRegion().write(base_reg_addr_ + 0x7c, frame_w);
                device_.defaultRegRegion().write(base_reg_addr_ + 0x78, 1);
                break;

            default:
                break;
            }
            spdlog::info("Hard Resize PS, x0={}, y0={}, x1={}, y1={}, stride x={}, stride y={}, resize channel={}",
                         x0, y0, x1, y1, ws, hs, image_fmt_channel);
            device_.defaultRegRegion().write(base_reg_addr_ + 0x6c, frame_w * frame_h * image_fmt_channel / 8);
        }

        void reset() const
        {
            device_.defaultRegRegion().write(base_reg_addr_ + 0x70, 0x1); // reset signal
            while (true)
            {
                auto soft_rst_stat = device_.defaultRegRegion().read(base_reg_addr_ + 0x74);
                spdlog::warn("Waiting until reset is done...({})", soft_rst_stat);
                if ((soft_rst_stat & 0x1) == 1)
                    break;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            spdlog::info("Camera reset done.");
        }

        /// @brief Trigger the SDI camera to capture a frame and transfer it to the PS DDR memory at the specified MemChunk address
        /// @param memchunk The memory chunk representing the PS DDR buffer where the captured frame should be stored
        void take(const icraft::xrt::MemChunk &memchunk) const // 取帧SDICamera到PSDDR
        {
            // 取帧到MemChunk处
            device_.defaultRegRegion().write(write_addr_, memchunk->begin.addr() >> 3);
            device_.defaultRegRegion().write(take_addr_, 1);
        }

        /// @brief Wait for camera frame capture from plin to ps udma buffer to complete
        /// @param wait_time_ms Maximum time to wait in milliseconds (default: 100ms)
        /// @return true if frame capture completed successfully without errors, false if timeout occurred or error detected
        /// @details This function polls the camera done register until the capture is complete or timeout occurs.
        ///          It checks for both completion status (bit 0) and error status (bit 2) in the done register.
        ///          If an error is detected, the function prints the register status in binary format for debugging.

        bool wait(int wait_time_ms = 100) const
        {
            // for debug
            static int reset_cnt = 0;
            bool error = false;
            bool done = false;
            WaitUntil(
                [&]() -> bool
                {
                    auto camera_done = device_.defaultRegRegion().read(done_addr_);
                    error = camera_done & 0x4;
                    done = camera_done & 0x1;
                    return done;
                },
                std::chrono::duration<int, std::milli>(wait_time_ms)
                // 100ms
            );
            if (error)
            {
                std::cout << std::bitset<32>(device_.defaultRegRegion().read(done_addr_)) << std::endl;
                std::cout << std::dec;
                if (!done)
                {
                    this->reset();
                    reset_cnt++;
                    spdlog::warn("Camera error detected! Resetting camera... Total reset count: {}", reset_cnt);
                }
            }
            spdlog::trace("Camera total reset count during run: {}", reset_cnt);
            return !error && done;
        }
        uint64_t RegRead(uint64_t offset) const
        {
            return device_.defaultRegRegion().read(base_reg_addr_ + offset);
        }
        uint64_t getBufferSize() const { return ps_udma_buffer_bytesize_; }
        camera_fmt getPixelFormat() const { return input_format_; }
        int getWidth() const { return camera_w_; }      // get original camera input width
        int getHeight() const { return camera_h_; }     // get original camera input height
        int getChannel() const { return camera_c_; }    // get original camera input channel
        int getFrameWidth() const { return frame_w_; }  // get ps side output width
        int getFrameHeight() const { return frame_h_; } // get ps side output height
        int getNetWidth() const { return net_w_; }      // get icore side input width
        int getNetHeight() const { return net_h_; }     // get icore side input height
        std::tuple<bool, float, float, int, int> getRatioBias() const
        {
            return ratio_bias_;
        }

    private:
        DeviceType &device_;
        uint64_t ps_udma_buffer_bytesize_ = 0;
        uint64_t base_reg_addr_;
        uint64_t take_addr_;
        uint64_t write_addr_;
        uint64_t done_addr_;
        // 硬件固定参数
        const int camera_w_;
        const int camera_h_;
        const int camera_c_;
        const camera_fmt input_format_;

        // 软件可配参数，按照VPU压缩或HDMI显示改变
        crop_position ps_crop_;
        camera_fmt ps_format_;
        int frame_w_;
        int frame_h_;

        // AI模型输入尺寸参数
        crop_position pl_crop_;
        resize_mode resize_mode_;
        int net_w_;
        int net_h_;
        // 获取ratio和bias
        // 实际缩放比例和偏移量<是否硬件缩放, RATIO_W, RATIO_H, BIAS_W, BIAS_H>
        std::tuple<bool, float, float, int, int> ratio_bias_;
    };

    using GenericSDICamera = SDICamera<FPAIDevice>;

}