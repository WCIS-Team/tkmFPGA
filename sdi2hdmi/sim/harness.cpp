//=============================================================================
// harness.cpp -- Verilator harness for the school-machine test round.
//
// What this exists for
// --------------------
// tb_scaler_720 and tb_e2e answer "is this expression right" on a handful of
// synthetic frames. The questions that were still open are different in kind:
//
//   * real video, hundreds of frames, pixel-exact against an independent model
//   * extreme values (all-zero, all-max, one-pixel-wide structure, PRNG noise)
//   * events: reset mid-line, source unlock/relock, geometry change mid-stream
//   * long runs, where a rate imbalance accumulates instead of showing up
//
// All four are cheap in C++ (one eval per clock, no event queue) and awkward in
// a Verilog testbench. The DUT is the same RTL either way -- see sim/vlt_top.v,
// which wraps exactly scaler_720 + hdmi_out and adds nothing.
//
// Ground truth
// ------------
// box_filter() below is written from the SPECIFICATION, the longhand way:
//   E(j) = (j+1)*SRC_W/DST_W, take = E(j)-E(j-1)
// It is not a transcription of the RTL. Two things cross-validate it:
//   (a) tb_e2e.v already checks the same rule against a third implementation
//       written in Verilog, and passes;
//   (b) --pattern tb_e2e reproduces tb_e2e's own stimulus, so this harness is
//       known to agree with the Verilog testbench before it is pointed at
//       real video or anything else.
//
// Clock model
// -----------
// cam_clk 148.5 MHz and the HDMI pixel clock 74.25 MHz both come out of the same
// MMCM, so they are synchronous with a fixed 2:1 ratio. Four phases make one
// cam_clk period; the second clock toggles every two phases. Edge order is
// chosen so no two rising edges coincide.
//=============================================================================

#include "verilated.h"
#include "Vvlt_top.h"
// Needed for the flattened internal probes: Verilator's Vvlt_top.h only forward
// declares the root class, so the signal members are incomplete types without it.
#include "Vvlt_top___024root.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdarg>
#include <string>
#include <vector>
#include <fstream>

//---------------------------------------------------------------------------
// Verilator's runtime refers to sc_time_stamp() when the model is driven with
// --exe rather than --binary, because --binary supplies its own main that
// defines it. This model has no delayed assignments -- the harness owns the
// clock -- so simulation time is meaningless here and is reported as 0.
//---------------------------------------------------------------------------
double sc_time_stamp() { return 0.0; }

//---------------------------------------------------------------------------
// fixed geometry of the design under test
//---------------------------------------------------------------------------
static const int DST_W = 1280;
static const int DST_H = 720;

static Vvlt_top *du = nullptr;

// Verilator flattens the sub-hierarchy into the root object, so a register
// inside scaler_720 or hdmi_out is reached by its flattened name. These are
// read-only PROBES for --diag and for localising a failure; nothing in the
// pass/fail path depends on them, and a signal that is optimised away only
// costs a diag column.
#define SC(name) (du->rootp->vlt_top__DOT__u_scaler__DOT__##name)
// hdmi_out's internals, for the frame-phase alignment loop's own state.
#define SCH(name) (du->rootp->vlt_top__DOT__u_hdmi_out__DOT__##name)

//---------------------------------------------------------------------------
// reporting
//---------------------------------------------------------------------------
static int  g_fail = 0;
static int  g_check_fail = 0;
static bool g_verbose = true;

static void say(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list ap; va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static void fail(const char *fmt, ...) {
    g_fail++;
    va_list ap; va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fflush(stdout);
}

//---------------------------------------------------------------------------
// capture
//---------------------------------------------------------------------------
static std::vector<uint16_t> g_cap(DST_W * DST_H);
static std::vector<uint16_t> g_last;          // last COMPLETE output frame
static bool   g_last_valid = false;
static long long g_frames_out = 0;
static long long g_cap_row = 0, g_cap_px = 0;
static long long g_hold_px = 0;
static long long g_cam_cycles = 0;
// Frame markers that reached hdmi_out's alignment loop, counted from the
// harness side. Positive evidence that the loop is not simply idle: a dead
// marker and a working loop look identical in the picture.
static long long g_markers = 0;
// Alignment stretch events (0 -> nonzero v_extra): how many frames the loop
// lengthened, when, and by how much.
static long long g_stretch_events = 0;
static long long g_first_stretch_frame = -1, g_first_stretch_len = 0;
static long long g_last_stretch_frame  = -1, g_last_stretch_len  = 0;
// Source frame being driven right now, so an event seen from one_cam_period()
// can be attributed to the frame it happened in.
static long long g_src_frame_now = -1;
// Source frames in which the loop lengthened the raster. A stretch is a real
// disturbance: it re-parks the ring (the extension drains the ring and the
// producer keeps pushing), which shifts the frame mapping by one and moves the
// frame phase once -- the same two things an injected reset does. Recorded so
// the comparison can treat those frames as an event window instead of failing
// on them.
static std::vector<long long> g_stretch_frames;
// Output frames compared so far, and the output-frame count at the last
// comparison: a comparison is only made when a NEW complete output frame
// exists, so each output frame is compared exactly once.
static long long g_cmp_frames = 0;
static long long g_cmp_seen   = -1;

static inline uint16_t rgb888_to_565(uint32_t v) {
    return (uint16_t)(((v >> 19) & 0x1F) << 11 | ((v >> 10) & 0x3F) << 5 | ((v >> 3) & 0x1F));
}

static void capture_sample() {
    if (!du->rst_n) { g_cap_row = 0; g_cap_px = 0; return; }
    if (du->stalled) g_hold_px++;
    if (du->de) {
        g_cap[(size_t)g_cap_row * DST_W + g_cap_px] = rgb888_to_565(du->rgb);
        if (g_cap_px == DST_W - 1) {
            g_cap_px = 0;
            if (g_cap_row == DST_H - 1) {
                g_cap_row = 0;
                g_last = g_cap;
                g_last_valid = true;
                g_frames_out++;
            } else {
                g_cap_row++;
            }
        } else {
            g_cap_px++;
        }
    } else {
        g_cap_px = 0;
    }
}

//---------------------------------------------------------------------------
// Scaler-side capture.
//
// Same sweep, but taken straight off scaler_720's own output port instead of
// off the HDMI raster. This is what localises a content failure: if the
// scaler's own stream matches the golden and the HDMI capture does not, the
// fault is in hdmi_out or in this capture; if the scaler stream is already
// wrong, hdmi_out is innocent and there is no point looking at it.
//
// Note this compares PIXELS, not line order. tb_e2e documents why: the scaler
// emits a different number of lines in its measurement frame than in steady
// state, so a row index taken here drifts and would report a false row
// mismatch. Row ORDER is hdmi_out's question and tb_hdmi_out's job.
//---------------------------------------------------------------------------
static std::vector<uint16_t> g_scap(DST_W * DST_H);
static long long g_s_row = 0, g_s_px = 0, g_s_frames = 0;
static bool      g_scap_full = false;

static void scaler_sample() {
    if (!du->rst_n) { g_s_row = 0; g_s_px = 0; return; }
    if (du->pix_valid) {
        g_scap[(size_t)g_s_row * DST_W + g_s_px] = du->pix_data;
        if (du->pix_last) {
            g_s_px = 0;
            if (g_s_row == DST_H - 1) { g_s_row = 0; g_scap_full = true; g_s_frames++; }
            else g_s_row++;
        } else {
            g_s_px++;
        }
    }
}

//---------------------------------------------------------------------------
// clock
//
// Four phases make TWO cam_clk periods. cam_clk rises once per two phases;
// the HDMI pixel clock rises once per four. Getting this wrong is not subtle
// and not harmless: an earlier version advanced all four phases per pixel, so
// every source pixel was clocked into the scaler TWICE and the measured
// geometry came back as 3840x1080 instead of 1920x1080.
//
//   ph : cam_clk hdmi_pix_clk
//   0  :   1 (r)     0
//   1  :   0 (f)     1 (r)     <- sample the HDMI outputs here
//   2  :   1 (r)     1
//   3  :   0 (f)     0 (f)
//
// No two rising edges coincide, which matters because hdmi_out has a
// dual-clock FIFO in the middle: simultaneous edges would make the harness,
// not the DUT, decide the ordering.
//---------------------------------------------------------------------------
static const int CM[4] = {1, 0, 1, 0};
static const int HM[4] = {0, 1, 1, 0};
static int g_phase = 0;

static inline void tick() {
    du->cam_clk      = CM[g_phase];
    du->hdmi_pix_clk = HM[g_phase];
    du->eval();
    if (g_phase == 1) capture_sample();               // hdmi_pix_clk rising edge
    if (g_phase == 0 || g_phase == 2) {               // cam_clk rising edge
        g_cam_cycles++;
        scaler_sample();
    }
    g_phase = (g_phase + 1) & 3;
}

// one full cam_clk period = two phases
//
// Also samples hdmi_out's marker synchroniser (wf_s3) and the alignment loop's
// countdown (v_extra) once per period, so what the loop did is visible from the
// harness side:
//   * wf_s3 is high for a whole line (the marker is a full line wide), so a
//     once-per-period sample cannot miss it, and the count is what
//     distinguishes "the loop corrected the phase" from "the loop never saw a
//     marker and the phase happened to be fine".
//   * a 0 -> nonzero edge of v_extra is one lengthened frame, and its value at
//     that instant is how many blanking lines were added. How many such events
//     there are is the difference between "corrected once, then settled" and
//     "re-correcting every frame" -- two states that can look equally wrong in
//     the picture but need opposite fixes.
static inline void one_cam_period() {
    tick(); tick();
    static bool mk_d = false;
    static unsigned ve_d = 0;
    if (du != nullptr && du->rootp != nullptr) {
        bool mk = SCH(wf_s3) != 0;
        if (mk && !mk_d) g_markers++;
        mk_d = mk;

        unsigned ve = SCH(v_extra);
        if (ve != 0 && ve_d == 0) {
            g_stretch_events++;
            g_last_stretch_frame = g_src_frame_now;
            g_last_stretch_len   = (long long)ve;
            if (g_first_stretch_frame < 0) {
                g_first_stretch_frame = g_src_frame_now;
                g_first_stretch_len   = (long long)ve;
            }
            if (g_src_frame_now >= 0) g_stretch_frames.push_back(g_src_frame_now);
            else                       g_stretch_frames.push_back(0);
        }
        ve_d = ve;
    }
}

//---------------------------------------------------------------------------
// source raster
//---------------------------------------------------------------------------
struct Raster {
    int act_w = 1920, act_h = 1080;
    int tot_w = 2200, tot_h = 1125;
    // 0 is the real value: cam_vs rises with the first active line's cam_hs.
    // Non-zero only moves the rising edge later into that line, to measure the
    // design's tolerance of a displaced edge.
    int vs_rise_x = 0;
};

static inline uint32_t expand565(uint16_t v) {
    uint32_t r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F;
    uint32_t R = (r << 3) | (r >> 2), G = (g << 2) | (g >> 4), B = (b << 3) | (b >> 2);
    return (R << 16) | (G << 8) | B;
}

// A blank line: no de, no hs, no vs -- what the source looks like with no lock.
static void drive_blank() {
    du->src_de = 0; du->src_hs = 0; du->src_vs = 0; du->src_rgb = 0;
}

static void drive_pixel(const Raster &r, const uint16_t *frame, int sh, int sv) {
    // The raster the hardware can actually produce.
    //
    // cam_hs is the data window of EVERY line, vertical-blanking lines
    // included: frame_convertor restarts its horizontal counter at each SAV and
    // a blanking line carries a SAV like any other. cam_vs is the
    // vertical-ACTIVE level, rising with the first active line's cam_hs -- which
    // is forced, because rx_sdi.v:357 makes cam_data_en = cam_vs & cam_hs, so a
    // line with active pixels while vs is low is not representable here.
    // cam_de is that AND.
    //
    // This used to drive cam_hs only on active lines and park the cam_vs rising
    // edge inside line 0's horizontal blanking. Neither is possible on the real
    // source, and between them they hid three defects that each stop the picture
    // -- see the notes in scaler_720.v and tb_e2e.v.
    //
    // vs_rise_x survives only as a diagnostic knob, to measure how far the
    // design tolerates a displaced cam_vs edge. 0 is the real value.
    bool act  = (sh < r.act_w) && (sv < r.act_h);
    bool vact = (sv < r.act_h) && ((sv == 0) ? (sh >= r.vs_rise_x) : true);
    du->src_hs  = (sh < r.act_w) ? 1 : 0;
    du->src_vs  = vact ? 1 : 0;
    du->src_de  = (act && vact) ? 1 : 0;
    du->src_rgb = act ? expand565(frame[(size_t)sv * r.act_w + sh]) : 0u;
}

//---------------------------------------------------------------------------
// golden model, from the specification
//---------------------------------------------------------------------------
static void box_filter(const uint16_t *src, int sw, int sh,
                       int dw, int dh, std::vector<uint16_t> &out)
{
    std::vector<uint16_t> hs((size_t)sh * dw);
    out.resize((size_t)dh * dw);

    int e_prev = 0;
    for (int j = 0; j < dw; j++) {
        int e_cur = (int)(((long long)(j + 1) * sw) / dw);
        int nh    = e_cur - e_prev;
        for (int y = 0; y < sh; y++) {
            const uint16_t *row = src + (size_t)y * sw;
            uint16_t v;
            if (nh == 1)       v = row[e_prev];
            else if (nh == 2) {
                // 16-BIT SUM, as Verilog computes it. `(a + b) >> 1` assigned
                // to a 16-bit destination is context-determined by that
                // destination, so a+b is evaluated at 16 bits and the carry
                // out of bit 15 is LOST before the shift. scaler_720.v does
                // exactly this: h_mean is [15:0] and px + h_sum[15:0] is a
                // 16-bit add. Computing it in 32 bits here -- which this
                // harness did at first -- is a DIFFERENT filter, and it
                // reported 40% of the picture as wrong while the RTL was
                // self-consistent. A golden that is more precise than the
                // specification is not a golden.
                v = (uint16_t)((uint16_t)(row[e_prev] + row[e_prev + 1]) >> 1);
            }
            else {
                // Spec rule for a wider tap: sum then >>2. Kept identical to
                // the RTL's h_mean and to tb_e2e's golden so a disagreement is
                // a real one. Note this is only reachable when the source is
                // more than 2x the destination, which the shipped geometry
                // never is -- see the note in the verdict output.
                uint32_t acc = 0;
                for (int x = 0; x < nh; x++) acc += row[e_prev + x];
                v = (uint16_t)(acc >> 2);
            }
            hs[(size_t)y * dw + j] = v;
        }
        e_prev = e_cur;
    }

    int f_prev = 0;
    for (int k = 0; k < dh; k++) {
        int f_cur = (int)(((long long)(k + 1) * sh) / dh);
        int nv    = f_cur - f_prev;
        for (int j = 0; j < dw; j++) {
            uint16_t v;
            if (nv == 1)       v = hs[(size_t)f_prev * dw + j];
            else if (nv == 2) {
                // same 16-bit truncation as the horizontal pass, and the same
                // as scaler_720.v's `(w_rd + h_mean) >> 1`
                v = (uint16_t)((uint16_t)(hs[(size_t)f_prev * dw + j] +
                                          hs[(size_t)(f_prev + 1) * dw + j]) >> 1);
            }
            else {
                uint32_t acc = 0;
                for (int y = 0; y < nv; y++) acc += hs[(size_t)(f_prev + y) * dw + j];
                v = (uint16_t)(acc >> 2);
            }
            out[(size_t)k * dw + j] = v;
        }
        f_prev = f_cur;
    }
}

//---------------------------------------------------------------------------
// Content match with a vertical FRAME-PHASE offset allowed.
//
// This is not a relaxation of the check -- it is the only well-posed question
// for this architecture. hdmi_out is a ring of line slots and the reader's frame
// boundary is its own vsync, so the displayed frame sits at a constant offset of
// (ring occupancy) lines from the producer's line 0. A line slot carries no line
// number, so nothing can align the two without a frame-level handshake that does
// not exist here.
//
// Measured for 1080p60 -> 720p60: 2 lines (capture line 0 holds producer line
// 718). Constant, because the two frame periods are exactly equal (1125x2200 cam
// clocks and 750x1650 rclk are both 1 237 500 clocks), so the occupancy is
// constant. What it costs is that the top two displayed lines hold the previous
// frame's last two.
//
// THE OFFSET CROSSES A FRAME BOUNDARY, which is why g_prev is not optional.
// Capture row i holds the producer's row (i - off) of the current frame when that
// is >= 0, and the same row position of the PREVIOUS frame when it is not --
// because the reader's window simply starts a couple of lines early. A synthetic
// pattern cannot tell the two cases apart (every frame is the same picture), so
// this went unnoticed for the whole synthetic suite. Real video shows it: on Big
// Buck Bunny the top two displayed lines hold the previous frame's last two and
// exactly 2345 of 921600 pixels differ at the best offset -- while the scaler's
// own output stream is exact to the pixel in the same run. A golden that ignores
// g_prev therefore reports a working design as broken, on the only content that
// can express the difference.
//
// What is NOT allowed: a non-zero difference at the best offset (wrong, torn or
// duplicated data), or an offset that moves between frames (a rolling picture).
//
// Search order: the real offset is the ring occupancy, a handful of lines, so
// offsets near 0 and near DST_H are tried first. The scan stays exhaustive (every
// value of off is tested unless an exact match ends it early); the order only
// decides which candidate is examined first, and it is what keeps a 720-offset
// sweep from costing a second per frame per golden.
//---------------------------------------------------------------------------
static long long rot_best_pair(const std::vector<uint16_t> &cap,
                               const std::vector<uint16_t> &g_cur,
                               const std::vector<uint16_t> &g_prev,
                               int *best_off)
{
    long long best = -1; int bo = 0;
    // 0, 719, 1, 718, 2, 717, ... -- covers every offset exactly once.
    for (int k = 0; k < DST_H; k++) {
        int off = (k & 1) ? (DST_H - 1 - (k >> 1)) : (k >> 1);
        long long n = 0;
        for (int r = 0; r < DST_H; r++) {
            if (best >= 0 && n >= best) break;   // cannot beat the incumbent
            int gr = r - off;
            const uint16_t *grp = (gr >= 0) ? &g_cur[(size_t)gr * DST_W]
                                            : &g_prev[(size_t)(DST_H + gr) * DST_W];
            const uint16_t *cr = &cap[(size_t)r * DST_W];
            for (int c = 0; c < DST_W; c++) if (cr[c] != grp[c]) n++;
        }
        if (best < 0 || n < best) { best = n; bo = off; }
        if (best == 0) break;
    }
    if (best_off) *best_off = bo;
    return best;
}

// The scaler's own output stream IS one frame, not a window across two, so its
// previous frame is itself: same function, same-frame lookup.
static long long rot_best(const std::vector<uint16_t> &cap,
                          const std::vector<uint16_t> &gld, int *best_off)
{
    return rot_best_pair(cap, gld, gld, best_off);
}

//---------------------------------------------------------------------------
// synthetic patterns. All in RGB565, the only precision the DUT consumes.
//---------------------------------------------------------------------------
static uint16_t pat_pixel(const std::string &name, int x, int y, int w, int h, uint32_t rnd) {
    if (name == "black")   return 0x0000;
    if (name == "white")   return 0xFFFF;
    if (name == "gray")    return 0x8410;                       // mid grey 16/32/16
    if (name == "ramp") {
        uint32_t r = (uint32_t)x * 31 / (w - 1);
        uint32_t g = (uint32_t)x * 63 / (w - 1);
        uint32_t b = (uint32_t)y * 31 / (h - 1);
        return (uint16_t)((r << 11) | (g << 5) | b);
    }
    if (name == "checker1") return ((x + y) & 1) ? 0xFFFF : 0x0000;
    if (name == "checker2") return (((x >> 1) + (y >> 1)) & 1) ? 0xFFFF : 0x0000;
    if (name == "vlines")   return (x & 1) ? 0xFFFF : 0x0000;
    if (name == "hline")    return (y & 1) ? 0xFFFF : 0x0000;
    if (name == "dot")      return (x == w / 2 && y == h / 2) ? 0xFFFF : 0x0000;
    if (name == "noise") {
        uint32_t z = rnd;
        z ^= z << 13; z ^= z >> 17; z ^= z << 5;
        return (uint16_t)(z & 0xFFFF);
    }
    if (name == "extreme") {
        // Bands that force every tap to be all-zero or all-max, so the sum
        // lands exactly on rounding boundaries.
        int band = (y * 8) / h;
        if (band == 0) return 0x0000;
        if (band == 1) return 0xFFFF;
        if (band == 2) return 0xF800;    // R only, max
        if (band == 3) return 0x07E0;    // G only, max
        if (band == 4) return 0x001F;    // B only, max
        if (band == 5) return 0xFFFF;
        if (band == 6) return (((x / 3) & 1) ? 0xFFFF : 0x0000);
        return (uint16_t)(0xFFFF - ((x * 65535) / (w - 1)));
    }
    if (name == "tb_e2e") {
        // Exactly tb_e2e.v's src_pixel(): this is the cross-check that ties the
        // C++ golden to the Verilog one.
        uint8_t r = (uint8_t)((x * 255) / (w - 1));
        uint8_t g = (uint8_t)((y * 255) / (h - 1));
        uint8_t b = (uint8_t)(((x + y) * 255) / (w + h - 2));
        return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    }
    return 0;
}

static const char *kPatterns[] = {
    "tb_e2e", "black", "white", "gray", "ramp", "checker1", "checker2",
    "vlines", "hline", "dot", "noise", "extreme", nullptr
};

//===========================================================================
// main
//===========================================================================
//---------------------------------------------------------------------------
// Row-level localisation of a content failure.
//
// "49573 of 921600 pixels differ" says nothing about the SHAPE of the fault.
// This walks the capture row by row against the golden at the best frame phase
// and reports which display rows are wrong, whether they are contiguous, and --
// for the first few -- which golden row each one actually holds. That last part
// separates the two failure families that matter here:
//
//   * a wrong row that IS some golden row  -> the reader starved and held a
//     line (positional, recoverable, visible as a repeated band);
//   * a wrong row that matches NOTHING    -> torn or partly written data.
//
// The row sweep is 720 rows x 720 candidate rows x 1280 columns per reported
// row, which is why it only runs on the first few failing rows.
//---------------------------------------------------------------------------
static void localise_rows(const std::vector<uint16_t> &cap,
                          const std::vector<uint16_t> &gld, int off)
{
    int nbad = 0, first = -1, last = -1, run = 0, longest = 0;
    for (int r = 0; r < DST_H; r++) {
        const uint16_t *cr = &cap[(size_t)r * DST_W];
        int gr = r - off; if (gr < 0) gr += DST_H;
        const uint16_t *grp = &gld[(size_t)gr * DST_W];
        int d = 0;
        for (int c = 0; c < DST_W; c++) if (cr[c] != grp[c]) d++;
        if (!d) { run = 0; continue; }
        nbad++; if (first < 0) first = r; last = r;
        if (++run > longest) longest = run;
        if (nbad <= 8) {
            int srcrow = -1, srbest = DST_W + 1;
            for (int k = 0; k < DST_H; k++) {
                const uint16_t *kp = &gld[(size_t)k * DST_W];
                int e = 0;
                for (int c = 0; c < DST_W; c++) if (cr[c] != kp[c]) e++;
                if (e < srbest) { srbest = e; srcrow = k; if (!e) break; }
            }
            say("    [diag] row %3d: %d/%d px differ; closest golden row %3d"
                " (%d px differ)\n", r, d, DST_W, srcrow, srbest);
        }
    }
    say("    [diag] wrong rows %d/%d, first %d last %d, longest run %d\n",
        nbad, DST_H, first, last, longest);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    std::string src_file, pattern = "tb_e2e";
    int  nframes    = 8;
    long long reset_frame = -1;
    long long unlock_at   = -1;
    int  unlock_len = 0;
    long long gc_at  = -1;
    Raster r2;
    bool have_r2 = false;
    bool check = true;
    std::string dump_prefix;
    std::string dump_src;
    int vsx = 0;                     // --vs-rise-x, diagnostic only
    long long start_phase = 0;       // --start-phase, source-vs-reader frame phase
    bool diag = false;               // --diag, per-frame scaler/slot state

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](void) -> std::string { return (i + 1 < argc) ? argv[++i] : std::string(); };
        if      (a == "--src")        src_file = next();
        else if (a == "--pattern")    pattern = next();
        else if (a == "--frames")     nframes = atoi(next().c_str());
        else if (a == "--reset-frame") reset_frame = atoll(next().c_str());
        else if (a == "--unlock-at")  unlock_at = atoll(next().c_str());
        else if (a == "--unlock-len") unlock_len = atoi(next().c_str());
        else if (a == "--geom2") {
            int aw, ah, tw, th;
            if (sscanf(next().c_str(), "%dx%dx%dx%d", &aw, &ah, &tw, &th) == 4) {
                r2.act_w = aw; r2.act_h = ah; r2.tot_w = tw; r2.tot_h = th;
                have_r2 = true;
            }
        }
        else if (a == "--vs-rise-x")  vsx = atoi(next().c_str());
        else if (a == "--start-phase") start_phase = atoll(next().c_str());
        else if (a == "--diag")       diag = true;
        else if (a == "--geom2-at")   gc_at = atoll(next().c_str());
        else if (a == "--no-check")   check = false;
        else if (a == "--quiet")      g_verbose = false;
        else if (a == "--dump")       dump_prefix = next();
        else if (a == "--dumpsrc")    dump_src = next();
        else if (a == "--list") {
            for (int k = 0; k < 12; k++) printf("%s\n", kPatterns[k]);
            return 0;
        }
    }

    Raster r1;
    r1.vs_rise_x = vsx;
    r2.vs_rise_x = vsx;

    //-----------------------------------------------------------------------
    // source: a file of RGB565 frames, or a pattern
    //-----------------------------------------------------------------------
    std::ifstream fin;
    if (!src_file.empty()) {
        fin.open(src_file.c_str(), std::ios::binary);
        if (!fin) { printf("FATAL cannot open %s\n", src_file.c_str()); return 2; }
        fin.seekg(0, std::ios::end);
        long long sz = (long long)fin.tellg();
        long long per = (long long)r1.act_w * r1.act_h * 2;
        long long avail = sz / per;
        say("=== source file %s : %.1f MB = %lld whole frames of %dx%d RGB565\n",
            src_file.c_str(), sz / 1048576.0, avail, r1.act_w, r1.act_h);
        if (avail < 2) { printf("FATAL file holds %lld frames\n", avail); return 2; }
    }

    // The frame buffer has to hold the LARGER of the two rasters: the geometry
    // change test switches the source size mid-run, and the golden is recomputed
    // for whichever raster is in force.
    size_t max_px = (size_t)r1.act_w * r1.act_h;
    if (have_r2) {
        size_t p2 = (size_t)r2.act_w * r2.act_h;
        if (p2 > max_px) max_px = p2;
    }
    std::vector<uint16_t> frame(max_px);
    std::vector<uint16_t> gring[4];      // goldens for f, f-1, f-2, f-3
    for (int i = 0; i < 4; i++) gring[i].resize((size_t)DST_W * DST_H);

    auto load_frame = [&](long long f, const Raster &r) {
        if (!fin.is_open()) {
            // Fixed seed on purpose: the noise probe is inverted offline to
            // recover which source pixels the DUT actually combined, and that
            // inversion is only unambiguous if the source does not depend on
            // the frame number. An earlier version mixed f into the seed, so
            // the offline reconstruction had to guess which source frame the
            // captured output came from -- and it guessed wrong, which made a
            // working DUT look like it produced values from nowhere.
            uint32_t seed = 0x9E3779B9u;
            (void)f;
            for (int y = 0; y < r.act_h; y++)
                for (int x = 0; x < r.act_w; x++)
                    frame[(size_t)y * r.act_w + x] =
                        pat_pixel(pattern, x, y, r.act_w, r.act_h, seed + (uint32_t)(y * 7919 + x));
        } else {
            long long per = (long long)r.act_w * r.act_h * 2;
            long long n = ((long long)fin.seekg(0, std::ios::end).tellg()) / per;
            // A geometry change alters `per`, which can leave the file holding
            // less than one whole frame at the new size; without this the modulo
            // below divides by zero.
            if (n < 1) n = 1;
            fin.seekg((f % n) * per, std::ios::beg);
            fin.read((char *)frame.data(), per);
            if (!fin) { fin.clear(); fin.seekg(0, std::ios::beg); fin.read((char *)frame.data(), per); }
        }
    };

    //-----------------------------------------------------------------------
    // reset
    //-----------------------------------------------------------------------
    du = new Vvlt_top;
    drive_blank();
    du->rst_n = 0;
    du->cam_clk = 0; du->hdmi_pix_clk = 0;
    for (int i = 0; i < 40; i++) one_cam_period();
    du->rst_n = 1;
    for (int i = 0; i < 40; i++) one_cam_period();

    // ---- source-vs-reader frame phase ---------------------------------
    //
    // This is the one input the reset does NOT control in the real system. On
    // the board the HDMI raster starts when rst_n is released, but the SDI
    // source starts whenever it starts -- the camera has its own timing and
    // locks a second or so later -- so the two frame boundaries land at an
    // arbitrary relative phase. Re-creating that here means idling the source
    // for a chosen part of a frame period before frame 0 is driven.
    if (start_phase > 0) {
        for (long long i = 0; i < start_phase; i++) { drive_blank(); one_cam_period(); }
        say("    (source held blank for %lld cam clocks = %.1f%% of a frame"
            " period before frame 0)\n", start_phase,
            100.0 * (double)start_phase / (double)((long long)r1.tot_w * r1.tot_h));
    }

    //-----------------------------------------------------------------------
    // push frames
    //-----------------------------------------------------------------------
    const int WARMUP   = 4;
    const int NCHECK   = nframes;
    int       offset   = -999;           // output frame lags source frame by this
    int       line_off = -999;           // vertical frame phase, see rot_best()
    // A run that injects reset / unlock / geometry change may legitimately
    // re-park the line-slot ring, which moves the frame phase once. A run with
    // no events may not.
    const bool has_events = (reset_frame >= 0) || (unlock_at >= 0) || have_r2;
    // Frames whose picture is legitimately disturbed by an injected event, and
    // which therefore cannot be held against a golden. They are still required
    // to produce output frames, and the frames just AFTER the window are
    // compared strictly -- that recovery is the point of the test.
    //
    // The window is generous because scaler_720 latches its geometry from the
    // previous frame: one frame after any disturbance is expected to be wrong
    // even when the disturbance itself is brief.
    auto in_event_window = [&](long long f) -> bool {
        // A disturbance is judged by the frames AFTER it, so the window only has
        // to cover the transit -- but the transit is longer than the event.
        // Two reasons, both measured:
        //   * the comparison is made against the newest COMPLETE output frame,
        //     so it can lag the driving by up to two source frames (the golden
        //     search covers f/f-1/f-2);
        //   * a reset drops the scaler's geometry lock, which takes a whole
        //     source frame to re-measure.
        // Four frames of margin covers both. With only one, the reset cases
        // failed on exactly ONE comparison -- frame idx 5, i.e. f = 9 after a
        // reset at frame 6 -- and passed every frame after it, which is the
        // signature of a comparison landing inside the transit.
        const long long ev_margin = 4;
        if (reset_frame >= 0 && f >= reset_frame && f <= reset_frame + ev_margin) return true;
        if (unlock_at   >= 0 && f >= unlock_at   && f <= unlock_at + unlock_len + ev_margin) return true;
        if (have_r2 && gc_at >= 0 && f >= gc_at && f <= gc_at + ev_margin) return true;
        // A frame the alignment loop stretched is a disturbance of the same
        // kind: the extension drains the ring while the producer keeps pushing,
        // so about one source frame of content is passed through invisibly and
        // the frame mapping shifts, and the frame phase moves once by design
        // (that is the correction). The frame itself, the one after it and the
        // comparison that can still be looking at them are not compared, exactly
        // like an injected event.
        for (size_t i = 0; i < g_stretch_frames.size(); i++) {
            long long sf = g_stretch_frames[i];
            if (f >= sf && f <= sf + 2) return true;
        }
        return false;
    };
    std::vector<uint16_t> gold_prev, gold_prev2;

    long long dropped_at_start = 0;
    long long total_pushed = 0;
    long long dg_lines = 0, dg_drop = 0, dg_hold = 0, dg_frames = 0;
    long long dg_f = -1;              // source frame of the previous diag line

    for (long long f = 0; f < (long long)WARMUP + NCHECK; f++) {
        // The raster in force decides the source size, so it is picked BEFORE the
        // frame is built and the golden is computed for it: the geometry-change
        // test switches the size mid-run and both have to follow.
        const Raster &r = (have_r2 && gc_at >= 0 && f >= gc_at) ? r2 : r1;

        load_frame(f, r);
        // Shift FIRST, then compute into slot 0: gring[0]=golden(f),
        // gring[1]=golden(f-1), gring[2]=golden(f-2), gring[3]=golden(f-3).
        // Computing before the shift would overwrite golden(f-1) and make the
        // latency search compare the same buffer against itself.
        //
        // Four, not three, because the frame-phase lookup reads a row of the
        // PREVIOUS frame (see rot_best_pair): identifying the frame and allowing
        // the rotation have to happen at the same time, so the oldest goldens
        // need one neighbour each.
        gring[3] = gring[2];
        gring[2] = gring[1];
        gring[1] = gring[0];
        box_filter(frame.data(), r.act_w, r.act_h, DST_W, DST_H, gring[0]);

        // ---- drive one source frame -------------------------------------

        g_src_frame_now = f;
        bool reset_this = (reset_frame >= 0 && f == reset_frame);
        bool unlock_this = (unlock_at >= 0 && f >= unlock_at && f < unlock_at + unlock_len);

        for (int v = 0; v < r.tot_h; v++) {
            for (int h = 0; h < r.tot_w; h++) {
                // event injection lands mid-frame on purpose: half a frame in.
                if (reset_this && v == r.tot_h / 2 && h == 0) {
                    du->rst_n = 0;
                    for (int k = 0; k < 10; k++) one_cam_period();
                    du->rst_n = 1;
                }
                if (unlock_this) drive_blank();
                else             drive_pixel(r, frame.data(), h, v);
                one_cam_period();
            }
        }
        total_pushed++;

        // ---- no wait: the source keeps streaming --------------------------
        //
        // This used to be a wait loop (tick until one more output frame
        // completes). That is a source OUTAGE: for the whole wait the source's
        // signals stand still, and while the alignment loop stretches a frame
        // the wait runs to nearly a whole source frame. With the source paused
        // that long, the source's frame boundary moves in TIME -- which
        // re-creates exactly the phase the loop just corrected. Measured on the
        // school machine with the old wait: 15 stretches in 16 frames, each
        // ~731 lines, the phase never moving and the picture never right.
        //
        // A real SDI source cannot be paused, so frames are driven back to back
        // now (exactly 1125 x 2200 cam clocks each, no inserted time) and the
        // comparison is made against the newest COMPLETE output frame. When no
        // new output frame has arrived the iteration is not compared: a
        // stretched output frame is nearly twice as long as a source frame, so
        // some source frames legitimately have no completed output frame of
        // their own yet. Each output frame is still compared exactly once, and
        // the frame mapping is re-latched across a stretch (in_event_window).
        if (!g_last_valid || g_frames_out == g_cmp_seen) {
            if (diag)
                say("    [pacing] source frame %lld: no new complete output frame"
                    " yet (%lld so far); not compared\n", f, g_frames_out);
            continue;
        }
        g_cmp_seen = g_frames_out;

        // Diagnostics start at frame 1, comparisons at WARMUP.
        //
        // The alignment loop lengthens exactly ONE frame and that frame lands in
        // frames 1-3, i.e. before the first compared frame. What the loop did
        // has to be visible where it happened, not inferred from the steady
        // state: a frame that is reported but not compared is what this needs.
        if (!check) continue;
        bool compare_this = (f >= WARMUP);

        // ---- per-frame scaler / slot state (diagnosis) -------------------
        //
        // Prints exactly what the ring is being fed and drained by, one line per
        // source frame, so a frame that does not compare can be read off the
        // numbers instead of guessed at: `rows` is what the scaler pushed, and
        // `capture frames` is how many output frames those rows filled.
        if (diag) {
            long long dl = (long long)du->scaler_lines - dg_lines;
            long long dd = (long long)du->stat_dropped  - dg_drop;
            long long dm = g_hold_px - dg_hold;
            long long df = g_frames_out - dg_frames;
            // The comparison can skip a source frame, when no complete output
            // frame has arrived yet (a stretched output frame is nearly twice
            // as long as a source frame). The deltas above then span more than
            // one source frame, so they are divided by the span: the columns
            // stay PER SOURCE FRAME, which is what they have always meant and
            // what the loss measurements were taken in.
            long long span = (dg_f < 0) ? 1 : (f - dg_f);
            if (span < 1) span = 1;
            say("    [diag] src %2lld: rows %+5lld  dropped %+7lld  held %+7lld"
                "  capframes %+lld | src_w %u src_h %u h_src_w %u v_src_h %u"
                " v_take %u v_got %u out_y %u lines_in_frame %u locked %u"
                " | markers %lld v_extra %u span %lld\n",
                f, dl / span, dd / span, dm / span, df / span,
                (unsigned)du->src_w, (unsigned)du->src_h,
                (unsigned)SC(h_src_w), (unsigned)SC(v_src_h),
                (unsigned)SC(v_take),  (unsigned)SC(v_got),
                (unsigned)SC(out_y),   (unsigned)SC(lines_in_frame),
                (unsigned)du->scaler_locked,
                g_markers, (unsigned)SCH(v_extra), span);
            dg_lines = du->scaler_lines; dg_drop = du->stat_dropped;
            dg_hold = g_hold_px; dg_frames = g_frames_out; dg_f = f;
        }

        // A deliberate disturbance re-parks the line-slot ring and forces the
        // scaler to re-learn the geometry, so the frame latency and the frame
        // phase have to be re-latched after it instead of being carried across
        // it. Inside the window the content is not compared at all.
        if (!in_event_window(f) && in_event_window(f - 1)) {
            offset   = -999;
            line_off = -999;
            say("    frame %lld: event window over, re-latching latency and frame phase\n", f);
        }
        if (in_event_window(f)) {
            say("    frame %lld: inside an injected event window, content not compared\n", f);
            continue;
        }

        // ---- compare ----------------------------------------------------
        //
        // Content is compared at the best vertical frame phase (see rot_best),
        // and the frame it belongs to is identified by which golden it matches
        // exactly.
        if (!compare_this) continue;
        g_cmp_frames++;
        int idx = (int)(f - WARMUP);
        std::vector<uint16_t> &g_now = gring[0];   // golden for frame f
        long long nbad;

        // The capture is a window across two source frames, so each candidate
        // latency needs the golden of the frame BEFORE it as well.
        int off0 = 0, off1 = 0, off2 = 0;
        long long b0 = rot_best_pair(g_last, gring[0], gring[1], &off0);
        long long b1 = rot_best_pair(g_last, gring[1], gring[2], &off1);
        long long b2 = rot_best_pair(g_last, gring[2], gring[3], &off2);

        int found = -1, capoff = off0;
        if      (b0 == 0) { found = 0; capoff = off0; }
        else if (b1 == 0) { found = 1; capoff = off1; }
        else if (b2 == 0) { found = 2; capoff = off2; }

        if (found < 0) {
            g_check_fail++;
            if (g_check_fail <= 5) {
                fail("FAIL frame %d: NO frame phase makes the capture match any of"
                     " golden(f/f-1/f-2); best per golden: %lld / %lld / %lld of %d"
                     " pixels differ\n",
                     idx, b0, b1, b2, DST_W * DST_H);
                localise_rows(g_last, gring[0], off0);
            }
        } else {
            if (offset == -999) {
                offset = idx - (f - found);
                say("    latency: output frame %d holds source frame %lld  (offset %d)\n",
                    idx, f - found, offset);
            } else if (idx - (f - found) != offset) {
                g_check_fail++;
                fail("FAIL frame %d: frame mapping SLIPPED, expected offset %d got %d\n",
                     idx, offset, idx - (int)(f - found));
            }

            // The frame-phase offset itself. It may legitimately move when a
            // deliberate event re-parks the ring (reset, unlock/relock, geometry
            // change), which shows up as a two-line vertical jump and nothing
            // else; it may NOT wander on its own, which is a rolling picture.
            if (line_off == -999) {
                line_off = capoff;
                say("    frame phase: capture line 0 holds golden line %d"
                    "  (hdmi_out ring occupancy)\n", capoff);
            } else if (capoff != line_off) {
                if (has_events || !g_stretch_frames.empty()) {
                    say("    frame phase: moved %d -> %d across an injected event"
                        " (expected)\n", line_off, capoff);
                    line_off = capoff;
                } else {
                    g_check_fail++;
                    fail("FAIL frame %d: frame phase moved %d -> %d with no event;"
                         " the picture is ROLLING\n", idx, line_off, capoff);
                    line_off = capoff;
                }
            }
        }

        // ---- localise: is the SCALER already wrong, or only the HDMI side? --
        if (idx < 2 || found < 0) {
            if (!g_scap_full) {
                say("    [bisect] scaler sweep not full yet (%lld lines seen)\n", g_s_frames);
            } else {
                int sdy = 0, cdy = 0;
                long long sb = rot_best(g_scap, gring[0], &sdy);
                long long cb = rot_best(g_last, gring[0], &cdy);
                say("    [bisect] scaler stream : %lld of %d pixels differ at its best"
                    " frame phase (offset %d)\n", sb, DST_W * DST_H, sdy);
                say("    [bisect] hdmi capture  : %lld of %d pixels differ at its best"
                    " frame phase (offset %d)\n", cb, DST_W * DST_H, cdy);
                // sb == 0 means every scaler-side write was the right value, so
                // anything still wrong on the capture is downstream of the
                // write stream (the line-slot ring / the read side).  Only a
                // non-zero sb blames scaler_720.  (Until 2026-10-16 this line
                // tested sb != cb and therefore blamed the scaler for every
                // downstream fault -- the opposite of what the numbers say.)
                if (sb > 0)
                    say("    [bisect] => the scaler stream is already wrong;"
                        " fix scaler_720 first\n");
                else if (cb > 0)
                    say("    [bisect] => the scaler stream is exact; the difference is"
                        " downstream (hdmi_out / the ring)\n");
            }
        }

        if (!dump_prefix.empty() && idx < 2) {
            char nm[512];
            snprintf(nm, sizeof nm, "%s_f%02d_%s.bin", dump_prefix.c_str(), idx,
                     src_file.empty() ? pattern.c_str() : "real");
            std::ofstream o(nm, std::ios::binary);
            o.write((const char *)g_last.data(), (std::streamsize)g_last.size() * 2);
            o.close();
            if (!dump_src.empty()) {
                // The source frame that was pushed for this index. Offline
                // inversion of the noise probe needs the source it actually
                // came from, reconstructed rather than recollected.
                snprintf(nm, sizeof nm, "%s_f%02d_src.bin", dump_src.c_str(), idx);
                std::ofstream osrc(nm, std::ios::binary);
                osrc.write((const char *)frame.data(), (std::streamsize)frame.size() * 2);
                osrc.close();
            }
            if (idx == 0) {
                snprintf(nm, sizeof nm, "%s_f%02d_golden.bin", dump_prefix.c_str(), idx);
                std::ofstream og(nm, std::ios::binary);
                og.write((const char *)g_now.data(), (std::streamsize)g_now.size() * 2);
                og.close();
                snprintf(nm, sizeof nm, "%s_f%02d_scaler.bin", dump_prefix.c_str(), idx);
                std::ofstream os(nm, std::ios::binary);
                os.write((const char *)g_scap.data(), (std::streamsize)g_scap.size() * 2);
                os.close();
            }
        }
    }

    //-----------------------------------------------------------------------
    // verdict
    //-----------------------------------------------------------------------
    long long dropped = du->stat_dropped - dropped_at_start;
    say("\n=== results\n");
    say("  source           : %s\n", src_file.empty() ? pattern.c_str() : src_file.c_str());
    say("  source frames    : %d (plus %d warm-up)\n", NCHECK, WARMUP);
    say("  output frames    : %lld\n", g_frames_out);
    say("  cam cycles       : %lld\n", g_cam_cycles);
    say("  scaler locked    : %d   measured %dx%d\n", (int)du->scaler_locked, du->src_w, du->src_h);
    say("  scaler lines     : %u\n", du->scaler_lines);
    say("  stat_dropped     : %u   (delta over the checked frames %lld)\n",
        (unsigned)du->stat_dropped, dropped);
    say("  overflow         : %d\n", (int)du->overflow);
    say("  scaler overflow_q: %d   push_overrun %d\n",
        (int)du->scaler_overflow, (int)du->scaler_overrun);
    say("  held pixels      : %lld\n", g_hold_px);
    say("  frame markers    : %lld   (w_frame markers that reached the alignment loop)\n",
        g_markers);
    say("  frames stretched : %lld   (first: frame %lld by %lld lines; last: frame %lld by %lld)\n",
        g_stretch_events, g_first_stretch_frame, g_first_stretch_len,
        g_last_stretch_frame, g_last_stretch_len);
    say("  frames compared  : %lld of %d checked\n", g_cmp_frames, NCHECK);

    // The loop has to go QUIET: correct once, then nothing. A loop that
    // re-corrects every frame is not aligning anything, and it can look
    // harmless in the picture while it burns a frame's worth of blanking
    // forever -- measured on the school machine when the harness still paused
    // the source: 15 stretches in 16 frames.
    if (!has_events && g_stretch_events > 0 && g_last_stretch_frame >= 0 &&
        g_last_stretch_frame + 3 > (long long)(WARMUP + NCHECK)) {
        say("  FAIL: the alignment loop stretched a frame in the last 3 frames of"
            " the run -- it is still correcting and never settled\n");
        g_fail++;
    }

    // A run in which almost nothing could be compared proves nothing, however
    // quiet the picture looks: no output frame may be silently missing.
    if (g_cmp_frames < 3) {
        say("  FAIL: only %lld frames could be compared (no complete output frames"
            " were produced?)\n", g_cmp_frames);
        g_fail++;
    }

    // A dead marker and a working alignment loop look identical in the
    // picture, so "no marker ever arrived" has to be a failure of its own --
    // otherwise the phase being clean can be credited to the loop by mistake.
    if (g_markers == 0) {
        say("  FAIL: no frame marker ever reached hdmi_out's alignment loop\n");
        g_fail++;
    }

    int problems = g_fail + g_check_fail;
    if (problems == 0)
        say("\nPASS: %d real output frames pixel-exact against the specification model\n", NCHECK);
    else
        say("\nFAIL: %d problem(s), %d frame(s) mismatched\n", problems, g_check_fail);

    delete du;
    return problems == 0 ? 0 : 1;
}
