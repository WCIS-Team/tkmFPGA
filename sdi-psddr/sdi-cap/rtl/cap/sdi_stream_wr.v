//============================================================================
// sdi_stream_wr -- 把 SDI 像素流连续搬进 PS DDR 的 AXI4 主机
//
// 设计原则：这是**纯数据搬运**，不是采集卡。
//   不看格式、不判制式、不按帧率门控、不丢帧、不等帧边界。
//   接收器没锁定也照写（写的是解串器输出的原始数据，可能是垃圾，
//   但"有垃圾"本身就是排障信息）。
//
// ★★ 2026-10-15 换口：GP0 -> S_AXI_HP2 ★★
//   原来挂在 M_AXI_GP0 上。查合成后的网表（sdi_cap.runs/synth_1/sdi_cap_top.dcp）：
//       u_wr/m_axi_awvalid … m_axi_wdata  全部 **不在网表里**（被优化掉）
//       net u_ps/wr_awvalid 上只有一个引脚： u_ps/u_ps7/M_AXI_GP0_AWVALID
//       M_AXI_GP0_AWVALID 方向 = OUT（PS 是主机），AWREADY/WREADY 被接地，
//       BVALID/BID 悬空，ACLK 没接
//   合成日志里那句话就是根因：
//       WARNING: [Synth 8-6104] Input port 'wr_awvalid' has an internal driver
//       [rtl/sdi_cap_ps.v:221]
//   M_AXI_GP0 是 **PS 出口（PS 当主机）**，PL 从设备挂在它下面；
//   PL 要写 PS DDR 必须走 **S_AXI_HP0..3**（PL 当主机，PS 当从设备）。
//   厂商自己的写帧器 frame_to_ps_largebuf 就是挂 S_AXI_HP2 的
//   （fpai_demo_fpga/rtl/ps_ai_peripheral.sv:857 起，
//     m00_axi_awid(S_AXI_HP2_AWID) / wdata(S_AXI_HP2_WDATA)）。本模块照抄这条通路。
//
// ★ HP2 的四条硬限制（全部读自 IP 生成的 HDL，不是从 AXI 规范推的）★
//   1. 数据宽 **64 bit**（S_AXI_HP2_WDATA[63:0]）—— 一拍 4 个像素
//   2. WSTRB **8 bit**，AWSIZE 固定 3'b011（8 byte）
//   3. AWLEN/ARLEN **4 bit** —— 单次突发最多 16 拍 = **128 字节**
//   4. AWID/BID/WID **6 bit**（GP 口是 12 bit）
//   属性值照抄厂商 aq_axi_master.v（已知能在这块板上写 DDR）：
//       AWID=0, AWLOCK=0, AWCACHE=4'b0011, AWPROT=3'b000, AWQOS=4'b1111
//
// ★ 为什么 AXI 侧在 clk_100m 而不在 cam_clk ★
//   像素时钟是恢复出来的，失锁时会切到 clk200 兜底 —— 频率会变。
//   AXI 接口上跑着在途事务时换时钟正是厂商文档里 L3/L4 那类挂死现场。
//   改成：像素域（cam_clk）打包 -> sdi_px_afifo（跨域）-> 本模块（clk_100m）。
//   clk_100m 来自 PS 的 FCLK0（常驻）。64 bit × 100 MHz = 800 MB/s 上限，
//   1080p30 只要 124.4 MB/s，余量 6.4×。
//
// ★ 为什么允许多个未完成突发（MAX_OUT = 8）★
//   AXI 突发的往返 = AW 握手 + W 拍数 + **BRESP 等待**。
//   只有 1 个未完成突发时吞吐 = 128 B / (2 + 16 + L_B)，被查不到的 BRESP
//   延迟 L_B 直接掐住；允许多个之后，实测 BRESP 延迟 1…127 拍吞吐恒定。
//
// ★ 突发长度必须锁存，也必须"攒够再发" ★
//   burst_len_q 在 S_IDLE 取一次，之后不再看实时水位：
//   否则 FIFO 排空会让 send_cnt < burst_len 提前为假，发出的 W 拍数少于
//   AWLEN+1，slave 会一直等 W —— AXI 端口挂死。
//
// ★ WVALID / WLAST 必须保持到握手为止 ★
//   这条踩过两次坑，都是 WREADY 恒为 1 时看不见、真 DDR 控制器一拉低就发作：
//   - WLAST 无条件清 -> 从设备永远看不到突发结束 -> 永不回 BRESP ->
//     inflight 涨满后死锁
//   - send_cnt 到齐就撤 WVALID -> 最后一拍被静默丢弃，少 8 字节、整帧错位
//
// ★ 判空握手（厂商 2026-10-12 客户说明里推荐的唯一办法）★
//   该芯片 PS 侧**不提供** S_AXI_HP*_RCOUNT/RACOUNT（文档原文），AXI 协议
//   本身也没有这种信号；而"只在 PL 侧复位/重配置"前必须先排空。
//   所以由 PL 自己报 idle = "inflight 归零 且 状态机回 S_IDLE"，
//   软件复位 PL 或重配置前必须等这一位为 1。
//
// 字节序：小端。64 bit 拍 n 里：4n+0 在 [15:0]，4n+1 在 [31:16]，
//         4n+2 在 [47:32]，4n+3 在 [63:48]。环形缓冲因此逐字节等于
//         SDI 口收到的内容（Y'CbCr 4:2:2 8 bit/分量）。
//============================================================================
`timescale 1ns / 1ps

module sdi_stream_wr #(
    parameter integer AW_ADDR_W = 32,
    parameter integer ID_W      = 6,      // HP2 的 AWID / BID / WID 都是 6 bit
    parameter integer FD        = 10,     // 与 sdi_px_afifo 一致：2^FD = 1024 拍
    parameter integer MAX_OUT   = 8       // 允许几个未完成突发
)(
    input  wire                  clk,        // AXI 侧时钟（clk_100m）
    input  wire                  rst_n,

    // ---- 像素 FIFO 读口（sdi_px_afifo 读侧，同一个时钟域）----
    output wire                  px_rd_en,
    input  wire [64:0]           px_rd_data,   // {帧标记, 4 像素}
    input  wire                  px_rd_empty,
    input  wire [FD:0]           px_rd_count,

    // ---- 配置（已同步到本域）----
    input  wire                  cfg_rearm,
    input  wire [63:0]           cfg_buf_addr,
    input  wire [31:0]           cfg_ring_bytes,   // 0 = 不环绕

    // ---- 像素侧溢出（cam_clk 域置的粘滞位，已两级同步过来）----
    input  wire                  px_overflow,

    // ---- AXI4 master（HP2，64 bit）----
    output wire [AW_ADDR_W-1:0]  m_axi_awaddr,
    output reg                   m_axi_awvalid,
    input  wire                  m_axi_awready,
    output reg  [ID_W-1:0]       m_axi_awid,
    output reg  [3:0]            m_axi_awlen,
    output reg  [2:0]            m_axi_awsize,
    output reg  [1:0]            m_axi_awburst,
    output reg                   m_axi_awlock,
    output reg  [3:0]            m_axi_awcache,
    output reg  [2:0]            m_axi_awprot,
    output reg  [3:0]            m_axi_awqos,
    output reg                   m_axi_wvalid,
    input  wire                  m_axi_wready,
    output reg  [63:0]           m_axi_wdata,
    output reg  [7:0]            m_axi_wstrb,
    output reg                   m_axi_wlast,
    output reg  [ID_W-1:0]       m_axi_wid,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    input  wire [1:0]            m_axi_bresp,

    // ---- 状态 ----
    output wire                  busy,             // 状态机不在空闲
    output reg  [31:0]           frame_cnt,
    output reg  [31:0]           frame_start_addr,
    output reg  [31:0]           wr_addr_lo,       // 下一个 beat 将写到哪
    output reg  [31:0]           beats_written,    // 累计 64 bit 拍数（8 字节/拍）
    output reg  [31:0]           err_stat,
    output reg  [5:0]            inflight,         // 未完成突发数
    output wire                  starving,
    output wire                  idle
);

    localparam [12:0] MAX_BURST   = 13'd16;        // AWLEN 4 bit -> 最多 16 拍
                                                   // 16 拍 × 8 字节 = 128 字节

    //--------------------------------------------------------------------------
    // 读侧取字：word_rdy = "手上这一拍可用"
    //   px_rd_en 后**下一拍** px_rd_data 才有新数据（FIFO 是同步读），
    //   所以这里跟一拍标志位，避免又把组合读当成异步读来用。
    //--------------------------------------------------------------------------
    reg  word_rdy;

    // 手上这一拍（= 上一拍的 px_rd_data）当前有效
    wire        w_beat_i;
    wire [FD:0] words_avail = px_rd_count + {{FD{1'b0}}, word_rdy};

    // 提前取数：手上没数据就取；正发一拍时同时取下一拍（无气泡）
    wire        px_rd_en_i  = !px_rd_empty && (!word_rdy || w_beat_i);

    always @(posedge clk) begin
        if (!rst_n || cfg_rearm) word_rdy <= 1'b0;
        else if (px_rd_en_i)     word_rdy <= 1'b1;
        else if (w_beat_i)       word_rdy <= 1'b0;
    end

    assign px_rd_en = px_rd_en_i;

    //--------------------------------------------------------------------------
    // 环形缓冲：递减计数器（到环尾还剩多少字节）
    //--------------------------------------------------------------------------
    wire [31:0] base_lo   = cfg_buf_addr[31:0];
    wire        ring_on   = (cfg_ring_bytes != 32'd0);

    reg  [31:0] ring_left;

    wire        wrap_now  = ring_on && (ring_left == 32'd0);
    wire [12:0] ring_cap  = (!ring_on)                ? MAX_BURST
                             : (cfg_ring_bytes >= 32'd128) ? MAX_BURST
                                                           : ((cfg_ring_bytes + 32'd7) >> 3);
    wire [12:0] burst_want = (!ring_on)              ? MAX_BURST
                              : (ring_left == 32'd0) ? ring_cap
                              : (ring_left >= 32'd128) ? ring_cap
                                                       : ((ring_left + 32'd7) >> 3);
    wire [31:0] addr_sel   = wrap_now ? base_lo : wr_addr_lo;

    //--------------------------------------------------------------------------
    // B 响应：常 ready，只记数。同一个 ID，响应按顺序回来。
    //--------------------------------------------------------------------------
    assign m_axi_bready = 1'b1;

    //--------------------------------------------------------------------------
    // 状态机：只管 AW 和 W。B 不参与，于是 W 一发完就能立刻发下一个 AW。
    //--------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_AW = 2'd1, S_W = 2'd2;

    reg  [1:0]  state;
    reg  [12:0] send_cnt;         // 已经放进 WDATA 寄存器的拍数
    reg  [12:0] burst_len_q;      // 锁存的突发长度（拍）
    reg  [31:0] addr_q;           // 锁存的本突发起始地址

    wire        aw_handshake = (state == S_AW) && m_axi_awready;
    wire        w_slot_free  = !m_axi_wvalid || m_axi_wready;
    wire        all_sent     = (send_cnt == burst_len_q);
    wire        burst_done   = (state == S_W) && w_slot_free && all_sent
                                && m_axi_wvalid && m_axi_wready;

    // 规定 w_beat_i：正在把手上的这一拍打进 WDATA
    assign      w_beat_i     = (state == S_W) && w_slot_free && !all_sent && word_rdy;

    // BUSY：状态机不在空闲（正在起突发 / 发 W 拍）。
    // IDLE：连在途事务都没有（下面）。两者一起给软件判空用。
    assign      busy         = (state != S_IDLE);

    // 攒够再发（words_avail 已经把手上那一拍算进去了）
    wire        fill_ok      = (words_avail >= {1'b0, burst_want});
    wire        start_ok     = (state == S_IDLE) && (burst_want != 13'd0)
                                && fill_ok && (inflight < MAX_OUT);

    // 发这一拍时它落在哪个地址（用于帧首地址，精确到 8 字节）
    wire [31:0] beat_addr    = addr_q + {{(32-13-3){1'b0}}, send_cnt, 3'b000};

    assign m_axi_awaddr = addr_q[AW_ADDR_W-1:0];
    assign starving     = px_rd_empty && !word_rdy;

    // 判空握手输出。软件复位 / 重配置 PL 之前必须等这一位为 1：
    // PS 侧看不到 HP 口上有没有在途事务（厂商 2026-10-12 客户说明原文），
    // 只可能靠 PL 报。inflight 归零 + 状态机回 S_IDLE 才算真排空。
    assign idle        = (inflight == 6'd0) && (state == S_IDLE);

    always @(posedge clk) begin
        if (!rst_n || cfg_rearm) begin
            state            <= S_IDLE;
            send_cnt         <= 13'd0;
            burst_len_q      <= 13'd0;
            addr_q           <= base_lo;
            wr_addr_lo       <= base_lo;
            beats_written    <= 32'd0;
            frame_cnt        <= 32'd0;
            frame_start_addr <= 32'd0;
            inflight         <= 6'd0;
            ring_left        <= cfg_ring_bytes;
            err_stat         <= 32'd0;
            m_axi_awvalid    <= 1'b0;
            m_axi_awid       <= {ID_W{1'b0}};
            m_axi_awlen      <= 4'd0;
            m_axi_awsize     <= 3'd3;          // 8 byte
            m_axi_awburst    <= 2'b01;         // INCR
            m_axi_awlock     <= 1'b0;
            m_axi_awcache    <= 4'b0011;       // 厂商 aq_axi_master 的取值
            m_axi_awprot     <= 3'b000;
            m_axi_awqos      <= 4'b1111;
            m_axi_wvalid     <= 1'b0;
            m_axi_wdata      <= 64'd0;
            m_axi_wstrb      <= 8'hFF;
            m_axi_wlast      <= 1'b0;
            m_axi_wid        <= {ID_W{1'b0}};
        end else begin
            // 未完成突发计数：AW 握手 +1，B 响应 -1
            case ({aw_handshake, m_axi_bvalid})
            2'b10:   inflight <= inflight + 6'd1;
            2'b01:   inflight <= inflight - 6'd1;
            default: ;
            endcase

            // 像素侧 FIFO 满（丢过整拍）/ AXI 写响应不是 OKAY：粘滞上报
            if (px_overflow)                   err_stat[0] <= 1'b1;
            if (m_axi_bvalid && (m_axi_bresp != 2'b00)) err_stat[1] <= 1'b1;

            // 环内余量：只在突发真正发完时更新，地址随之推进
            if (!ring_on) ring_left <= 32'd0;
            else if (burst_done) begin
                ring_left <= (ring_left >= {burst_len_q, 3'b000})
                             ? (ring_left - {burst_len_q, 3'b000}) : 32'd0;
            end

            case (state)
            //-------------------------------------------------------- IDLE
            S_IDLE: begin
                m_axi_wvalid  <= 1'b0;
                m_axi_awvalid <= 1'b0;
                m_axi_wlast   <= 1'b0;   // 上一突发的最后一拍已被收走
                if (start_ok) begin
                    burst_len_q <= burst_want;
                    addr_q      <= addr_sel;
                    send_cnt    <= 13'd0;
                    state       <= S_AW;
                end
            end

            //---------------------------------------------------------- AW
            S_AW: begin
                m_axi_awlen   <= burst_len_q[3:0] - 4'd1;
                m_axi_awvalid <= 1'b1;
                if (m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    state         <= S_W;
                end
            end

            //----------------------------------------------------------- W
            S_W: begin
                if (w_slot_free) begin
                    if (!all_sent) begin
                        if (word_rdy) begin
                            m_axi_wdata  <= px_rd_data[63:0];
                            m_axi_wstrb  <= 8'hFF;
                            m_axi_wlast  <= (send_cnt == burst_len_q - 13'd1);
                            m_axi_wvalid <= 1'b1;
                            // 帧标记随数据一起到：标记在哪一拍就记哪个地址，
                            // 与数据严格对齐，不靠单独的跨域脉冲。
                            if (px_rd_data[64]) begin
                                frame_cnt        <= frame_cnt + 32'd1;
                                frame_start_addr <= beat_addr;
                            end
                            send_cnt     <= send_cnt + 13'd1;
                        end
                        // word_rdy 为假（手上没数据）：保持 WVALID 和数据不变，
                        // 等像素流再灌进来。地址不推进，不会写错地方。
                    end else begin
                        // 走到这里必然是 m_axi_wvalid && m_axi_wready：
                        // 最后一拍已经被从设备收下，这一拍才算真正结束。
                        // ★ 不能只看 send_cnt 到齐就走 ★
                        m_axi_wvalid  <= 1'b0;
                        wr_addr_lo    <= addr_q + {6'd0, burst_len_q, 3'b000};
                        beats_written <= beats_written + burst_len_q;
                        state         <= S_IDLE;
                    end
                end
                // w_slot_free 为假：WVALID 与 WLAST 一起保持，等从设备收。
                // ★ 这里绝对不能清 WLAST ★
            end
            endcase
        end
    end

endmodule
