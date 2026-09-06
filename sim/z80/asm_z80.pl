#!/usr/bin/perl
# asm_z80.pl -- tiny two-pass Z80 assembler for the bench program (documented instruction set plus
# SLL; no undocumented IXH/IXL forms). Output: a $readmemh image, one byte per line.
#   usage: perl asm_z80.pl z80_prog.asm z80_rom.hex [ROMSIZE]
# Syntax: `label:`; `name EQU expr`; ORG/DB/DW/DS; standard Zilog mnemonics, one per line; `;`
# comments. Numbers: 123, $1F, 0x1F, 1Fh, 'c'. Expressions: terms joined by + and - (labels, `$` =
# current address, LOW(x)/HIGH(x)). Case-insensitive.
use strict; use warnings;
my ($in, $out, $size) = @ARGV; $size ||= 8192;
open(my $fh, '<', $in) or die "$in: $!"; my @lines = <$fh>; close $fh;

my %sym; my $pass; my $pc; my @mem = (0xFF) x $size; my %used;
my %R8 = (B=>0, C=>1, D=>2, E=>3, H=>4, L=>5, '(HL)'=>6, A=>7);
my %RP = (BC=>0, DE=>1, HL=>2, SP=>3);
my %RQ = (BC=>0, DE=>1, HL=>2, AF=>3);
my %CC = (NZ=>0, Z=>1, NC=>2, C=>3, PO=>4, PE=>5, P=>6, M=>7);
my %ALU = (ADD=>0, ADC=>1, SUB=>2, SBC=>3, AND=>4, XOR=>5, OR=>6, CP=>7);
my %ROT = (RLC=>0, RRC=>1, RL=>2, RR=>3, SLA=>4, SRA=>5, SLL=>6, SRL=>7);
my %IDX = (IX=>0xDD, IY=>0xFD);
my %ED = (NEG=>0x44, RETN=>0x45, RETI=>0x4D, RRD=>0x67, RLD=>0x6F, LDI=>0xA0, CPI=>0xA1, INI=>0xA2, OUTI=>0xA3,
	LDD=>0xA8, CPD=>0xA9, IND=>0xAA, OUTD=>0xAB, LDIR=>0xB0, CPIR=>0xB1, INIR=>0xB2, OTIR=>0xB3, LDDR=>0xB8, CPDR=>0xB9,
	INDR=>0xBA, OTDR=>0xBB);
my %ONE = (NOP=>0x00, RLCA=>0x07, RRCA=>0x0F, RLA=>0x17, RRA=>0x1F, DAA=>0x27, CPL=>0x2F, SCF=>0x37, CCF=>0x3F, HALT=>0x76,
	RET=>0xC9, EXX=>0xD9, DI=>0xF3, EI=>0xFB);

sub err { my $m = shift; die "$in: $m\n" }
sub num {
	my $t = shift;
	return hex($1) if $t =~ /^\$([0-9A-F]+)$/;
	return hex($1) if $t =~ /^0X([0-9A-F]+)$/;
	return hex($1) if $t =~ /^([0-9A-F]+)H$/;
	return $t + 0 if $t =~ /^\d+$/;
	return ord($1) if $t =~ /^'(.)'$/;
	return $pc if $t eq '$';
	if ($t =~ /^LOW\((.*)\)$/) { return expr($1) & 0xFF }
	if ($t =~ /^HIGH\((.*)\)$/) { return (expr($1) >> 8) & 0xFF }
	if (exists $sym{$t}) { return $sym{$t} }
	err("undefined symbol $t") if $pass == 2;
	$used{$t} = 1;
	return 0;
}
sub expr {
	my $e = shift; $e =~ s/\s+//g;
	my $v = 0; my $sign = 1;
	# tokens: [+-]?term, terms may contain LOW(...)/HIGH(...) with a nested expression
	while (length $e) {
		if ($e =~ s/^([+-])//) { $sign = $1 eq '-' ? -1 : 1; next }
		if ($e =~ s/^((?:LOW|HIGH)\([^()]*\)|'.'|\$[0-9A-F]+|[0-9A-Z_\$]+)//) { $v += $sign * num($1); $sign = 1; next }
		err("bad expression '$_[0]'");
	}
	return $v & 0xFFFF;
}
sub b8 { my $v = expr(shift); err("byte out of range: $v") if $pass == 2 && ($v > 0xFF && $v < 0xFF00); return $v & 0xFF }
sub disp { my $v = expr(shift); $v -= 0x10000 if $v >= 0x8000; err("index displacement out of range: $v") if $pass == 2 && ($v < -128 || $v > 127); return $v & 0xFF }
sub rel { my $v = expr(shift); my $d = $v - (($pc + 2) & 0xFFFF); $d -= 0x10000 if $d >= 0x8000; $d += 0x10000 if $d < -0x8000;
	err("relative jump out of range ($d)") if $pass == 2 && ($d < -128 || $d > 127); return $d & 0xFF }
sub w16 { my $v = expr(shift); return ($v & 0xFF, ($v >> 8) & 0xFF) }
sub mem { my $o = shift; return $1 if $o =~ /^\((.*)\)$/ && $o !~ /^\((HL|BC|DE|SP|C|IX|IY)([+-].*)?\)$/; return undef }
sub idx { my $o = shift; return ($IDX{$1}, defined $2 ? disp($2) : 0) if $o =~ /^\((IX|IY)([+-].*)?\)$/; return () }

sub enc {
	my ($mn, @o) = @_;
	my $n = @o;
	return ($ONE{$mn}) if exists $ONE{$mn} && $n == 0;
	return (0xED, $ED{$mn}) if exists $ED{$mn} && $n == 0;
	if ($mn eq 'LD' && $n == 2) {
		my ($d, $s) = @o;
		my @di = idx($d); my @si = idx($s);
		if (exists $R8{$d} && exists $R8{$s}) { err("LD (HL),(HL)") if $d eq '(HL)' && $s eq '(HL)'; return (0x40 | $R8{$d} << 3 | $R8{$s}) }
		if (exists $R8{$d} && @si) { return ($si[0], 0x40 | $R8{$d} << 3 | 6, $si[1]) }
		if (@di && exists $R8{$s} && $s ne '(HL)') { return ($di[0], 0x70 | $R8{$s}, $di[1]) }
		if (@di) { return ($di[0], 0x36, $di[1], b8($s)) }
		if ($d eq 'A' && $s eq '(BC)') { return (0x0A) }
		if ($d eq 'A' && $s eq '(DE)') { return (0x1A) }
		if ($d eq '(BC)' && $s eq 'A') { return (0x02) }
		if ($d eq '(DE)' && $s eq 'A') { return (0x12) }
		if ($d eq 'A' && $s eq 'I') { return (0xED, 0x57) }
		if ($d eq 'A' && $s eq 'R') { return (0xED, 0x5F) }
		if ($d eq 'I' && $s eq 'A') { return (0xED, 0x47) }
		if ($d eq 'R' && $s eq 'A') { return (0xED, 0x4F) }
		if ($d eq 'SP' && $s eq 'HL') { return (0xF9) }
		if ($d eq 'SP' && exists $IDX{$s}) { return ($IDX{$s}, 0xF9) }
		my $dm = mem($d); my $sm = mem($s);
		if ($d eq 'A' && defined $sm) { return (0x3A, w16($sm)) }
		if (defined $dm && $s eq 'A') { return (0x32, w16($dm)) }
		if ($d eq 'HL' && defined $sm) { return (0x2A, w16($sm)) }
		if (defined $dm && $s eq 'HL') { return (0x22, w16($dm)) }
		if (exists $IDX{$d} && defined $sm) { return ($IDX{$d}, 0x2A, w16($sm)) }
		if (defined $dm && exists $IDX{$s}) { return ($IDX{$s}, 0x22, w16($dm)) }
		if (exists $RP{$d} && defined $sm) { return (0xED, 0x4B | $RP{$d} << 4, w16($sm)) }
		if (defined $dm && exists $RP{$s}) { return (0xED, 0x43 | $RP{$s} << 4, w16($dm)) }
		if (exists $R8{$d}) { return (0x06 | $R8{$d} << 3, b8($s)) }
		if (exists $RP{$d}) { return (0x01 | $RP{$d} << 4, w16($s)) }
		if (exists $IDX{$d}) { return ($IDX{$d}, 0x21, w16($s)) }
	}
	if (($mn eq 'PUSH' || $mn eq 'POP') && $n == 1) {
		my $op = $mn eq 'PUSH' ? 0xC5 : 0xC1;
		return ($op | $RQ{$o[0]} << 4) if exists $RQ{$o[0]};
		return ($IDX{$o[0]}, $op | 0x20) if exists $IDX{$o[0]};
	}
	if ($mn eq 'EX' && $n == 2) {
		return (0xEB) if "@o" eq 'DE HL';
		return (0x08) if "@o" eq "AF AF'";
		return (0xE3) if "@o" eq '(SP) HL';
		return ($IDX{$o[1]}, 0xE3) if $o[0] eq '(SP)' && exists $IDX{$o[1]};
	}
	if (exists $ALU{$mn} && !(($mn eq 'ADD' || $mn eq 'ADC' || $mn eq 'SBC') && $n == 2 && ($o[0] eq 'HL' || exists $IDX{$o[0]}))) {
		my $s = $o[-1];
		if ($n == 2) { err("$mn: first operand must be A") unless $o[0] eq 'A' }
		elsif ($mn eq 'ADD' || $mn eq 'ADC' || $mn eq 'SBC') { err("$mn needs two operands") }
		my @si = idx($s);
		return (0x80 | $ALU{$mn} << 3 | $R8{$s}) if exists $R8{$s};
		return ($si[0], 0x80 | $ALU{$mn} << 3 | 6, $si[1]) if @si;
		return (0xC6 | $ALU{$mn} << 3, b8($s));
	}
	if (($mn eq 'INC' || $mn eq 'DEC') && $n == 1) {
		my $s = $o[0]; my @si = idx($s);
		my $b = $mn eq 'INC' ? 0 : 1;
		return (0x04 | $R8{$s} << 3 | $b) if exists $R8{$s};
		return ($si[0], 0x34 | $b, $si[1]) if @si;
		return (0x03 | $RP{$s} << 4 | $b << 3) if exists $RP{$s};
		return ($IDX{$s}, 0x23 | $b << 3) if exists $IDX{$s};
	}
	if ($mn eq 'IM' && $n == 1) { return (0xED, (0x46, 0x56, 0x5E)[$o[0]]) }
	if (($mn eq 'ADD' || $mn eq 'ADC' || $mn eq 'SBC') && $n == 2 && ($o[0] eq 'HL' || exists $IDX{$o[0]})) {
		my ($d, $s) = @o;
		if ($d eq 'HL') {
			return (0x09 | $RP{$s} << 4) if $mn eq 'ADD';
			return (0xED, 0x4A | $RP{$s} << 4) if $mn eq 'ADC';
			return (0xED, 0x42 | $RP{$s} << 4);
		}
		my %PP = (BC=>0, DE=>1, $d=>2, SP=>3);
		return ($IDX{$d}, 0x09 | $PP{$s} << 4) if $mn eq 'ADD' && exists $PP{$s};
	}
	if (exists $ROT{$mn} && $n == 1) {
		my $s = $o[0]; my @si = idx($s);
		return (0xCB, $ROT{$mn} << 3 | $R8{$s}) if exists $R8{$s};
		return ($si[0], 0xCB, $si[1], $ROT{$mn} << 3 | 6) if @si;
	}
	if (($mn eq 'BIT' || $mn eq 'SET' || $mn eq 'RES') && $n == 2) {
		my $b = expr($o[0]); my $s = $o[1]; my @si = idx($s);
		my $op = $mn eq 'BIT' ? 0x40 : $mn eq 'RES' ? 0x80 : 0xC0;
		return (0xCB, $op | $b << 3 | $R8{$s}) if exists $R8{$s};
		return ($si[0], 0xCB, $si[1], $op | $b << 3 | 6) if @si;
	}
	if ($mn eq 'JP') {
		return (0xC3, w16($o[0])) if $n == 1 && !defined idx($o[0]) && $o[0] ne '(HL)';
		return (0xE9) if $n == 1 && $o[0] eq '(HL)';
		return ($IDX{$1}, 0xE9) if $n == 1 && $o[0] =~ /^\((IX|IY)\)$/;
		return (0xC2 | $CC{$o[0]} << 3, w16($o[1])) if $n == 2 && exists $CC{$o[0]};
	}
	if ($mn eq 'JR') {
		return (0x18, rel($o[0])) if $n == 1;
		my %JR = (NZ=>0x20, Z=>0x28, NC=>0x30, C=>0x38);
		return ($JR{$o[0]}, rel($o[1])) if $n == 2 && exists $JR{$o[0]};
	}
	if ($mn eq 'DJNZ' && $n == 1) { return (0x10, rel($o[0])) }
	if ($mn eq 'CALL') {
		return (0xCD, w16($o[0])) if $n == 1;
		return (0xC4 | $CC{$o[0]} << 3, w16($o[1])) if $n == 2 && exists $CC{$o[0]};
	}
	if ($mn eq 'RET' && $n == 1) { return (0xC0 | $CC{$o[0]} << 3) if exists $CC{$o[0]} }
	if ($mn eq 'RST' && $n == 1) { my $p = expr($o[0]); err("bad RST") if $p & ~0x38; return (0xC7 | $p) }
	if ($mn eq 'IN' && $n == 2) {
		return (0xDB, b8($1)) if $o[0] eq 'A' && $o[1] =~ /^\((.*)\)$/ && $o[1] ne '(C)';
		return (0xED, 0x40 | $R8{$o[0]} << 3) if $o[1] eq '(C)' && exists $R8{$o[0]} && $o[0] ne '(HL)';
	}
	if ($mn eq 'OUT' && $n == 2) {
		return (0xD3, b8($1)) if $o[1] eq 'A' && $o[0] =~ /^\((.*)\)$/ && $o[0] ne '(C)';
		return (0xED, 0x41 | $R8{$o[1]} << 3) if $o[0] eq '(C)' && exists $R8{$o[1]} && $o[1] ne '(HL)';
	}
	err("cannot assemble: $mn " . join(',', @o));
}

sub emit { for my $b (@_) { err(sprintf("address %04X outside the ROM", $pc)) if $pc >= $size; if ($pass == 2) { err(sprintf("overlap at %04X", $pc)) if $used{"@".$pc}; $used{"@".$pc} = 1; $mem[$pc] = $b & 0xFF } $pc = ($pc + 1) & 0xFFFF } }

for my $pass_iter (1, 2) {
	$pass = $pass_iter;
	$pc = 0; my $ln = 0;
	for my $raw (@lines) {
		$ln++;
		my $l = $raw; $l =~ s/\r?\n$//; $l =~ s/;.*//; $l = uc $l;
		if ($l =~ s/^\s*([A-Z_][A-Z0-9_]*):\s*//) { my $lab = $1; err("line $ln: label $lab redefined") if $pass == 1 && exists $sym{$lab}; $sym{$lab} = $pc if $pass == 1; }
		$l =~ s/^\s+//; $l =~ s/\s+$//;
		next unless length $l;
		if ($l =~ /^([A-Z_][A-Z0-9_]*)\s+EQU\s+(.*)$/) { $sym{$1} = expr($2) if $pass == 1; next }
		my ($mn, $rest) = $l =~ /^(\S+)\s*(.*)$/;
		my @o = length $rest ? map { s/^\s+//; s/\s+$//; $_ } split(/,/, $rest) : ();
		eval {
			if ($mn eq 'ORG') { $pc = expr($o[0]) }
			elsif ($mn eq 'DB') { emit(map { b8($_) } @o) }
			elsif ($mn eq 'DW') { emit(map { w16($_) } @o) }
			elsif ($mn eq 'DS') { my $c = expr($o[0]); my $f = @o > 1 ? b8($o[1]) : 0; emit(($f) x $c) }
			else { emit(enc($mn, @o)) }
		};
		err("line $ln ($raw): $@") if $@;
	}
}
open($fh, '>', $out) or die "$out: $!";
binmode $fh;
printf $fh "%02x\n", $_ for @mem;
close $fh;
printf STDERR "asm_z80: %d bytes used of %d, %d symbols\n", scalar(grep { /^@/ } keys %used), $size, scalar(grep { !/^@/ } keys %sym);
