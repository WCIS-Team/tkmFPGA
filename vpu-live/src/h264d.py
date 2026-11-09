#!/usr/bin/env python3
# Board-side HLS packager for the VPU H.264 pump.
#
# Reads the pump's Annex-B segment files (segN.h264 + segN.info + state) from SRC,
# remuxes each one to MPEG-TS with the board ffmpeg, keeps a rolling
# window of KEEP segments and writes a hand-made index.m3u8 into WWW.
# PTS across segments are made continuous with -output_ts_offset so OBS
# does not re-sync on every segment join.
#
# fps comes from the pump's own state file, not from an env copy, so the
# playlist duration cannot disagree with what the encoder was told.
#
# Lifecycle: the launcher drops a "done" sentinel into SRC when the worker
# exits. On seeing it the packager drains any remaining segments, writes a
# final playlist carrying #EXT-X-ENDLIST, and exits on its own -- so the last
# segment is never lost to a mid-remux SIGTERM (the old behaviour).
#
# usage (on board):
#   H264_SRC=/dev/shm/wcis-vpu-h264-<session> H264_WWW=.../www \
#     setsid python3 h264d.py > /tmp/h264d.log 2>&1 < /dev/null &
import os
import re
import subprocess
import sys
import time


def now():
    return int(time.time())


def read_info(path, fallback_frames):
    try:
        with open(path) as f:
            m = re.search(r"frames=(\d+)", f.read())
        if m:
            return int(m.group(1))
    except Exception:
        pass
    return fallback_frames


def read_fps(path, fallback_fps):
    try:
        with open(path) as f:
            m = re.search(r"fps=(\d+)", f.read())
        if m and int(m.group(1)) > 0:
            return int(m.group(1))
    except Exception:
        pass
    return fallback_fps


def safe_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return -1


def safe_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def write_playlist(www, window, seq0, target, discont, endlist):
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        "#EXT-X-TARGETDURATION:%d" % target,
        "#EXT-X-MEDIA-SEQUENCE:%d" % seq0,
    ]
    for seq, dur in window:
        if seq in discont:
            lines.append("#EXT-X-DISCONTINUITY")
        lines.append("#EXTINF:%.3f," % dur)
        lines.append("seg%d.ts" % seq)
    if endlist:
        lines.append("#EXT-X-ENDLIST")
    tmp = os.path.join(www, "index.m3u8.part")
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, os.path.join(www, "index.m3u8"))


def main():
    src = os.environ.get("H264_SRC", "/dev/shm/h264")
    www = os.environ.get("H264_WWW", "/dev/shm/h264www")
    done_file = os.path.join(src, "done")
    fps = read_fps(os.path.join(src, "state"), int(os.environ.get("H264_FPS", "30")))
    keep = int(os.environ.get("H264_KEEP", "6"))
    pend_max = max(8, keep * 2)
    os.makedirs(www, exist_ok=True)

    print("packager src=%s www=%s fps=%d keep=%d pid=%d unix=%d" % (src, www, fps, keep, os.getpid(), now()), flush=True)

    window = []          # list[(seq, dur)] currently advertised
    discont = set()      # seqs that need a #EXT-X-DISCONTINUITY marker before them
    total_dur = 0.0
    done_thru = -1
    prev_consumed = -1
    target = 0           # EXT-X-TARGETDURATION, latched monotonically (RFC 8216: MUST NOT change)
    fails = 0

    while True:
        finishing = os.path.exists(done_file)
        state = os.path.join(src, "state")
        if os.path.exists(state):
            fps = read_fps(state, fps)
        segs = []
        try:
            for name in os.listdir(src):
                m = re.match(r"seg(\d+)\.h264$", name)
                if m:
                    segs.append(int(m.group(1)))
        except Exception as e:
            print("listdir %s: %r" % (src, e), flush=True)
            time.sleep(0.5)
            continue
        segs.sort()

        if len(segs) > pend_max:
            drop = segs[: len(segs) - pend_max]
            for s in drop:
                for ext in (".h264", ".info"):
                    safe_remove(os.path.join(src, "seg%d%s" % (s, ext)))
            print("overflow: dropped %d oldest raw segs" % len(drop), flush=True)
            segs = segs[len(segs) - pend_max:]

        fresh = [s for s in segs if s > done_thru]
        if len(fresh) > 3:
            skip = fresh[:-3]
            for s in skip:
                for ext in (".h264", ".info"):
                    safe_remove(os.path.join(src, "seg%d%s" % (s, ext)))
            print("lagging: skipped %d segs" % len(skip), flush=True)
            fresh = fresh[-3:]

        for s in fresh:
            raw = os.path.join(src, "seg%d.h264" % s)
            info = os.path.join(src, "seg%d.info" % s)
            raw_size = safe_size(raw)
            if raw_size < 0:
                # Segment vanished between listdir and here (writer prune race); treat as consumed.
                prev_consumed = s
                done_thru = s
                continue
            if raw_size < 64:
                prev_consumed = s
                done_thru = s
                continue
            frames = read_info(info, 1)
            dur = float(frames) / float(fps)
            out = os.path.join(www, "seg%d.ts" % s)
            cmd = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "h264", "-framerate", str(fps), "-i", raw,
                "-c", "copy", "-output_ts_offset", "%.3f" % total_dur,
                "-mpegts_copyts", "0", "-f", "mpegts", out,
            ]
            t0 = time.time()
            try:
                r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
            except subprocess.TimeoutExpired:
                print("seg%d ffmpeg timeout" % s, flush=True)
                r = None
            if r is None or r.returncode != 0 or not os.path.exists(out) or safe_size(out) < 64:
                fails += 1
                print("seg%d remux FAILED rc=%s err=%s" % (
                    s, getattr(r, "returncode", None),
                    (r.stderr.decode("utf-8", "replace")[:200] if r and r.stderr else "")), flush=True)
                # Drop the bad file but keep PTS aligned with the encoder timeline: the
                # next segment's source PTS continues from this one, so count its duration
                # even though we discard the media. A gap follows, so flag a discontinuity.
                safe_remove(out)
                safe_remove(raw)
                safe_remove(info)
                total_dur += dur
                prev_consumed = s
                done_thru = s
                continue
            spent = time.time() - t0
            safe_remove(raw)
            safe_remove(info)
            if s != prev_consumed + 1:
                discont.add(s)
            window.append((s, dur))
            total_dur += dur
            while len(window) > keep:
                old, _ = window.pop(0)
                discont.discard(old)
                safe_remove(os.path.join(www, "seg%d.ts" % old))
            d_max = max((d for _, d in window), default=0.0)
            if d_max > 0:
                candidate = int(d_max) + 1
                if candidate > target:
                    target = candidate
            write_playlist(www, window, window[0][0], target, discont, finishing)
            prev_consumed = s
            done_thru = s
            fails = 0
            if s % 30 == 0:
                print("seg%d dur=%.3f remux_ms=%d window=%d ts_bytes=%d cum_s=%.1f" % (
                    s, dur, int(spent * 1000), len(window), safe_size(out), total_dur), flush=True)

        if finishing:
            # Drain complete: publish a final playlist (with #EXT-X-ENDLIST) and exit.
            write_playlist(www, window, window[0][0] if window else 0, target, discont, True)
            print("packager done: %d segments published, total_dur=%.1f s" % (len(window), total_dur), flush=True)
            return 0

        if fails and fails % 20 == 0:
            print("consecutive remux failures=%d" % fails, flush=True)
        time.sleep(0.05)


if __name__ == "__main__":
    sys.exit(main())
