#pragma once

#include "pipeline/base/message_queue.hpp"
#include "pipeline/core/functional_actor.hpp"
#include "pipeline/core/debug_flags.hpp"
#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/memory/slot_lease.hpp"
#include "log_utils.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <type_traits>
#include <utility>

namespace fpai::pipeline
{
    // Model-specific input Contexts may derive from this plain struct and add
    // Session/tensor state. The inheritance is static and has no virtual API.
    template <typename DeviceType, typename BufferPool, typename Message = InputMessageForIcore>
    struct SdiInputContext
    {
        // 编译期 SDI 诊断开关，修改后需重新编译；用 | 组合，0 关闭位控诊断。
        // BIT_MASK_0：逐帧 capture/prepare DEBUG 耗时，需 sys.log_level: debug 才可见。
        // BIT_MASK_1：由 sdi_imagemake_input.hpp 的默认 ImageMake 回调消费；成功帧
        //   输出 tensor_<index>.ftmp + .txt 到 <FPAI_DEBUG_DIR>/imagemake/source_<id>/
        //   frame_<timestamp>/，根目录默认 ./logs/pipeline；不生成 PNG。
        // 纯 SDI 或替换了默认 ImageMake 回调的路径不会自动获得 bit1 导出功能。
        // BIT_MASK_2..7 未使用；文件导出与 log_level、sys.profile 相互独立。
        static constexpr int OPT_DEBUG_FLAGS = BIT_MASK_0;

        using message_type = Message;

        DeviceType *device{nullptr};
        BufferPool *buffers{nullptr};
        ThreadSafeQueue<Message> *output_queue{nullptr};
        std::unique_ptr<SDICamera<DeviceType>> camera;
        int source_id{0};

        // Frame storage uses UDMA; lifetime and alignment remain explicit.
        bool auto_free{false};
        std::uint64_t alignment{0};
        bool enable_profiling{false};
        std::size_t profile_every_n_frames{60};
        std::size_t profiled_frames{0};
        std::uint64_t profile_total_us{0};
        // Set false when several inputs share one queue and the application
        // installs bind_message_reclaimer_by_source() once for that queue.
        bool install_output_reclaimer{true};
    };

    template <typename Context>
    [[nodiscard]] Status validate_sdi_input_context(const Context &context) noexcept
    {
        if (!context.device || !context.buffers || !context.output_queue || !context.camera)
        {
            return Status::failure(
                StatusCode::initialization_failed,
                "SDI input Context is incomplete");
        }
        if (context.source_id < 0 ||
            context.source_id > std::numeric_limits<std::int16_t>::max())
        {
            return Status::failure(
                StatusCode::initialization_failed,
                "SDI source id is outside the supported message range");
        }
        if (context.alignment == 0 ||
            (context.alignment & (context.alignment - 1U)) != 0)
        {
            return Status::failure(
                StatusCode::initialization_failed,
                "SDI memory alignment is invalid");
        }
        if (context.profile_every_n_frames == 0)
        {
            return Status::failure(
                StatusCode::initialization_failed,
                "SDI profiling window must be non-zero");
        }
        return Status::success();
    }

    template <typename Context, typename ModelInitFunction>
    [[nodiscard]] Status initialize_sdi_input(
        Context &context,
        ModelInitFunction &model_init)
    {
        const Status common_status = validate_sdi_input_context(context);
        if (!common_status.ok())
        {
            return common_status;
        }

        // Validate model/session bindings before reserving DMA memory.
        const Status model_status = model_init(context);
        if (!model_status.ok())
        {
            return model_status;
        }

        context.profiled_frames = 0;
        context.profile_total_us = 0;

        context.buffers->initialize(
            *context.device,
            context.camera->getBufferSize(),
            "udma",
            context.auto_free,
            context.alignment);
        if (context.install_output_reclaimer)
        {
            bind_message_reclaimer(*context.output_queue, *context.buffers);
        }
        return Status::success();
    }

    template <typename Context, typename BeforeCaptureFunction, typename DuringCaptureFunction, typename AfterCaptureFunction>
    [[nodiscard]] StepResult sdi_input_step(
        Context &context,
        BeforeCaptureFunction &before_capture,
        DuringCaptureFunction &during_capture,
        AfterCaptureFunction &after_capture)
    {
        using BufferPool = std::remove_reference_t<decltype(*context.buffers)>;
        using Message = typename Context::message_type;

        using Clock = std::chrono::steady_clock;
        Clock::time_point step_start{};
        if (context.enable_profiling)
        {
            step_start = Clock::now();
        }
        const int slot = context.buffers->request();
        if (slot < 0)
        {
            return StepResult::stop();
        }

        SlotLease<BufferPool> lease(*context.buffers, slot);
        Message message{};
        initialize_message(
            message,
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count(),
            context.source_id,
            slot);

        const Status before_status = before_capture(context, slot, message);
        if (!before_status.ok())
        {
            return StepResult::fatal(before_status);
        }

        DebugStepTimer<(Context::OPT_DEBUG_FLAGS & BIT_MASK_0) != 0> debug_timer("SDI capture/prepare", context.source_id, slot);
        context.camera->take(context.buffers->chunk(slot));

        Status during_status = Status::success();
        try
        {
            during_status = during_capture(context, slot, message);
        }
        catch (...)
        {
            // Once take() has armed PL-to-PS DMA, settle it before the slot
            // guard can return the underlying MemChunk to the pool.
            (void)context.camera->wait();
            throw;
        }

        if (!context.camera->wait())
        {
            mark_message_invalid_ps_frame(message);
            LOG_ERROR("[SDICam]", "[{}] PL-to-PS frame failed for slot {}",
                      context.source_id, slot);
        }
        if (!during_status.ok())
        {
            return StepResult::fatal(during_status);
        }

        // PS pixels are now settled. A case-specific CPU preprocessor can
        // read the slot here and fill message.image_tensors before enqueue.
        // The callback also sees invalid_ps_frame when the capture failed.
        const Status after_status = after_capture(context, slot, message);
        if (!after_status.ok())
        {
            return StepResult::fatal(after_status);
        }

        if (context.enable_profiling)
        {
            const auto step_time =
                std::chrono::duration_cast<std::chrono::microseconds>(
                    Clock::now() - step_start);
            context.profile_total_us +=
                static_cast<std::uint64_t>(step_time.count());
            ++context.profiled_frames;
            if (context.profiled_frames % context.profile_every_n_frames == 0)
            {
                LOG_INFO("[SDICam]",
                         "[{}] window={} avg_capture_prepare={:.2f}ms slots={}/{}",
                         context.source_id,
                         context.profile_every_n_frames,
                         static_cast<float>(context.profile_total_us) /
                             static_cast<float>(context.profile_every_n_frames) /
                             1000.0F,
                         context.buffers->available_count(),
                         BufferPool::slot_count);
                context.profile_total_us = 0;
            }
        }

        // A stopped queue consumes the message through bind_message_reclaimer().
        lease.transfer();
        try
        {
            if (!context.output_queue->push(std::move(message)))
            {
                return StepResult::stop();
            }
        }
        catch (...)
        {
            (void)context.buffers->release(slot);
            throw;
        }
        return StepResult::next();
    }

    template <typename Context>
    void stop_sdi_input(Context &context) noexcept
    {
        if (context.output_queue)
        {
            context.output_queue->stop();
        }
        if (context.buffers)
        {
            context.buffers->cancel();
        }
    }

    // The base input is a complete SDI data path. Model hooks are optional;
    // applications override only the operations their input actually needs.
    struct NoSdiInputHook
    {
        template <typename Context, typename... Args>
        [[nodiscard]] Status operator()(Context &, Args &&...) const noexcept
        {
            return Status::success();
        }
    };

    struct NoSdiInputShutdown
    {
        template <typename Context>
        void operator()(Context &) const noexcept
        {
        }
    };

    template <
        typename ModelInitFunction,
        typename BeforeCaptureFunction,
        typename AfterCaptureFunction,
        typename ShutdownFunction,
        typename DuringCaptureFunction = NoSdiInputHook>
    class SdiInputOps
    {
    public:
        SdiInputOps(
            ModelInitFunction model_init = {},
            BeforeCaptureFunction before_capture = {},
            AfterCaptureFunction after_capture = {},
            ShutdownFunction shutdown = {},
            DuringCaptureFunction during_capture = {})
            : model_init_(std::move(model_init)),
              before_capture_(std::move(before_capture)),
              after_capture_(std::move(after_capture)),
              shutdown_(std::move(shutdown)),
              during_capture_(std::move(during_capture))
        {
        }

        template <typename Context>
        [[nodiscard]] Status init(Context &context)
        {
            return initialize_sdi_input(context, model_init_);
        }

        template <typename Context>
        [[nodiscard]] StepResult loop(Context &context)
        {
            return sdi_input_step(context, before_capture_, during_capture_, after_capture_);
        }

        template <typename Context>
        void request_stop(Context &context) noexcept
        {
            stop_sdi_input(context);
        }

        template <typename Context>
        void shutdown(Context &context) noexcept(
            std::is_nothrow_invocable_v<ShutdownFunction &, Context &>)
        {
            shutdown_(context);
        }

    private:
        ModelInitFunction model_init_;
        BeforeCaptureFunction before_capture_;
        AfterCaptureFunction after_capture_;
        ShutdownFunction shutdown_;
        DuringCaptureFunction during_capture_;
    };

    // Hooks replace model initialization, pre-capture preparation and
    // post-wait message construction, respectively. Omitted hooks do nothing.
    // during_capture is reserved for work that overlaps SDI DMA (ImageMake).
    // CPU image preprocessing belongs in after_capture, never during_capture.
    template <
        typename ExecutionPolicy = StdThreadPolicy,
        typename Context,
        typename ModelInitFunction = NoSdiInputHook,
        typename BeforeCaptureFunction = NoSdiInputHook,
        typename AfterCaptureFunction = NoSdiInputHook,
        typename ShutdownFunction = NoSdiInputShutdown,
        typename DuringCaptureFunction = NoSdiInputHook>
    [[nodiscard]] auto make_sdi_input_actor(
        Context &context,
        ModelInitFunction &&model_init = {},
        BeforeCaptureFunction &&before_capture = {},
        AfterCaptureFunction &&after_capture = {},
        ShutdownFunction &&shutdown = {},
        DuringCaptureFunction &&during_capture = {})
    {
        using Ops = SdiInputOps<
            std::decay_t<ModelInitFunction>,
            std::decay_t<BeforeCaptureFunction>,
            std::decay_t<AfterCaptureFunction>,
            std::decay_t<ShutdownFunction>,
            std::decay_t<DuringCaptureFunction>>;
        return FunctionalActor<Context, Ops, ExecutionPolicy>(
            context,
            Ops{
                std::forward<ModelInitFunction>(model_init),
                std::forward<BeforeCaptureFunction>(before_capture),
                std::forward<AfterCaptureFunction>(after_capture),
                std::forward<ShutdownFunction>(shutdown),
                std::forward<DuringCaptureFunction>(during_capture)});
    }
}
