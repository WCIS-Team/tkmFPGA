"""LAN MJPEG viewer for the vendor SDI -> VPU JPEG worker. No hardware access."""
import argparse
import json
import os
from pathlib import Path
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PAGE = """<!doctype html><meta charset=utf-8><title>SDI 内网直播</title>
<style>body{background:#14181f;color:#eee;font:18px sans-serif;margin:2rem}img{max-width:100%;width:960px}p{min-height:2em}</style>
<h1>SDI 内网直播</h1><p id=s>正在检查输入…</p><img id=v hidden>
<script>const s=document.querySelector('#s'),v=document.querySelector('#v');
const names={waiting_for_capture:'等待启动采集',waiting_for_sdi_lock:'等待 SDI 输入锁定',input_format_mismatch:'输入格式不匹配',ready:'直播中',stopped:'采集已停止',starting:'正在启动',no_fresh_frame:'暂无新画面',boot_changed_requires_review:'重启后等待检查',capture_failed_requires_reboot:'采集异常，等待恢复',hardware_error_requires_review:'设备状态待检查'};
async function update(){try{const r=await fetch('/api/status',{cache:'no-store'}),q=await r.json();
s.textContent=(q.source==='vtc'?'板内测试图（不是摄像头）':'摄像头')+' · '+(names[q.state]||q.state)+(q.ready?' · '+q.width+'×'+q.height+' · '+q.encoded+' 帧':'');
if(q.ready){v.hidden=false;if(v.dataset.session!==q.session){v.dataset.session=q.session;v.src='/stream.mjpg?session='+encodeURIComponent(q.session)}}
else{v.hidden=true;v.removeAttribute('src');v.dataset.session=''}}catch(e){s.textContent='连接中断';v.hidden=true;v.removeAttribute('src');v.dataset.session=''}}
v.onerror=()=>{v.dataset.session='';v.hidden=true};setInterval(update,1000);update();</script>""".encode()


class Frames:
    def __init__(self, control, boot_file="/proc/sys/kernel/random/boot_id", frame_root="/dev/shm", process_alive=None):
        self.control = Path(control)
        self.boot_file = Path(boot_file)
        self.frame_root = Path(frame_root)
        self.process_alive = process_alive or (lambda pid: Path("/proc", str(pid), "stat").exists())

    def read(self):
        state = dict(ready=False, source="camera", state="waiting_for_capture")
        try:
            cfg = json.loads(self.control.read_text())
            state.update(source=cfg["source"], session=cfg["session"])
            boot = self.boot_file.read_text().strip()
            if boot != cfg["boot_id"]:
                state["state"] = "boot_changed_requires_review"
                return state, None
            directory = Path(cfg["directory"])
            if directory.parent != self.frame_root or not directory.name.startswith("wcis-"):
                raise ValueError("Unexpected frame directory")
            status = json.loads((directory / "status.json").read_text())
            state.update(status)
            if status["boot_id"] != boot or status["source"] != cfg["source"] or status["pid"] != cfg["pid"]:
                raise ValueError("Capture session mismatch")
            if status["state"] != "ready":
                return state, None
            if not self.process_alive(cfg["pid"]):
                raise ValueError("Capture process is gone")
            with (directory / "latest.frame").open("rb") as f:
                packet = f.read(5 * 1024 * 1024 + 16385)
            if len(packet) < 8:
                raise ValueError("Short frame")
            n = struct.unpack_from("<I", packet)[0]
            if not 0 < n <= 16384 or len(packet) > 5 * 1024 * 1024 + 16384:
                raise ValueError("Frame bounds")
            info = json.loads(packet[4:4+n])
            jpeg = packet[4+n:]
            if any(info[key] != cfg[key] for key in ("boot_id", "pid", "source")):
                raise ValueError("Frame belongs to a different session")
            age = time.monotonic() - info["captured_at"]
            if not 0 <= age <= 2:
                state.update(state="no_fresh_frame", frame_age_s=age)
                return state, None
            if not jpeg.startswith(b"\xff\xd8") or not jpeg.endswith(b"\xff\xd9"):
                raise ValueError("Incomplete JPEG")
            state.update(info, ready=True, session=cfg["session"], frame_age_s=age)
            return state, jpeg
        except (OSError, ValueError, KeyError, TypeError, struct.error):
            state.update(ready=False)
            if state["state"] == "ready":
                state["state"] = "no_valid_frame"
            return state, None


def handler(frames):
    slots = threading.BoundedSemaphore(4)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, code, content_type, data):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.connection.settimeout(5)
            url = urlsplit(self.path)
            path = url.path
            if path == "/":
                return self.send(200, "text/html; charset=utf-8", PAGE)
            if path == "/api/status":
                state, _ = frames.read()
                return self.send(200, "application/json", json.dumps(state).encode())
            if path == "/snapshot.jpg":
                state, jpeg = frames.read()
                return self.send(200, "image/jpeg", jpeg) if state["ready"] else self.send(503, "text/plain", b"No fresh frame")
            if path != "/stream.mjpg":
                return self.send(404, "text/plain", b"Not found")
            if not slots.acquire(blocking=False):
                return self.send(503, "text/plain", b"Viewer limit reached")
            try:
                state, jpeg = frames.read()
                if not state["ready"]:
                    return self.send(503, "text/plain", b"No fresh frame")
                requested = parse_qs(url.query).get("session", [state["session"]])[0]
                if requested != state["session"]:
                    return self.send(409, "text/plain", b"Capture session changed")
                session, last = state["session"], None
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                while True:
                    state, jpeg = frames.read()
                    if not state["ready"] or state["session"] != session:
                        break
                    if state["frame_id"] != last:
                        self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(jpeg)).encode() + b"\r\nX-Frame-Id: " + str(state["frame_id"]).encode() + b"\r\n\r\n" + jpeg + b"\r\n")
                        self.wfile.flush()
                        last = state["frame_id"]
                    time.sleep(.05)
                self.wfile.write(b"--frame--\r\n")
            except (OSError, BrokenPipeError):
                pass
            finally:
                slots.release()

    return Handler


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--host", default="192.168.1.113")
    parser.add_argument("--port", type=int, default=8092)
    args = parser.parse_args()
    ThreadingHTTPServer((args.host, args.port), handler(Frames(args.control))).serve_forever()
