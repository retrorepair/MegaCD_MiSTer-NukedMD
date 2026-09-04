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
    vclk, dl = w[7] >> 32, w[7] & 0xFFFFFFFF
    fl = ' '.join(n for i, n in enumerate(FLAGS) if flags & (1 << i))
    print('seq=%d vs=%d dl_words=%d vclk=%d AS=%d expRD=%d expWR=%d late=%d nodtack=%d maxlat=%d(x9.3ns) prg=%d cart=%d lastVA=%06X lastVD=%04X [%s]'
          % (seq, vs, dl, vclk, as_, exp_rd, exp_wr, late, nodtack, max_lat, prg, cart, last_va, last_vd, fl))
    for i in range(16):
        a = w[8 + 2*i]; b = w[9 + 2*i]
        if a == 0 and b == 0: continue
        va = (a >> 41) & 0x7FFFFF; rw = (a >> 40) & 1; rom = (a >> 39) & 1; ras2 = (a >> 38) & 1; fdc = (a >> 37) & 1; cs = (a >> 36) & 1; dt = (a >> 35) & 1
        lat_dt = (a >> 23) & 0xFFF; vd = (a >> 7) & 0xFFFF; seen_busy = a & 1
        mcd_do = (b >> 48) & 0xFFFF; sdr = (b >> 32) & 0xFFFF; lat_busy = (b >> 20) & 0xFFF; cyc_len = (b >> 8) & 0xFFF
        reg = 'ROM ' if rom else 'RAS2' if ras2 else 'FDC ' if fdc else 'CE0 ' if cs else '--- '
        print('  #%2d %s %06X %s bus=%04X ga=%04X sdram=%04X  dtack@%3d busy_end@%3d len=%3d (x9.3ns) %s%s'
              % (i, 'RD' if rw else 'WR', va << 1, reg, vd, mcd_do, sdr, lat_dt if dt else -1, lat_busy if seen_busy else -1, cyc_len,
                 'mcd_dtack' if dt else 'NO-DTACK', '' if seen_busy else ' no-sdram'))

if __name__ == '__main__':
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    for i in range(count):
        show(read())
        if i + 1 < count: time.sleep(interval)
