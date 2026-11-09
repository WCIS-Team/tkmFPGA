"""Board-side, exclusive launcher for the SDI/VPU worker; no automatic retries."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import signal
import uuid

# The worker's own profile table is the source of truth; this only sizes the packager's fallback.
FPS = {"jpeg": 5, "h264": 30}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source", choices=("camera", "vtc"), required=True)
    parser.add_argument("--frames", type=int, default=0)
    parser.add_argument("--codec", choices=("jpeg", "h264"), default="jpeg")
    parser.add_argument("--size", default="960x540")
    args = parser.parse_args()
    if not 0 <= args.frames <= 3600:
        raise ValueError("Invalid finite frame limit")
    root = args.root.resolve()
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    proof = json.loads((root / "boot-proof.json").read_text())
    assert proof["boot_id"] == boot
    assert proof["boot_files"]["BOOT.bin"] in (
        "0088581b738fdef741983d2dfd4dd52363d2d90fddc2fa4dafb30cfdb3b23fca",
        "f48397d08b1ccb1c950adafcebe5e36678154e73fa1d19792150aa5ddccd8ad1",
    )
    assert not Path("/download.bit").exists() and Path("/root/live.disabled").exists()
    receipt = json.loads((root / "build-receipt.json").read_text())
    executable = root / "wcis_sdi_vpu_live"
    assert hashlib.sha256(executable.read_bytes()).hexdigest() == receipt["binary_sha256"]
    marker = Path("/root/wcis-face/hardware-review-required.json")
    assert not marker.exists() or json.loads(marker.read_text()).get("boot_id") != boot
    assert subprocess.run(["systemctl", "is-active", "--quiet", "wcis-face-photo.service"]).returncode != 0
    cfg = json.loads(Path("/root/wcis-face/video-stream-current.json").read_text())
    with (Path(cfg["release"]) / "npu.lock").open("a") as lock, Path("/root/wcis-camera-preview/camera.lock").open("a") as camera:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(camera, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for process in Path("/proc").iterdir():
            if not process.name.isdigit():
                continue
            for fd in (process / "fd").glob("*"):
                try:
                    target = os.readlink(fd)
                except OSError:
                    continue
                if target == "/dev/video0":
                    raise RuntimeError("VPU is owned by PID " + process.name)
        session = uuid.uuid4().hex
        directory = Path("/dev/shm") / ("wcis-vpu-" + args.source + "-" + session)
        directory.mkdir()
        env = os.environ.copy()
        env["WCIS_NPU_LOCK_FD"] = str(lock.fileno())
        env["WCIS_CAMERA_LOCK_FD"] = str(camera.fileno())
        process = subprocess.Popen([str(executable), args.source, boot, str(directory), str(args.frames), args.codec, args.size], env=env, pass_fds=(lock.fileno(), camera.fileno()))
        packager = None
        if args.codec == "h264":
            packager_env = dict(env, H264_SRC=str(directory), H264_WWW=str(directory / "www"), H264_FPS=str(FPS["h264"]))
            packager = subprocess.Popen([sys.executable, str(root / "h264d.py")], env=packager_env)
        control = dict(source=args.source, session=session, boot_id=boot, pid=process.pid, directory=str(directory),
                       codec=args.codec, size=args.size, packager_pid=None if packager is None else packager.pid)
        temporary = root / "current.tmp"
        temporary.write_text(json.dumps(control))
        temporary.replace(root / "current.json")
        def stop(signum, _):
            if process.poll() is None:
                process.send_signal(signum)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            code = process.wait()
        finally:
            if packager is not None:
                # Let the packager drain any segments still on disk and write the
                # final playlist with #EXT-X-ENDLIST, instead of SIGTERM-ing it and
                # losing the tail segment (the old behaviour left the last segment
                # out of index.m3u8, so the live view silently froze on it).
                if args.codec == "h264":
                    try:
                        open(str(directory / "done"), "w").close()
                    except Exception:
                        pass
                if packager.poll() is None:
                    try:
                        packager.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        packager.terminate()
                        try:
                            packager.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            packager.kill()
        report = dict(control, exit_code=code, packager_exit=None if packager is None else packager.returncode)
        (root / (session + "-result.json")).write_text(json.dumps(report, indent=2))
        if code:
            marker.write_text(json.dumps(dict(boot_id=boot, reason="SDI/VPU capture failed; review or full reboot before SDK reuse", source=args.source, codec=args.codec)))
        raise SystemExit(code)


if __name__ == "__main__":
    main()
