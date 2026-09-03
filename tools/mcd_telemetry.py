#!/usr/bin/env python3
# Read the MegaCD test core's telemetry record from DDR3 (runs on the MiSTer).
#   python3 mcd_telemetry.py [interval_s] [count]
import mmap, struct, sys, time

BASE = 0x3E000000
FLAGS = ['exp_rom','exp_ras2','exp_fdc','md_reset','btn_reset','sys_reset','region0','region1',
         'rom_cart_mode','mcd_rst_n','led_r','led_g','rom_download','m68k_reset','m68k_halt','locked']

def read():
    with open('/dev/mem', 'rb') as f:
        m = mmap.mmap(f.fileno(), 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
        d = m.read(320)
        m.close()
    return struct.unpack('<40Q', d)

def show(w):
    if w[0] != 0x4D43445F4E554B45:
        print('no magic (%016x)' % w[0]); return
    seq = w[1] >> 32; flags = w[1] & 0xFFFF
    vs, as_ = w[2] >> 32, w[2] & 0xFFFFFFFF
    exp_rd, late = w[3] >> 32, w[3] & 0xFFFFFFFF
    nodtack, exp_wr = w[4] >> 32, w[4] & 0xFFFFFFFF
    last_va = (w[5] >> 32) & 0xFFFFFF; last_vd = (w[5] >> 16) & 0xFFFF; max_lat = w[5] & 0xFFFF
    prg, cart = w[6] >> 32, w[6] & 0xFFFFFFFF
    vclk, hs = w[7] >> 32, w[7] & 0xFFFFFFFF
    fl = ' '.join(n for i, n in enumerate(FLAGS) if flags & (1 << i))
    print('seq=%d vs=%d hs=%d vclk=%d AS=%d expRD=%d expWR=%d late=%d nodtack=%d maxlat=%d(x9.3ns) prg=%d cart=%d lastVA=%06X lastVD=%04X [%s]'
          % (seq, vs, hs, vclk, as_, exp_rd, exp_wr, late, nodtack, max_lat, prg, cart, last_va, last_vd, fl))
    for i in range(32):
        t = w[8+i]
        if t == 0: continue
        va = (t >> 41) & 0x7FFFFF; rw = (t >> 40) & 1; rom = (t >> 39) & 1; ras2 = (t >> 38) & 1; fdc = (t >> 37) & 1; cs = (t >> 36) & 1; dt = (t >> 35) & 1; lat = (t >> 23) & 0xFFF; vd = (t >> 7) & 0xFFFF
        print('  #%2d %s %06X %s data=%04X lat=%4d(x9.3ns) %s' % (i, 'RD' if rw else 'WR', va << 1, 'ROM ' if rom else 'RAS2' if ras2 else 'FDC ' if fdc else 'CE0 ' if cs else '--- ', vd, lat, 'mcd_dtack' if dt else 'NO-DTACK'))

if __name__ == '__main__':
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    for i in range(count):
        show(read())
        if i + 1 < count: time.sleep(interval)
