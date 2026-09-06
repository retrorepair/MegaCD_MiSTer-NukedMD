; z80_prog.asm -- directed program of the z80 A/B equivalence bench (assembled by asm_z80.pl into
; z80_rom.hex, 8 KB, mapped at 0000-1FFF). It runs through every instruction family once, then a
; sequence of HALTs that the bench wakes with INT (IM 0 with an RST byte, IM 1, IM 2 through the
; uniform vector table at 1F00) and NMI, and finally writes the signature A5 to SIG. PHASE is
; written at every section so the bench can report how far the program got.
;
; Bench memory map: 0000-1FFF ROM, 2000-3FFF 8 KB RAM, 4000-7FFF peripheral region and 8000-FFFF
; 68000 window (both with bridge-style WAIT states), I/O ports 00-FF (stub port model).

BUF     EQU $2000        ; scratch
SRC     EQU $2100
DST     EQU $2200
VAR     EQU $2300
VAR16   EQU $2302
INTCNT  EQU $2304
NMICNT  EQU $2305
IOBUF   EQU $2310
SIG     EQU $3F00
PHASE   EQU $3F01
STACK   EQU $3FF0

        ORG $0000
reset:  DI
        JP main
        ORG $0008
rst08:  INC B
        RET
        ORG $0010
rst10:  INC C
        RET
        ORG $0018
rst18:  INC D
        RET
        ORG $0020
rst20:  INC E
        RET
        ORG $0028
rst28:  EX AF,AF'
        RET
        ORG $0030
rst30:  EXX
        RET
        ORG $0038
int38:  PUSH AF          ; IM 1 handler, and the IM 0 handler when the bench supplies RST 38h
        PUSH HL
        LD HL,INTCNT
        INC (HL)
        POP HL
        POP AF
        EI
        RETI
        ORG $0066
nmi66:  PUSH AF
        PUSH HL
        LD HL,NMICNT
        INC (HL)
        POP HL
        POP AF
        RETN

        ORG $0100
main:   LD SP,STACK
        LD A,1
        LD (PHASE),A
; ---------------------------------------------------------------- 8-bit loads
        LD A,$12
        LD B,A
        LD C,B
        LD D,C
        LD E,D
        LD H,E
        LD L,H
        LD A,L
        LD HL,BUF
        LD (HL),A
        LD B,(HL)
        INC HL
        LD (HL),$34
        LD C,(HL)
        LD D,$56
        LD E,$78
        LD (HL),D
        LD A,(HL)
        LD BC,BUF
        LD A,(BC)
        LD DE,BUF+1
        LD A,(DE)
        LD (BC),A
        LD (DE),A
        LD (VAR),A
        LD A,(VAR)
        LD I,A
        LD A,I
        LD R,A
        LD A,R
        LD IX,BUF
        LD IY,BUF+8
        LD (IX+2),A
        LD (IX+3),$9A
        LD B,(IX+2)
        LD (IY-1),B
        LD C,(IY-1)
        LD (IY+0),C
        LD H,(IX+3)
        LD (IX+4),H
        LD L,(IY+4)
        LD (IY+5),L
        LD A,(IX+4)
        LD (IX+5),A
        LD D,(IY+2)
        LD (IY+3),D
        LD E,(IX+6)
        LD (IX+7),E
; ---------------------------------------------------------------- 16-bit loads, stack
        LD A,2
        LD (PHASE),A
        LD BC,$1234
        LD DE,$5678
        LD HL,$9ABC
        LD IX,$DEF0
        LD IY,$1357
        LD (VAR16),HL
        LD HL,(VAR16)
        LD (VAR16),BC
        LD BC,(VAR16)
        LD (VAR16),DE
        LD DE,(VAR16)
        LD (VAR16),IX
        LD IX,(VAR16)
        LD (VAR16),IY
        LD IY,(VAR16)
        LD (VAR16),SP
        LD HL,(VAR16)
        LD SP,(VAR16)
        PUSH BC
        PUSH DE
        PUSH HL
        PUSH AF
        PUSH IX
        PUSH IY
        POP IY
        POP IX
        POP AF
        POP HL
        POP DE
        POP BC
        LD HL,STACK
        LD SP,HL
        LD IX,STACK
        LD SP,IX
        LD IY,STACK
        LD SP,IY
; ---------------------------------------------------------------- exchanges
        LD A,3
        LD (PHASE),A
        EX DE,HL
        EX AF,AF'
        EXX
        LD BC,$1111
        LD DE,$2222
        LD HL,$3333
        EXX
        EX AF,AF'
        EX DE,HL
        PUSH HL
        EX (SP),HL
        POP HL
        PUSH IX
        EX (SP),IX
        POP IX
        PUSH IY
        EX (SP),IY
        POP IY
; ---------------------------------------------------------------- block moves and compares
        LD A,4
        LD (PHASE),A
        LD HL,table
        LD DE,SRC
        LD BC,32
        LDIR
        LD HL,SRC+31
        LD DE,DST+31
        LD BC,32
        LDDR
        LD HL,SRC
        LD DE,DST+32
        LDI
        LDI
        LD HL,SRC+31
        LD DE,DST+40
        LDD
        LDD
        LD A,$55         ; present in the table
        LD HL,SRC
        LD BC,32
        CPIR
        LD A,$AA         ; absent: runs the whole block
        LD HL,SRC
        LD BC,32
        CPIR
        LD A,$55
        LD HL,SRC+31
        LD BC,32
        CPDR
        LD HL,SRC
        CPI
        CPD
; ---------------------------------------------------------------- 8-bit ALU
        LD A,5
        LD (PHASE),A
        LD A,$3C
        LD B,$5A
        LD C,$C3
        LD D,$0F
        LD E,$F0
        LD H,HIGH(BUF)
        LD L,LOW(BUF)
        ADD A,B
        ADC A,C
        SUB D
        SBC A,E
        AND H
        XOR L
        OR (HL)
        CP A
        CP B
        ADD A,$11
        ADC A,$22
        SUB $33
        SBC A,$44
        AND $0F
        XOR $FF
        OR $80
        CP $12
        ADD A,(HL)
        ADC A,(HL)
        SUB (HL)
        SBC A,(HL)
        AND (HL)
        XOR (HL)
        CP (HL)
        LD IX,BUF
        LD IY,BUF+8
        ADD A,(IX+1)
        ADC A,(IY-2)
        SUB (IX+2)
        SBC A,(IY+3)
        AND (IX+4)
        XOR (IY+5)
        OR (IX+6)
        CP (IY+7)
        INC A
        INC B
        INC C
        INC D
        INC E
        INC H
        INC L
        INC (HL)
        INC (IX+1)
        INC (IY+2)
        DEC A
        DEC B
        DEC C
        DEC D
        DEC E
        DEC H
        DEC L
        DEC (HL)
        DEC (IX+1)
        DEC (IY+2)
        LD A,$19
        ADD A,$28
        DAA
        LD A,$45
        SUB $17
        DAA
        CPL
        NEG
        CCF
        SCF
        CCF
        NOP
; ---------------------------------------------------------------- 16-bit arithmetic
        LD A,6
        LD (PHASE),A
        LD HL,$1234
        LD BC,$0FED
        LD DE,$FFFF
        ADD HL,BC
        ADD HL,DE
        ADD HL,HL
        ADD HL,SP
        ADC HL,BC
        ADC HL,DE
        ADC HL,HL
        ADC HL,SP
        SBC HL,BC
        SBC HL,DE
        SBC HL,HL
        SBC HL,SP
        LD IX,$8000
        LD IY,$7FFF
        ADD IX,BC
        ADD IX,DE
        ADD IX,IX
        ADD IX,SP
        ADD IY,BC
        ADD IY,DE
        ADD IY,IY
        ADD IY,SP
        INC BC
        INC DE
        INC HL
        INC SP
        INC IX
        INC IY
        DEC BC
        DEC DE
        DEC HL
        DEC SP
        DEC IX
        DEC IY
        LD SP,STACK
; ---------------------------------------------------------------- rotates and shifts
        LD A,7
        LD (PHASE),A
        LD A,$81
        RLCA
        RLA
        RRCA
        RRA
        LD B,$81
        LD C,$42
        LD D,$24
        LD E,$18
        LD HL,BUF+16
        RLC B
        RRC C
        RL D
        RR E
        SLA B
        SRA C
        SLL D
        SRL E
        RLC (HL)
        RRC (HL)
        RL (HL)
        RR (HL)
        SLA (HL)
        SRA (HL)
        SLL (HL)
        SRL (HL)
        RLC A
        RRC H
        RL L
        RR A
        LD IX,BUF+16
        LD IY,BUF+24
        RLC (IX+1)
        RRC (IY+1)
        RL (IX+2)
        RR (IY+2)
        SLA (IX+3)
        SRA (IY+3)
        SLL (IX+4)
        SRL (IY+4)
        LD A,$A5
        LD (HL),$3C
        RLD
        RRD
        RRD
; ---------------------------------------------------------------- bit operations
        LD A,8
        LD (PHASE),A
        BIT 0,A
        BIT 1,B
        BIT 2,C
        BIT 3,D
        BIT 4,E
        BIT 5,H
        BIT 6,L
        BIT 7,(HL)
        SET 0,A
        SET 1,B
        SET 7,(HL)
        RES 0,A
        RES 2,C
        RES 7,(HL)
        SET 3,(IX+5)
        RES 4,(IY+5)
        BIT 3,(IX+5)
        BIT 4,(IY+5)
        SET 6,(IX+6)
        RES 6,(IY+6)
        BIT 7,(IX+7)
; ---------------------------------------------------------------- jumps, loops, calls, returns
        LD A,9
        LD (PHASE),A
        LD B,5
loop1:  DJNZ loop1
        LD B,3
loop2:  NOP
        DJNZ loop2
        XOR A
        JP Z,j1
        NOP
j1:     JP NZ,j2
        JR j3
j2:     NOP
j3:     JR Z,j4
        NOP
j4:     JR NZ,j5
        INC A
j5:     JR C,j6
        SCF
j6:     JR NC,j7
        CCF
j7:     JP C,j8
        NOP
j8:     JP NC,j9
        NOP
j9:     JP PO,j10
        NOP
j10:    JP PE,j11
        NOP
j11:    JP P,j12
        NOP
j12:    JP M,j13
        NOP
j13:    LD HL,j14
        JP (HL)
        NOP
j14:    LD IX,j15
        JP (IX)
        NOP
j15:    LD IY,j16
        JP (IY)
        NOP
j16:    CALL sub1
        CALL Z,sub1
        CALL NZ,sub1
        CALL C,sub1
        CALL NC,sub1
        CALL PO,sub2
        CALL PE,sub2
        CALL P,sub2
        CALL M,sub2
        CALL sub3
        SCF
        CALL sub3
        CALL sub4
        XOR A
        CALL sub4
        CALL sub5
        LD A,$80
        OR A
        CALL sub5
        RST $08
        RST $10
        RST $18
        RST $20
        RST $28
        RST $28
        RST $30
        RST $30
; ---------------------------------------------------------------- I/O
        LD A,10
        LD (PHASE),A
        LD A,$5A
        OUT ($42),A
        IN A,($42)
        LD BC,$0343
        OUT (C),A
        IN B,(C)
        IN A,(C)
        LD BC,$0344
        IN D,(C)
        IN E,(C)
        IN H,(C)
        IN L,(C)
        IN C,(C)
        LD BC,$0345
        OUT (C),B
        OUT (C),D
        OUT (C),E
        OUT (C),H
        OUT (C),L
        OUT (C),C
        LD HL,IOBUF
        LD BC,$0450
        INI
        INIR
        LD BC,$0451
        IND
        LD BC,$0252
        INDR
        LD HL,table
        LD BC,$0453
        OUTI
        OTIR
        LD HL,table+7
        LD BC,$0454
        OUTD
        LD BC,$0255
        OTDR
; ---------------------------------------------------------------- 68000 window and peripheral region (WAIT states)
        LD A,11
        LD (PHASE),A
        LD A,($8000)
        LD ($8010),A
        LD HL,($C000)
        LD ($C002),HL
        LD A,($7F00)
        LD ($7F01),A
        LD A,($4000)
        LD ($4001),A
        LD HL,table
        LD DE,$8100
        LD BC,8
        LDIR
        LD HL,$8100
        LD DE,DST
        LD BC,8
        LDIR
        LD HL,$FF00
        LD B,4
loopw:  LD A,(HL)
        LD (HL),A
        INC HL
        DJNZ loopw
        LD IX,$C100
        INC (IX+1)
        LD A,(IX+2)
        SET 0,(IX+3)
        LD SP,$FFF0      ; a few stack operations through the bridge
        PUSH HL
        CALL sub1
        POP HL
        LD SP,STACK
; ---------------------------------------------------------------- interrupts: the bench wakes each HALT
        LD A,12
        LD (PHASE),A
        IM 0
        EI
        HALT             ; INT, the bench puts an RST opcode on the bus
        IM 1
        EI
        HALT             ; INT -> 0038
        LD A,HIGH(vectab)
        LD I,A
        IM 2
        EI
        HALT             ; INT, vector byte from the bench -> vectab -> im2h
        DI
        HALT             ; NMI only
        IM 1
        EI
        HALT
        IM 2
        EI
        HALT
        DI
        HALT
        IM 0
        EI
        HALT
; ---------------------------------------------------------------- done
        LD A,13
        LD (PHASE),A
        LD A,$A5
        LD (SIG),A
end:    HALT             ; the bench keeps waking it until it ends the phase
        JR end

sub1:   PUSH AF
        LD A,(VAR)
        INC A
        LD (VAR),A
        POP AF
        RET
sub2:   INC A
        RET Z
        RET NZ
sub3:   RET C
        RET NC
sub4:   RET PO
        RET PE
        RET
sub5:   RET P
        RET M

table:  DB $00,$11,$22,$33,$44,$55,$66,$77,$88,$99,$AA,$BB,$CC,$DD,$EE,$FF
        DB $01,$02,$04,$08,$10,$20,$40,$80,$FE,$FD,$FB,$F7,$EF,$DF,$BF,$7F

        ORG $0A0A
im2h:   PUSH AF          ; IM 2 handler: at 0A0A so that any vector byte, odd or even, reaches it
        LD A,(INTCNT)
        ADD A,$10
        LD (INTCNT),A
        POP AF
        EI
        RETI

        ORG $1F00
vectab: DS 256,$0A       ; IM 2 vector table: every entry (either alignment) = 0A0A
