import sys, re
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

new = open("board_BOOT.bin", "rb").read()
old = open("S:/work/WCIS/board_extract/boot_files/BOOT.bin", "rb").read()
bit = open("S:/work/WCIS/board_extract/boot_files/ai7030_top.bit", "rb").read()
print("sizes: new=%d factory=%d ai7030_top.bit=%d" % (len(new), len(old), len(bit)))

n = min(len(new), len(old))
first = next((i for i in range(n) if new[i] != old[i]), None)
print("first diff offset: %s" % (hex(first) if first is not None else "none"))
if first is not None:
    seg_new = new[first:first + 48]
    seg_old = old[first:first + 48]
    print("new @diff : " + seg_new.hex())
    print("fac @diff : " + seg_old.hex())

def runs(data, lo, hi, minlen=5):
    return [m.group().decode("ascii", "replace") for m in
            re.finditer(rb"[\x20-\x7e]{%d,}" % bytes(str(minlen), "ascii"), data[lo:hi])]

for tag, d in (("new", new), ("factory", old)):
    print("\n===== %s header strings (0..0x4000) =====" % tag)
    seen = []
    for s in runs(d, 0, 0x4000, 5):
        if s not in seen:
            seen.append(s)
    print(" | ".join(seen[:60]))

# does either contain the standalone ai7030_top.bit payload?
for probe in (bit[len(bit)//4:len(bit)//4+256], bit[:256], bit[-256:]):
    print("\nprobe len=256 -> in new: %s  in factory: %s" % (new.find(probe) != -1, old.find(probe) != -1))

# where do the two files start to diverge from each other in block terms
if first is not None:
    diff_blocks = sum(1 for i in range(0, n, 4096) if new[i:i+4096] != old[i:i+4096])
    print("\n4KB blocks differing: %d of %d" % (diff_blocks, n // 4096))
