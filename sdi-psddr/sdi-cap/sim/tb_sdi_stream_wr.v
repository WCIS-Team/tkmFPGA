//============================================================================
// tb_sdi_stream_wr -- 像素链（打包 -> 异步 FIFO -> AXI 写帧器）联合回归
//
// 被测的是三级串联，和顶层 sdi_cap_top 里的接法完全一致：
//     sdi_px_pack   (px_clk 域)  4 像素拼 1 拍 64 bit + 帧标记
//     sdi_px_afifo  (跨域)       格雷码指针双时钟 FIFO
//     sdi_stream_wr (ax_clk 域)  AXI4 主机 -> HP2 从设备模型
//
// 回答四个问题：
//   1. 64 bit HP2 主机在 100 MHz 上够不够 1080p30 的 124.4 MB/s
//   2. AXI 协议 / WDATA 内容 / 环形回绕 有没有错
//   3. 判空握手（idle / inflight）语义对不对：停流之后多久算真排空，
//      排空之后还会不会冒出新拍
//   4. 在途事务没排空就复位会怎样（厂商 2026-10-12 文档里 L4 那个坑），
//      复位之后 PL 侧能不能自己干净地重新起来
//
// 参数（工作目录下的 bench.txt，一行一个 "键 值"）：
//   AW_LAT  N   AWVALID 起来之后 N 拍才给 AWREADY（默认 1）
//   W_LAT   N   WREADY 每 N 拍才拉一次（默认 1 = 恒 ready）
//   B_LAT   N   收到 WLAST 之后 N 拍才回 BRESP（默认 12）
//   CYCLES  N   测多久（默认 100000 拍 @100 MHz = 1 ms）
//   RING_BYTES N 环形缓冲字节数，0 = 不环绕
//   PX_DUTY N   像素占空比：>=100 = 每拍都有像素（最坏情况）；
//               N = 每 N 拍来一个像素（不会丢字，用来查跨拍连续性）
//   PX_MHZ  N   像素时钟（74 = 真实 HD-SDI；200 = 失锁后 clk200 兜底，
//               即"接收器没锁也照写"那条路，速率 400 MB/s）
//   RST_MID N   1 = 在测量窗口中途故意复位 16 拍（测复位后的自恢复）
//
// 检查项：
//   AXI 协议：AW 载荷在握手前不许变；WVALID 不许在握手前撤；
//             实发拍数必须等于 AWLEN+1；AWSIZE/AWBURST/地址对齐必须对
//   数据内容：一拍之内 4 个像素必须连续；不丢字时跨拍也要连续
//   环回绕：每拍地址 +8，且始终落在 [base, base+RING_BYTES)
//   帧标记：frame_cnt 的每一次自增都必须对应一个带标记的拍，
//           且 frame_start_addr 必须等于那一拍的地址
//   判空：停流后 idle 必须拉高、inflight 归零、FIFO 排空，
//         之后 200 拍内不许再出现新拍
//
// 踩过的坑（保留提醒）：
//   - B 模型的"收到 WLAST 后倒计时 B_LAT 拍"必须用移位管线给每个 WLAST
//     独立排队。第一版用 if/else 让新 WLAST 重置倒计时 = 从设备同时只能
//     跟踪一个写事务，连发突发时 BRESP 永远不来，测出来的是模型的假象。
//   - 参数不能走 +testplusarg：Windows 上 xsim.bat 转发参数会在 "=" 处劈开。
//============================================================================
`timescale 1ns / 1ps

`ifndef MAX_OUT_VAL
  `define MAX_OUT_VAL 8
`endif

module tb_sdi_stream_wr;

    localparam integer MAX_OUT = `MAX_OUT_VAL;
    localparam integer AX_HZ   = 100_000_000;     // clk_100m

    //--------------------------------------------------------------------------
    // 参数
    //--------------------------------------------------------------------------
    integer AW_LAT, W_LAT, B_LAT, N_CYCLES, RING_BYTES, PX_DUTY, PX_MHZ, RST_MID;
    integer pfd, code, pval;
    reg [8*32:1] pkey;
    real    px_period;
    reg     params_ready = 1'b0;

    localparam [63:0] BASE_ADDR = 64'h0000_0000_1000_0000;

    initial begin
        AW_LAT = 1; W_LAT = 1; B_LAT = 12; N_CYCLES = 100000;
        RING_BYTES = 0; PX_DUTY = 100; PX_MHZ = 74; RST_MID = 0;
        pfd = $fopen("bench.txt", "r");
        if (pfd != 0) begin
            code = $fscanf(pfd, "%s %d", pkey, pval);
            while (code == 2) begin
                if      (pkey == "AW_LAT")     AW_LAT     = pval;
                else if (pkey == "W_LAT")      W_LAT      = pval;
                else if (pkey == "B_LAT")      B_LAT      = pval;
                else if (pkey == "CYCLES")     N_CYCLES   = pval;
                else if (pkey == "RING_BYTES") RING_BYTES = pval;
                else if (pkey == "PX_DUTY")    PX_DUTY    = pval;
                else if (pkey == "PX_MHZ")     PX_MHZ     = pval;
                else if (pkey == "RST_MID")    RST_MID    = pval;
                code = $fscanf(pfd, "%s %d", pkey, pval);
            end
            $fclose(pfd);
        end
        px_period = 1.0e9 / (PX_MHZ * 1.0e6);
        params_ready = 1'b1;
    end

    //--------------------------------------------------------------------------
    // 两个时钟：像素域（74.25 或 200 MHz）和 AXI 域（100 MHz）
    //--------------------------------------------------------------------------
    reg px_clk = 1'b0;
    reg ax_clk = 1'b0;

    initial begin
        wait (params_ready);
        forever #(px_period / 2.0) px_clk = ~px_clk;
    end
    always #(5.0) ax_clk = ~ax_clk;              // 100 MHz

    reg rst_n = 1'b0;
    integer gcyc = 0;                            // AXI 域自由运行计数
    always @(posedge ax_clk) gcyc <= gcyc + 1;

    //--------------------------------------------------------------------------
    // 像素源：连续 +1 的 16 bit 序列（最坏情况：全是活跃像素）
    //--------------------------------------------------------------------------
    reg [15:0] px_data = 16'h0102;
    reg        frame_start = 1'b0;
    reg        px_en = 1'b0;
    integer    fs_cnt = 0;

    // PX_DUTY >= 100 -> 每拍都给像素（写不动时打包器会丢字，这才是真实的最坏情况）
    // PX_DUTY = N    -> 每 N 拍给一个像素，FIFO 不会满，不丢字
    wire px_valid_src = rst_n && px_en &&
                        ((PX_DUTY >= 100) ? 1'b1 : ((gcyc % PX_DUTY) == 0));

    always @(posedge px_clk) begin
        if (!rst_n) begin
            px_data <= 16'h0102;
            fs_cnt  <= 0;
            frame_start <= 1'b0;
        end else begin
            // 像素计数器只在真的送出像素时 +1，所以 WDATA 序列永远是
            // 连续 +1，跨拍连续性检查才有意义
            if (px_valid_src) px_data <= px_data + 16'h0001;
            frame_start <= 1'b0;
            if (fs_cnt == 0) begin
                frame_start <= 1'b1;
                fs_cnt      <= 1080;             // 每 1080 个像素一个"帧"
            end else begin
                fs_cnt <= fs_cnt - 1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 被测三级链
    //--------------------------------------------------------------------------
    wire [64:0] px_word, px_rdata;
    wire        px_wen, px_wfull;
    wire        px_ren, px_rempty;
    wire [10:0] px_rcount;
    wire [31:0] drop_lo;
    reg         cfg_rearm = 1'b0;

    wire [31:0] awaddr;  wire awvalid, awready;
    wire [5:0]  awid;    wire [3:0]  awlen;
    wire [2:0]  awsize;  wire [1:0]  awburst;
    wire        awlock;  wire [3:0]  awcache; wire [2:0] awprot; wire [3:0] awqos;
    wire        wvalid, wready;  wire [63:0] wdata;
    wire [7:0]  wstrb;   wire wlast;  wire [5:0] wid;
    wire        bvalid, bready;  wire [1:0]  bresp; wire [5:0] bid;

    wire        busy, starving, idle;
    wire [31:0] frame_cnt, frame_start_addr, wr_addr_lo, beats_written, err_stat;
    wire [5:0]  inflight;

    //--------------------------------------------------------------------------
    // px_overflow：与顶层同构（sdi_cap_top.v: px_overflow_cam -> sdi_cap_cdc -> 写帧器）
    //   "FIFO 满丢过字" 是**粘滞电平**，跨到写帧器时钟域后才进 err_stat[0]。
    //   这里用两级同步器做同一件事，并做双向核对：
    //       像素域看见丢字（drop_seen）  =>  写帧器必须把 err_stat[0] 置起来（err0_seen）
    //   2026-10-15 之前这里是硬接的 1'b0，等于**这条报错通路从来没被验过**。
    //--------------------------------------------------------------------------
    reg ovf_s1, ovf_s2;                  // ax 域两级同步
    reg drop_seen, err0_seen;            // 两个域各自的粘滞观察

    always @(posedge ax_clk or negedge rst_n) begin
        if (!rst_n) begin
            ovf_s1 <= 1'b0; ovf_s2 <= 1'b0; err0_seen <= 1'b0;
        end else begin
            ovf_s1    <= (drop_lo != 32'd0);
            ovf_s2    <= ovf_s1;
            err0_seen <= err0_seen | err_stat[0];
        end
    end

    always @(posedge px_clk or negedge rst_n) begin
        if (!rst_n) drop_seen <= 1'b0;
        else        drop_seen <= drop_seen | (drop_lo != 32'd0);
    end

    wire px_overflow_ax = ovf_s2;

    sdi_px_pack u_pack (
        .clk         (px_clk),
        .rst_n       (rst_n),
        .rearm       (1'b0),
        .px_valid    (px_valid_src),
        .px_data     (px_data),
        .frame_start (frame_start),
        .w_data      (px_word),
        .w_en        (px_wen),
        .w_full      (px_wfull),
        .drop_lo     (drop_lo)
    );

    sdi_px_afifo #(.W(65), .FD(10)) u_fifo (
        .wr_clk    (px_clk),
        .wr_rst_n  (rst_n),
        .wr_en     (px_wen),
        .wr_data   (px_word),
        .wr_full   (px_wfull),
        .rd_clk    (ax_clk),
        .rd_rst_n  (rst_n),
        .rd_en     (px_ren),
        .rd_data   (px_rdata),
        .rd_empty  (px_rempty),
        .rd_count  (px_rcount)
    );

    sdi_stream_wr #(.AW_ADDR_W(32), .ID_W(6), .FD(10), .MAX_OUT(MAX_OUT)) dut (
        .clk             (ax_clk),
        .rst_n           (rst_n),
        .px_rd_en        (px_ren),
        .px_rd_data      (px_rdata),
        .px_rd_empty     (px_rempty),
        .px_rd_count     (px_rcount),
        .cfg_rearm       (cfg_rearm),
        .cfg_buf_addr    (BASE_ADDR),
        .cfg_ring_bytes  (RING_BYTES[31:0]),
        .px_overflow     (px_overflow_ax),
        .m_axi_awaddr    (awaddr),
        .m_axi_awvalid   (awvalid),
        .m_axi_awready   (awready),
        .m_axi_awid      (awid),
        .m_axi_awlen     (awlen),
        .m_axi_awsize    (awsize),
        .m_axi_awburst   (awburst),
        .m_axi_awlock    (awlock),
        .m_axi_awcache   (awcache),
        .m_axi_awprot    (awprot),
        .m_axi_awqos     (awqos),
        .m_axi_wvalid    (wvalid),
        .m_axi_wready    (wready),
        .m_axi_wdata     (wdata),
        .m_axi_wstrb     (wstrb),
        .m_axi_wlast     (wlast),
        .m_axi_wid       (wid),
        .m_axi_bvalid    (bvalid),
        .m_axi_bready    (bready),
        .m_axi_bresp     (bresp),
        .busy            (busy),
        .frame_cnt       (frame_cnt),
        .frame_start_addr(frame_start_addr),
        .wr_addr_lo      (wr_addr_lo),
        .beats_written   (beats_written),
        .err_stat        (err_stat),
        .inflight        (inflight),
        .starving        (starving),
        .idle            (idle)
    );

    // 观测用层次引用（只看内部信号，不驱动它）。用在帧标记检查上：
    // 一拍 W 里带的标记必须与 frame_start_addr 的记录严格对齐。
    wire        dbg_wbeat     = dut.w_beat_i;
    wire        dbg_marker    = dut.px_rd_data[64];
    wire [31:0] dbg_beat_addr = dut.beat_addr;

    //--------------------------------------------------------------------------
    // AXI 从设备模型（当作 HP2 / PS DDR 控制器）
    //--------------------------------------------------------------------------
    // --- AWREADY：AWVALID 起来 N 拍之后 ---
    integer aw_lat_cnt = 0;
    always @(posedge ax_clk) begin
        if (!rst_n)                   aw_lat_cnt <= 0;
        else if (awvalid && !awready) aw_lat_cnt <= aw_lat_cnt + 1;
        else                          aw_lat_cnt <= 0;
    end
    assign awready = rst_n && awvalid && (aw_lat_cnt >= AW_LAT-1);

    // --- WREADY：每 W_LAT 拍拉一次（用自由运行计数，才是真占空比）---
    assign wready = rst_n && wvalid && ((W_LAT == 1) ? 1'b1 : ((gcyc % W_LAT) == 0));

    // --- BRESP：移位管线，每个 WLAST 独立排 B_LAT 级 ---
    reg [127:0] bpipe = 128'd0;
    always @(posedge ax_clk) begin
        if (!rst_n) bpipe <= 128'd0;
        else begin
            bpipe <= {bpipe[126:0], 1'b0};
            if (wvalid && wready && wlast) bpipe[0] <= 1'b1;
        end
    end
    assign bvalid = bpipe[B_LAT];
    assign bresp  = 2'b00;
    assign bid    = 6'd0;

    //--------------------------------------------------------------------------
    // AXI 协议检查
    //--------------------------------------------------------------------------
    integer errors = 0;
    reg     chk_ok = 1'b1;            // 复位窗口里把检查关掉
    reg     awv_d, awready_d, wready_d, wv_d, wlast_d;
    reg [31:0] awaddr_d;
    reg [5:0]  awid_d;
    reg [3:0]  awlen_d;
    reg [2:0]  awsize_d;
    reg [1:0]  awburst_d;

    integer expect_beats = 0;
    integer got_beats    = 0;
    reg     burst_open   = 1'b0;

    always @(posedge ax_clk) begin
        awv_d     <= awvalid && chk_ok;
        awready_d <= awready;
        wready_d  <= wready;
        awaddr_d  <= awaddr;
        awid_d    <= awid;
        awlen_d   <= awlen;
        awsize_d  <= awsize;
        awburst_d <= awburst;
        wv_d      <= wvalid && chk_ok;
        wlast_d   <= wlast;

        if (!rst_n || !chk_ok) begin
            expect_beats <= 0;
            got_beats    <= 0;
            burst_open   <= 1'b0;
        end else begin
            // 1. AWVALID 撤销前地址/长度/属性跳变
            if (awv_d && !awready && awvalid &&
                ((awaddr != awaddr_d) || (awlen != awlen_d) ||
                 (awid != awid_d) || (awsize != awsize_d) || (awburst != awburst_d))) begin
                if (errors < 8) $display("AXI-ERROR: AW payload changed while AWVALID held");
                errors <= errors + 1;
            end
            // 属性必须是我们写死的那套（HP2 上 8 byte 传输）
            if (awvalid && awready) begin
                if (awsize !== 3'd3) begin
                    if (errors < 8) $display("AXI-ERROR: AWSIZE=%0d, expected 3 (8 byte)", awsize);
                    errors <= errors + 1;
                end
                if (awburst !== 2'b01) begin
                    if (errors < 8) $display("AXI-ERROR: AWBURST=%b, expected INCR", awburst);
                    errors <= errors + 1;
                end
                if (awaddr[2:0] !== 3'd0) begin
                    if (errors < 8) $display("AXI-ERROR: AWADDR %08h not 8-byte aligned", awaddr);
                    errors <= errors + 1;
                end
                if (awlen > 4'd15) begin
                    if (errors < 8) $display("AXI-ERROR: AWLEN=%0d > 15 (HP2 AWLEN[3:0])", awlen);
                    errors <= errors + 1;
                end
                expect_beats <= awlen + 1;
                got_beats    <= 0;
                burst_open   <= 1'b1;
            end
            // 2. WVALID 握手前被撤销
            if (wv_d && !wready_d && !wvalid) begin
                if (errors < 8) $display("AXI-ERROR: WVALID dropped before WREADY handshake (gcyc=%0d)", gcyc);
                errors <= errors + 1;
            end
            // 3. 拍数必须等于 AWLEN+1
            if (wvalid && wready && burst_open) begin
                got_beats <= got_beats + 1;
                if (wlast) begin
                    burst_open <= 1'b0;
                    if ((got_beats + 1) != expect_beats) begin
                        if (errors < 8)
                            $display("AXI-ERROR: burst sent %0d beats, AWLEN said %0d",
                                     got_beats + 1, expect_beats);
                        errors <= errors + 1;
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 吞吐计数（AXI 域）
    //--------------------------------------------------------------------------
    integer nwl = 0, nburst = 0;
    integer nbeat = 0;
    always @(posedge ax_clk) if (rst_n && wvalid && wready) begin
        nbeat <= nbeat + 1;
        if (wlast) nwl <= nwl + 1;
    end
    always @(posedge ax_clk) if (rst_n && awvalid && awready) nburst <= nburst + 1;

    reg [63:0] bytes = 0;
    always @(posedge ax_clk) if (rst_n && wvalid && wready) bytes <= bytes + 64'd8;

    //--------------------------------------------------------------------------
    // 数据内容检查
    //--------------------------------------------------------------------------
    // 协议检查只看握手，不看数据。FIFO 读指针错、RAMB 读垃圾、字节序写反，
    // 这三类的表现全是"握手正常、数据错"。这里补内容检查：
    //   拍内：4 个 16 bit 像素必须连续（任何 PX_DUTY 下都成立）
    //   跨拍：低 16 位 = 上一拍的高 16 位 + 1（只在 PX_DUTY < 100、
    //         即不丢字时才成立；满速时会丢字，序列本来就会跳）
    integer    data_errs  = 0;
    integer    data_beats = 0;
    reg        have_prev  = 1'b0;
    reg [15:0] prev_hi    = 16'h0000;

    always @(posedge ax_clk) begin
        if (rst_n && wvalid && wready) begin
            data_beats <= data_beats + 1;
            if (wdata[31:16] !== (wdata[15:0]        + 16'd1) ||
                wdata[47:32] !== (wdata[31:16]       + 16'd1) ||
                wdata[63:48] !== (wdata[47:32]       + 16'd1)) begin
                if (data_errs < 8)
                    $display("DATA-ERROR: beat not consecutive: %h", wdata);
                data_errs <= data_errs + 1;
            end
            if ((PX_DUTY < 100) && have_prev &&
                (wdata[15:0] !== (prev_hi + 16'd1))) begin
                if (data_errs < 8)
                    $display("DATA-ERROR: stream discontinuity: prev_hi=%h lo=%h",
                             prev_hi, wdata[15:0]);
                data_errs <= data_errs + 1;
            end
            prev_hi   <= wdata[63:48];
            have_prev <= 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // 环形缓冲边界检查
    //--------------------------------------------------------------------------
    integer ring_errs = 0;
    reg [31:0] chk_addr = BASE_ADDR[31:0];
    always @(posedge ax_clk) begin
        if (!rst_n) begin
            ring_errs <= 0;
            chk_addr  <= BASE_ADDR[31:0];
        end else begin
            // 地址以 AW 握手为准，不能用自由运行的影子计数
            if (awvalid && awready) chk_addr <= awaddr;
            else if (wvalid && wready && burst_open) begin
                if (RING_BYTES != 0 &&
                    ((chk_addr < BASE_ADDR[31:0]) ||
                     (chk_addr >= BASE_ADDR[31:0] + RING_BYTES))) begin
                    if (ring_errs < 8)
                        $display("RING-ERROR: beat writes at 0x%08h, outside [0x%08h, +%0d)",
                                 chk_addr, BASE_ADDR[31:0], RING_BYTES);
                    ring_errs <= ring_errs + 1;
                end
                chk_addr <= chk_addr + 32'd8;    // 64 bit = 8 byte/拍
            end
        end
    end

    //--------------------------------------------------------------------------
    // 帧标记检查：带标记的那一拍，地址必须被记进 frame_start_addr
    //--------------------------------------------------------------------------
    integer    mark_errs  = 0;
    integer    n_marker   = 0;
    reg        chk_fsa_en = 1'b0;
    reg [31:0] chk_fsa_val = 32'd0;

    always @(posedge ax_clk) begin
        if (!rst_n) begin
            chk_fsa_en <= 1'b0;
            n_marker   <= 0;
            mark_errs  <= 0;
        end else if (dbg_wbeat && dbg_marker) begin   // 这一拍正在被写进 WDATA
            n_marker   <= n_marker + 1;
            chk_fsa_en <= 1'b1;
            chk_fsa_val<= dbg_beat_addr;
        end else begin
            if (chk_fsa_en && (frame_start_addr !== chk_fsa_val)) begin
                if (mark_errs < 8)
                    $display("MARK-ERROR: frame_start_addr=%08h, expected=%08h",
                             frame_start_addr, chk_fsa_val);
                mark_errs <= mark_errs + 1;
            end
            chk_fsa_en <= 1'b0;
        end
    end

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer  i, idle_wait, beat_at_idle;
    reg [63:0] b0, b1;
    integer  ncyc;
    real     t_ns, mbps, need_mbps, beat_rate;
    integer  drops_lo;

    initial begin
        // 等参数读完再放时钟（px_period 是变量，动态延时）
        wait (params_ready);

        repeat (16) @(posedge ax_clk);
        rst_n = 1'b1;
        px_en = 1'b1;
        repeat (4000) @(posedge ax_clk);        // 越过复位、填满 FIFO，丢弃前段

        // ---- 测量窗口 ----
        bytes = 0;
        b0 = bytes;
        nbeat = 0; nburst = 0; nwl = 0;
        for (i = 0; i < N_CYCLES; i = i + 1) begin
            @(posedge ax_clk);
            // 中途复位测试：故意在事务没排空时复位，看 PL 能不能自己起来
            if (RST_MID && (i == N_CYCLES/2)) begin
                chk_ok <= 1'b0;
                rst_n  <= 1'b0;
                repeat (16) @(posedge ax_clk);
                rst_n  <= 1'b1;
                repeat (4)  @(posedge ax_clk);
                chk_ok <= 1'b1;
            end
        end
        b1 = bytes;
        ncyc = N_CYCLES;

        t_ns      = ncyc * 10.0;                 // AXI 域 100 MHz
        mbps      = ((b1 - b0) / (t_ns * 1.0e-9)) / 1.0e6;
        need_mbps = 1920.0*1080.0*30.0*2.0/1.0e6;
        beat_rate = (nbeat * 1.0) / (ncyc * 1.0);

        // ---- 判空测试：停像素，等 idle ----
        px_en     = 1'b0;
        idle_wait = 0;
        while (!idle && (idle_wait < 20000)) begin
            @(posedge ax_clk);
            idle_wait = idle_wait + 1;
        end
        beat_at_idle = nbeat;
        repeat (200) @(posedge ax_clk);          // 排空之后不许再有新拍

        drops_lo = drop_lo;

        $display("================================================================");
        $display(" MAX_OUT=%0d AW_LAT=%0d W_LAT=%0d B_LAT=%0d PX_DUTY=%0d PX_MHZ=%0d RST_MID=%0d",
                 MAX_OUT, AW_LAT, W_LAT, B_LAT, PX_DUTY, PX_MHZ, RST_MID);
        $display(" 64-bit HP2 master @100 MHz, ceiling 800 MB/s");
        $display(" window  %0d cycles (%.3f ms)  bytes=%0d", ncyc, t_ns/1.0e6, b1-b0);
        $display(" throughput = %8.2f MB/s  (%6.1f%% of the %.1f MB/s needed for 1080p30)",
                 mbps, 100.0*mbps/need_mbps, need_mbps);
        $display(" beat rate  = %6.3f beats/cycle (1.000 = 800 MB/s)", beat_rate);
        $display(" beats=%0d wlast=%0d aw=%0d beats_written=%0d inflight=%0d",
                 nbeat, nwl, nburst, beats_written, inflight);
        $display(" frame_cnt=%0d marker_beats=%0d frame_start_addr=%08h",
                 frame_cnt, n_marker, frame_start_addr);
        $display(" dropped_words=%0d err_stat=0x%08x", drops_lo, err_stat);
        $display(" CHECK data=%s marker=%s frames=%s axi=%s ring=%s drain=%s quiet=%s ovf=%s",
                 (data_errs == 0) ? "PASS" : "FAIL",
                 (mark_errs == 0) ? "PASS" : "FAIL",
                 (frame_cnt == n_marker) ? "PASS" : "FAIL",
                 (errors    == 0) ? "PASS" : "FAIL",
                 (ring_errs == 0) ? "PASS" : "FAIL",
                 (idle && (inflight == 0) && (px_rcount < 11'd16)) ? "PASS" : "FAIL",
                 (nbeat == beat_at_idle)   ? "PASS" : "FAIL",
                 (!(drop_seen && !err0_seen)) ? "PASS" : "FAIL");
        $display(" (data beats=%0d errors=%0d | marker=%0d errors=%0d | axi errors=%0d | ring errors=%0d)",
                 data_beats, data_errs, n_marker, mark_errs, errors, ring_errs);
        $display(" (ovf: drop_seen=%b err0_seen=%b -- a drop must show up as err_stat[0])",
                 drop_seen, err0_seen);
        $display(" (drain: idle=%b inflight=%0d fifo_left=%0d words cycles_to_drain=%0d quiet beats=%0d)",
                 idle, inflight, px_rcount, idle_wait, nbeat - beat_at_idle);
        $display("================================================================");
        $finish;
    end

    initial begin
        #20_000_000;                     // 20 ms 上限
        $display("TIMEOUT");
        $finish;
    end

endmodule
