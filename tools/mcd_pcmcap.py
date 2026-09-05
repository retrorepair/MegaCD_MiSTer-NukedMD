#!/usr/bin/env python3
# Dump the MegaCD test core's PCM output capture ring (runs on the MiSTer).
#   python3 mcd_pcmcap.py [out_prefix]
# Writes <prefix>_pcm.wav (RF5C164 output) and <prefix>_mix.wav (mixed core audio, input of
# audio_fix), both 16-bit stereo at 32552 Hz, and prints per-block level and pitch statistics.
import mmap, struct, sys, wave, math

REC  = 0x3E000000
RING = 0x3E010000
N    = 8192
RATE = 32552

def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else '/tmp/pcmcap'
    with open('/dev/mem', 'rb') as f:
        m = mmap.mmap(f.fileno(), 0x20000, mmap.MAP_SHARED, mmap.PROT_READ, offset=REC)
        rec = struct.unpack('<40Q', m[0:320])
        ring = m[0x10000:0x20000]
        m.close()
    if rec[0] != 0x4D43445F4E554B45:
        print('no telemetry record'); return
    ptr = rec[20] & 0x1FFF
    words = struct.unpack('<%dQ' % N, ring)
    words = words[ptr:] + words[:ptr]            # oldest first
    def s16(v):
        return v - 0x10000 if v & 0x8000 else v
    pcm_l = [s16((w >> 48) & 0xFFFF) for w in words]
    pcm_r = [s16((w >> 32) & 0xFFFF) for w in words]
    mix_l = [s16((w >> 16) & 0xFFFF) for w in words]
    mix_r = [s16(w & 0xFFFF) for w in words]
    for name, l, r in (('pcm', pcm_l, pcm_r), ('mix', mix_l, mix_r)):
        with wave.open('%s_%s.wav' % (prefix, name), 'wb') as wf:
            wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(RATE)
            wf.writeframes(b''.join(struct.pack('<hh', a, b) for a, b in zip(l, r)))
    print('capture: %d samples = %.2f s, ring pointer %d, files %s_pcm.wav %s_mix.wav' % (N, N / RATE, ptr, prefix, prefix))
    # per-block statistics on the PCM left channel: RMS and fundamental by autocorrelation
    B = 1024
    print(' block   t(ms)   rms_pcm  rms_mix  f0_pcm(Hz)  zero-crossings')
    for b in range(N // B):
        x = pcm_l[b*B:(b+1)*B]; y = mix_l[b*B:(b+1)*B]
        rms = math.sqrt(sum(v*v for v in x) / B); rmy = math.sqrt(sum(v*v for v in y) / B)
        zc = sum(1 for i in range(1, B) if (x[i-1] < 0) != (x[i] < 0))
        best, bestv = 0, 0.0
        if rms > 50:
            mean = sum(x) / B; xz = [v - mean for v in x]
            for lag in range(20, 400):
                c = sum(xz[i] * xz[i+lag] for i in range(0, B - lag, 2))
                if c > bestv: bestv, best = c, lag
        f0 = RATE / best if best else 0.0
        print(' %5d %7.1f %9.1f %8.1f %10.1f  %5d' % (b, b*B*1000.0/RATE, rms, rmy, f0, zc))

if __name__ == '__main__':
    main()
