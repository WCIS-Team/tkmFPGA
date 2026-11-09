#!/usr/bin/env python3
"""Splice a Xilinx .bit into the bitstream slot of a BOOT.bin image.

The BOOT.bin stores the bitstream with every 32-bit word byte-reversed, so the
file starts with 66 55 99 AA instead of AA 99 55 66.  The slot is located from
the reference .bit (the design currently inside the image), never guessed.

usage: boot-splice.py NEW.bit BOOT_template.bin OUT.bin --ref OLD.bit
       boot-splice.py NEW.bit BOOT_template.bin OUT.bin --slot 0x2D9F0 --size 5979868
"""
import array
import hashlib
import re
import sys


def swap4(data):
    if len(data) % 4:
        raise SystemExit("refusing to byte-swap %d bytes (not a multiple of 4)" % len(data))
    a = array.array("I")
    a.frombytes(data)
    a.byteswap()
    return a.tobytes()


def payload_of(bit):
    s = bit.find(b"\xaa\x99\x55\x66")
    if s < 0:
        raise SystemExit("no AA 99 55 66 sync word")
    return s, bit[s:]


def main():
    args = sys.argv[1:]
    if len(args) < 4 or args[0] in ("-h", "--help"):
        raise SystemExit(__doc__)
    new_bit, tpl_path, out_path = args[0], args[1], args[2]
    ref_path = slot = size = None
    i = 3
    while i < len(args):
        if args[i] == "--ref":
            ref_path = args[i + 1]; i += 2
        elif args[i] == "--slot":
            slot = int(args[i + 1], 0); i += 2
        elif args[i] == "--size":
            size = int(args[i + 1], 0); i += 2
        else:
            raise SystemExit("unknown argument %r" % args[i])

    tpl = open(tpl_path, "rb").read()
    new_sync, new_pay = payload_of(open(new_bit, "rb").read())
    new_sw = swap4(new_pay)
    print("new bit   %s: sync@%d, payload %d B" % (new_bit, new_sync, len(new_pay)))

    if ref_path:
        ref = open(ref_path, "rb").read()
        ref_sync, ref_pay = payload_of(ref)
        ref_sw = swap4(ref_pay)
        if slot is None:
            hits = [m.start() for m in re.finditer(re.escape(b"\x66\x55\x99\xaa"), tpl)
                    if m.start() >= 0x1000]
            slot = tpl.find(ref_sw[:256])
            print("candidate slot positions (swapped sync >= 0x1000): %s" % hits)
            if slot < 0:
                raise SystemExit("reference payload head not present in template -- wrong pair?")
        if tpl[slot:slot + len(ref_sw)] != ref_sw:
            raise SystemExit("reference payload does not occupy [0x%X, +%d) byte-for-byte"
                             % (slot, len(ref_sw)))
        if size is not None and size != len(ref_sw):
            raise SystemExit("--size %d disagrees with reference payload %d" % (size, len(ref_sw)))
        size = len(ref_sw)
        print("reference %s: sync@%d, payload %d B -- verified resident at 0x%X"
              % (ref_path, ref_sync, size, slot))
    else:
        if slot is None or size is None:
            raise SystemExit("need --ref, or both --slot and --size")

    if slot + size > len(tpl):
        raise SystemExit("slot runs past the end of the image")
    if len(new_sw) != size:
        raise SystemExit("new payload %d B != slot %d B (slack after slot is what it is; "
                         "no resize here)" % (len(new_sw), size))

    out = tpl[:slot] + new_sw + tpl[slot + size:]
    assert len(out) == len(tpl)
    open(out_path, "wb").write(out)
    back = open(out_path, "rb").read()
    if back[:slot] != tpl[:slot] or back[slot + size:] != tpl[slot + size:] or back[slot:slot + size] != new_sw:
        raise SystemExit("VERIFY FAILED: output does not match the intended splice")

    print("wrote %s: %d B, md5 %s" % (out_path, len(out), hashlib.md5(out).hexdigest().upper()))
    print("template           : %d B, md5 %s" % (len(tpl), hashlib.md5(tpl).hexdigest().upper()))
    print("verify OK: bytes outside 0x%X..0x%X untouched, slot == swapped new payload"
          % (slot, slot + size))


if __name__ == "__main__":
    main()
