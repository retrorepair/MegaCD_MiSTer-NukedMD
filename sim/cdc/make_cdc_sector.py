#!/usr/bin/env python3
# Generate a canonical Mode-1 CD sector (2352 bytes) and pack it as 1176 little-endian
# 16-bit words for the CDC CD_DI feed (word i = sector[2i] | sector[2i+1]<<8).
# Header bytes 12-15 = 00 02 00 01 and bytes 16.. = "SEGADISCSYSTEM  " so the CDC decode
# yields HEAD0..3 = 00 02 00 01 and the DMA-to-MAIN readback starts 00 02 00 01 'S' 'E' 'G' 'A'.
s = bytearray(2352)
s[0] = 0x00
for i in range(1,11): s[i] = 0xFF        # sync 00 FF*10 00
s[11] = 0x00
s[12:16] = bytes([0x00,0x02,0x00,0x01])   # header: min sec frame mode
tag = b"SEGADISCSYSTEM  "
s[16:16+len(tag)] = tag
for i in range(16+len(tag), 2352):        # deterministic fill
    s[i] = i & 0xFF
# pack little-endian words
with open("sim/cdc/sector_words.hex","w") as f:
    for i in range(0,2352,2):
        w = s[i] | (s[i+1] << 8)
        f.write("%04x\n" % w)
print("wrote sim/cdc/sector_words.hex (%d words)" % (2352//2))
print("first 10 bytes:", " ".join("%02x"%b for b in s[:10]))
print("header 12-19  :", " ".join("%02x"%b for b in s[12:20]))
print("word[6]=%04x word[8]=%04x (SE=4553)" % (s[12]|s[13]<<8, s[16]|s[17]<<8))
