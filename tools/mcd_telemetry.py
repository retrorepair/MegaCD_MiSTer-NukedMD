#!/usr/bin/env python3
# Read the MegaCD test core's telemetry record from DDR3 (runs on the MiSTer).
#   python3 mcd_telemetry.py [interval_s] [count]
import mmap, struct, sys, time

BASE = 0x3E000000
FLAGS = ['exp_rom','exp_ras2','exp_fdc','md_reset','btn_reset','sys_reset','region0','region1',
         'rom_cart_mode','mcd_rst_n','led_r','led_g','rom_download','m68k_reset','m68k_halt','locked']
REGIONS = ['PRG-RAM', 'WORD-RAM', 'REGS/PCM', 'PCM', 'BRAM']
CPU_CLK_NS = 80.0      # 12.5 MHz sub-CPU
TICK_NS = 9.3125       # 107.38 MHz telemetry clock

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
    ras2_ign, ras2_acc = w[4] >> 32, w[4] & 0xFFFFFFFF
    last_va = (w[5] >> 32) & 0xFFFFFF; last_vd = (w[5] >> 16) & 0xFFFF; max_lat = w[5] & 0xFFFF
    prg, cart = w[6] >> 32, w[6] & 0xFFFFFFFF
    vclk, dl = w[7] >> 32, w[7] & 0xFFFFFFFF
    fl = ' '.join(n for i, n in enumerate(FLAGS) if flags & (1 << i))
    print('seq=%d vs=%d dl_words=%d vclk=%d AS=%d expRD=%d ras2acc=%d late=%d ras2ign=%d maxlat=%d(x9.3ns) prg=%d cart=%d lastVA=%06X lastVD=%04X [%s]'
          % (seq, vs, dl, vclk, as_, exp_rd, ras2_acc, late, ras2_ign, max_lat, prg, cart, last_va, last_vd, fl))
    # sub-CPU bus statistics
    for r in range(5):
        a = w[8 + 2*r]; b = w[9 + 2*r]
        cnt = a >> 32; ssum = a & 0xFFFFFFFF
        mx = (b >> 48) & 0xFFFF; mn = (b >> 32) & 0xFFFF; long_ = b & 0xFFFFFFFF
        if cnt == 0: continue
        avg = ssum / cnt
        print('  sub %-8s n=%-9d AS->DTACK avg=%6.1fns (%4.2f clk) min=%5.1fns max=%6.1fns  >8clk=%d'
              % (REGIONS[r], cnt, avg * TICK_NS, avg * TICK_NS / CPU_CLK_NS, mn * TICK_NS, mx * TICK_NS, long_))
    smp_ce = w[18] >> 32; cef = w[18] & 0xFFFFFFFF
    pcm_wr = w[19] >> 32; pcm_seen = w[19] & 0xFFFFFFFF; pcm_late = w[20] >> 32
    print('  pcm sample_ce=%d ce_f=%d writes=%d seen_by_chip=%d late_fetch=%d' % (smp_ce, cef, pcm_wr, pcm_seen, pcm_late))
    fresh_seq = w[21] >> 32; cdd_send = (w[21] >> 16) & 0xFFFF; cdd_rec = w[21] & 0xFFFF; live = w[22] & 0xFF; ce_hi = w[23] >> 32; sub_last = ((w[22] >> 8) & 0x7FFFFF) << 1
    win_min = (w[22] >> 48) & 0xFFFF; win_last = (w[22] >> 32) & 0xFFFF; irq_max = (w[23] >> 16) & 0xFFFF; irq_last = w[23] & 0xFFFF
    print('  record: word21 seq=%d (%s) cdd cmds=%d stats=%d  sub last reg=%06X  live sp_ce=%d%d sp_late=%d%d sp_we=%d%d sp_cef=%d%d ce_high_clocks=%d'
          % (fresh_seq, 'fresh' if fresh_seq == seq else 'STALE', cdd_send, cdd_rec, sub_last,
             (live >> 7) & 1, (live >> 6) & 1, (live >> 5) & 1, (live >> 4) & 1, (live >> 3) & 1, (live >> 2) & 1, (live >> 1) & 1, live & 1, ce_hi))
    print('  int2: IFL2 write end -> sub write FF8026 last=%.2fus max=%.2fus | -> main read A12026 last=%.2fus min=%.2fus'
          % (irq_last * TICK_NS / 1000, irq_max * TICK_NS / 1000, win_last * TICK_NS / 1000, (0 if win_min == 0xFFFF else win_min) * TICK_NS / 1000))
    # sub-CPU bus address ring: 32 entries in words 24-39 (two per word), oldest first from the write pointer
    rp = (w[20] >> 13) & 0x1F
    ents = []
    for wi in range(24, 40):
        ents.append(w[wi] & 0xFFFFFFFF); ents.append(w[wi] >> 32)
    ents = ents[rp:] + ents[:rp]
    def region(a):
        if a < 0x80000: return 'P'
        if a < 0xE0000: return 'W'
        if 0xFE0000 <= a < 0xFF0000: return 'B'
        if 0xFF0000 <= a < 0xFF8000: return 'M'
        if a >= 0xFF8000: return 'R'
        return '?'
    print('  sub-CPU last 32 bus cycles, oldest first (r/W = read/write, P=PRG-RAM W=word RAM B=backup M=PCM R=register):')
    print('   ' + ' '.join('%s%s%06X' % ('r' if (e >> 23) & 1 else 'W', region((e & 0x7FFFFF) << 1), (e & 0x7FFFFF) << 1) for e in ents))

if __name__ == '__main__':
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    for i in range(count):
        show(read())
        if i + 1 < count: time.sleep(interval)
