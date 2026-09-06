#!/usr/bin/perl
# transform.pl -- STAGE 1 instance-by-instance transformer for ym7101.v -> ym7101_rtl.v
#
# Reads rtl/nuked-md/ym7101.v and writes rtl/nuked-md/ym7101_rtl.v, converting every ym_lib
# primitive instance in the three modules' bodies into inline registered logic that produces
# the SAME value at every posedge MCLK (STAGE 1, no register collapse).  It also emits a
# storage manifest (sim/ym7101/storage_manifest.txt) listing, per converted storage element,
# the die-model hierarchical path and the matching _rtl reg, for the A/B bench generator.
#
# Rules (see ym_lib.v for the exact primitive definitions):
#   ym_slatch/ym_dlatch_1/ym_dlatch_2 : mem<=en?inp:mem  ->  if(en) mem<=inp; val=mem, nval=~mem
#   ym_slatch_t                       : same store, but transparent output val=mem_assign (feed-through)
#   ym_slatch_r                       : if(rst) mem<=0; else if(en) mem<=inp
#   ym_sr_bit (DW=1, len L)           : two regs v1,v2 : if(c1) v1<={v2[L-2:0],bit_in}; if(c2) v2<=v1; sr_out=v2[L-1]
#   ym_sr_bit_array (DW cells, len L) : DW parallel ym_sr_bit
#   ym_sr_bit_en (L cells, inner 1)   : L-bit shift with en1/en2 select, over a ym_sr_bit_array
#   ym_cnt_bit / _load / _rs / _rev   : ym_sr_bit_array (len 1) + the primitive's adder/select combinational logic
#   ym_dbg_read                       : ym_sr_bit_array (len 1) + shift/load chain
# The two module-local helpers ym7101_dff and ym7101_rs_trig are ALREADY in master-slave /
# rs two-register posedge-MCLK form in ym7101.v, so they are kept as modules (renamed *_rtl)
# and their instances are just retyped; their l1/l2 (dff) and q/nq (rs_trig) are compared as-is.
use strict; use warnings;

my $SRC = "rtl/nuked-md/ym7101.v";
my $DST = "rtl/nuked-md/ym7101_rtl.v";
my $MAN = "sim/ym7101/storage_manifest.txt";

open(my $in, "<", $SRC) or die "open $SRC: $!";
my @L = <$in>; close $in;

# leaf ym_lib types we inline (longest names first for safety, though we match whole token)
my %INLINE = map {$_=>1} qw(ym_sr_bit_array ym_sr_bit_en ym_sr_bit ym_slatch_t ym_slatch_r
  ym_slatch ym_dlatch_1 ym_dlatch_2 ym_cnt_bit_load ym_cnt_bit_rs ym_cnt_bit_rev ym_cnt_bit
  ym_dbg_read);
my %HELPER = ("ym7101_dff"=>"ym7101_dff_rtl", "ym7101_rs_trig"=>"ym7101_rs_trig_rtl");

my @man;                 # manifest lines: label \t die_expr \t rtl_expr \t width
my %counts;              # census
my $flagged = 0;         # irregular-construct notes

sub zeros { my $w=shift; return $w>1 ? "{".$w."{1'h0}}" : "1'h0"; }
sub ones  { my $w=shift; return $w>1 ? "{".$w."{1'h1}}" : "1'h1"; }
sub vw    { my $w=shift; return $w>1 ? "[".($w-1).":0] " : ""; }

# --- balanced-paren reader: given string and pos at '(', return (inner, pos-after-close)
sub read_bal {
  my ($s,$i)=@_;
  die "expected ( at $i in: $s" unless substr($s,$i,1) eq '(';
  my $d=0; my $j=$i;
  while ($j < length($s)) {
    my $c=substr($s,$j,1);
    $d++ if $c eq '(';
    $d-- if $c eq ')';
    return (substr($s,$i+1,$j-$i-1), $j+1) if $d==0;
    $j++;
  }
  die "unbalanced parens in: $s";
}

# split a port/param list on top-level commas
sub split_top {
  my $s=shift; my @out; my $d=0; my $cur="";
  for my $c (split //,$s) {
    if ($c eq '(' || $c eq '{' || $c eq '[') { $d++; $cur.=$c; }
    elsif ($c eq ')' || $c eq '}' || $c eq ']') { $d--; $cur.=$c; }
    elsif ($c eq ',' && $d==0) { push @out,$cur; $cur=""; }
    else { $cur.=$c; }
  }
  push @out,$cur if $cur=~/\S/;
  return @out;
}

# parse a cleaned instance statement (no comments), return hashref
sub parse_inst {
  my $s=shift;
  $s =~ /^(\s*)([A-Za-z_]\w*)\s*/g or die "no type: $s";
  my $indent=$1; my $type=$2; my $i=pos($s);
  my %params;
  # optional #(...)
  if (substr($s,$i) =~ /^\s*#\s*/) {
    $s =~ /\G\s*#\s*/gc; $i=pos($s);
    (my $pstr,$i)=read_bal($s,index($s,'(',$i));
    for my $p (split_top($pstr)) {
      $p=~/\.\s*(\w+)\s*\(\s*(.*?)\s*\)\s*$/s or die "param parse: $p";
      $params{$1}=$2;
    }
    pos($s)=$i;
  }
  $s =~ /\G\s*([A-Za-z_]\w*)\s*/gc or die "no instname: $s";
  my $inst=$1; $i=pos($s);
  (my $portstr,$i)=read_bal($s,index($s,'(',$i));
  my @ports;
  for my $p (split_top($portstr)) {
    $p=~/^\s*\.\s*(\w+)\s*/gc or die "port parse: $p";
    my $pn=$1; my $pi=pos($p);
    (my $expr,$pi)=read_bal($p,index($p,'(',$pi));
    $expr =~ s/^\s+//; $expr =~ s/\s+$//;
    push @ports,[$pn,$expr];
  }
  return {indent=>$indent,type=>$type,params=>\%params,inst=>$inst,ports=>\@ports};
}

# emit the inline block for one parsed ym_lib instance; returns text, appends manifest
sub emit_inline {
  my ($h,$raw)=@_;
  my $ind=$h->{indent}; my $t=$h->{type}; my $n=$h->{inst};
  my %p = map {$_->[0]=>$_->[1]} @{$h->{ports}};
  my $DW = exists $h->{params}{DATA_WIDTH} ? $h->{params}{DATA_WIDTH}+0 : 1;
  my $SLdef = ($t eq 'ym_sr_bit_en') ? 2 : 1;
  my $SL = exists $h->{params}{SR_LENGTH} ? $h->{params}{SR_LENGTH}+0 : $SLdef;
  my $o = "";
  # echo the original as a comment (collapse whitespace/newlines)
  (my $cmt = $raw) =~ s/\s*\n\s*/ /g; $cmt =~ s/\s+/ /g; $cmt =~ s/^\s+//; $cmt =~ s/\s+$//;
  $o .= "$ind// $cmt\n";

  my $assign_out = sub { my ($port,$rhs)=@_; return exists $p{$port} ? "$ind assign $p{$port} = $rhs;\n" : ""; };

  if ($t eq 'ym_slatch' || $t eq 'ym_dlatch_1' || $t eq 'ym_dlatch_2') {
    my $en = $t eq 'ym_slatch' ? $p{en} : ($t eq 'ym_dlatch_1' ? $p{c1} : $p{c2});
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind always \@(posedge MCLK) if ($en) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',  "${n}_mem");
    $o .= $assign_out->('nval', "~${n}_mem");
    push @man, join("\t","$n.mem","$n.mem","${n}_mem",$DW);
  }
  elsif ($t eq 'ym_slatch_t') {
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind wire ".vw($DW)."${n}_mem_assign = $p{en} ? $p{inp} : ${n}_mem;\n";
    $o .= "$ind always \@(posedge MCLK) if ($p{en}) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',  "${n}_mem_assign");
    $o .= $assign_out->('nval', "~${n}_mem_assign");
    push @man, join("\t","$n.mem","$n.mem","${n}_mem",$DW);
  }
  elsif ($t eq 'ym_slatch_r') {
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind always \@(posedge MCLK) if ($p{rst}) ${n}_mem <= ".zeros($DW).";\n";
    $o .= "$ind\telse if ($p{en}) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',  "${n}_mem");
    $o .= $assign_out->('nval', "~${n}_mem");
    push @man, join("\t","$n.mem","$n.mem","${n}_mem",$DW);
  }
  elsif ($t eq 'ym_sr_bit') {   # DW=1, length SL
    my $L=$SL;
    $o .= "$ind reg ".vw($L)."${n}_v1 = ".zeros($L).", ${n}_v2 = ".zeros($L).";\n";
    $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
    if ($L==1) { $o .= "$ind\tif ($p{c1}) ${n}_v1 <= $p{bit_in};\n"; }
    else       { $o .= "$ind\tif ($p{c1}) ${n}_v1 <= { ${n}_v2[".($L-2).":0], $p{bit_in} };\n"; }
    $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
    $o .= "$ind end\n";
    $o .= $assign_out->('sr_out', $L==1 ? "${n}_v2" : "${n}_v2[".($L-1)."]");
    push @man, join("\t","$n.v1","$n.v1","${n}_v1",$L);
    push @man, join("\t","$n.v2","$n.v2","${n}_v2",$L);
  }
  elsif ($t eq 'ym_sr_bit_array') {   # DW cells each length SL
    my $L=$SL; my $tot=$DW*$L;
    $o .= "$ind reg ".vw($tot)."${n}_v1 = ".zeros($tot).", ${n}_v2 = ".zeros($tot).";\n";
    $o .= "$ind wire ".vw($DW)."${n}_din = $p{data_in};\n";
    if ($L==1) {
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
      $o .= "$ind\tif ($p{c1}) ${n}_v1 <= ${n}_din;\n";
      $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
      $o .= "$ind end\n";
      $o .= $assign_out->('data_out', "${n}_v2");
    } else {
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
      $o .= "$ind\tif ($p{c1})\n$ind\tbegin\n";
      for my $i (0..$DW-1) { my $b=$i*$L;
        $o .= "$ind\t\t${n}_v1[$b +: $L] <= { ${n}_v2[$b +: ".($L-1)."], ${n}_din[$i] };\n"; }
      $o .= "$ind\tend\n";
      $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
      $o .= "$ind end\n";
      if (exists $p{data_out}) {
        $o .= "$ind wire ".vw($DW)."${n}_dout;\n";
        for my $i (0..$DW-1) { $o .= "$ind assign ${n}_dout[$i] = ${n}_v2[".($i*$L+$L-1)."];\n"; }
        $o .= "$ind assign $p{data_out} = ${n}_dout;\n";
      }
    }
    for my $i (0..$DW-1) { my $b=$i*$L;
      my $r1 = ($tot==1) ? "${n}_v1" : ($L==1 ? "${n}_v1[$i]" : "${n}_v1[$b +: $L]");
      my $r2 = ($tot==1) ? "${n}_v2" : ($L==1 ? "${n}_v2[$i]" : "${n}_v2[$b +: $L]");
      push @man, join("\t","$n.l1[$i].sr.v1","$n.l1[$i].sr.v1", $r1, $L);
      push @man, join("\t","$n.l1[$i].sr.v2","$n.l1[$i].sr.v2", $r2, $L);
    }
  }
  elsif ($t eq 'ym_sr_bit_en') {   # L cells inner len 1
    my $L=$SL;
    $o .= "$ind reg ".vw($L)."${n}_v1 = ".zeros($L).", ${n}_v2 = ".zeros($L).";\n";
    $o .= "$ind wire ".vw($L)."${n}_sr_out = ${n}_v2;\n";
    $o .= "$ind wire ".vw($L)."${n}_sr_in = ($p{en1} ? { ${n}_sr_out[".($L-2).":0], $p{data_in} } : ".zeros($L).")\n";
    $o .= "$ind\t| ($p{en2} ? ${n}_sr_out : ".zeros($L).");\n";
    $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
    $o .= "$ind\tif ($p{c1}) ${n}_v1 <= ${n}_sr_in;\n";
    $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
    $o .= "$ind end\n";
    $o .= $assign_out->('data_out', "${n}_sr_out");
    for my $i (0..$L-1) {
      push @man, join("\t","$n.mem.l1[$i].sr.v1","$n.mem.l1[$i].sr.v1","${n}_v1[$i]",1);
      push @man, join("\t","$n.mem.l1[$i].sr.v2","$n.mem.l1[$i].sr.v2","${n}_v2[$i]",1);
    }
  }
  elsif ($t eq 'ym_cnt_bit' || $t eq 'ym_cnt_bit_load' || $t eq 'ym_cnt_bit_rs' || $t eq 'ym_cnt_bit_rev') {
    my $W=$DW;
    $o .= "$ind reg ".vw($W)."${n}_v1 = ".zeros($W).", ${n}_v2 = ".zeros($W).";\n";
    $o .= "$ind wire ".vw($W)."${n}_data_out = ${n}_v2;\n";
    if ($t eq 'ym_cnt_bit') {
      $o .= "$ind wire [".$W.":0] ${n}_sum = { 1'h0, ${n}_data_out } + { ".zeros($W).", $p{c_in} };\n";
      $o .= "$ind wire ".vw($W)."${n}_data_in = $p{reset} ? ".zeros($W)." : ${n}_sum[".($W-1).":0];\n";
    } elsif ($t eq 'ym_cnt_bit_load') {
      $o .= "$ind wire ".vw($W)."${n}_base_val = $p{load} ? $p{load_val} : ${n}_data_out;\n";
      $o .= "$ind wire [".$W.":0] ${n}_sum = { 1'h0, ${n}_base_val } + { ".zeros($W).", $p{c_in} };\n";
      $o .= "$ind wire ".vw($W)."${n}_data_in = $p{reset} ? ".zeros($W)." : ${n}_sum[".($W-1).":0];\n";
    } elsif ($t eq 'ym_cnt_bit_rs') {
      $o .= "$ind wire ".vw($W)."${n}_data_out_s = $p{set} ? ".ones($W)." : ${n}_data_out;\n";
      $o .= "$ind wire [".$W.":0] ${n}_sum = { 1'h0, ${n}_data_out_s } + { ".zeros($W).", $p{c_in} };\n";
      $o .= "$ind wire ".vw($W)."${n}_data_in = $p{reset} ? ".zeros($W)." : ${n}_sum[".($W-1).":0];\n";
    } else { # rev
      my $decterm = $W>1 ? "{".$W."{".$p{dec}."}}" : $p{dec};
      $o .= "$ind wire [".$W.":0] ${n}_sum = { 1'h0, ${n}_data_out } + { 1'h0, ".$decterm." } + { ".zeros($W).", $p{c_in} };\n";
      $o .= "$ind wire ".vw($W)."${n}_data_in = $p{reset} ? ".zeros($W)." : ${n}_sum[".($W-1).":0];\n";
    }
    $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
    $o .= "$ind\tif ($p{c1}) ${n}_v1 <= ${n}_data_in;\n";
    $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
    $o .= "$ind end\n";
    if ($t eq 'ym_cnt_bit_rs') {
      $o .= $assign_out->('val',  "${n}_data_out_s");
      $o .= $assign_out->('nval', "~${n}_data_out_s");
    } else {
      $o .= $assign_out->('val',  "${n}_data_out");
    }
    $o .= $assign_out->('c_out', "${n}_sum[$W]");
    for my $i (0..$W-1) {
      my $r1 = ($W==1) ? "${n}_v1" : "${n}_v1[$i]";
      my $r2 = ($W==1) ? "${n}_v2" : "${n}_v2[$i]";
      push @man, join("\t","$n.mem.l1[$i].sr.v1","$n.mem.l1[$i].sr.v1",$r1,1);
      push @man, join("\t","$n.mem.l1[$i].sr.v2","$n.mem.l1[$i].sr.v2",$r2,1);
    }
  }
  elsif ($t eq 'ym_dbg_read') {
    my $W=$DW;
    $o .= "$ind reg ".vw($W)."${n}_v1 = ".zeros($W).", ${n}_v2 = ".zeros($W).";\n";
    $o .= "$ind wire ".vw($W)."${n}_data_out = ${n}_v2;\n";
    if ($W==1) { $o .= "$ind wire ${n}_chain = $p{prev};\n"; }
    else { $o .= "$ind wire ".vw($W)."${n}_chain = { $p{prev}, ${n}_data_out[".($W-1).":1] };\n"; }
    $o .= "$ind wire ".vw($W)."${n}_data_in = ${n}_chain | ($p{load} ? $p{load_val} : ".zeros($W).");\n";
    $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
    $o .= "$ind\tif ($p{c1}) ${n}_v1 <= ${n}_data_in;\n";
    $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n";
    $o .= "$ind end\n";
    $o .= $assign_out->('next', "${n}_data_out[0]");
    for my $i (0..$W-1) {
      my $r1 = ($W==1) ? "${n}_v1" : "${n}_v1[$i]";
      my $r2 = ($W==1) ? "${n}_v2" : "${n}_v2[$i]";
      push @man, join("\t","$n.mem.l1[$i].sr.v1","$n.mem.l1[$i].sr.v1",$r1,1);
      push @man, join("\t","$n.mem.l1[$i].sr.v2","$n.mem.l1[$i].sr.v2",$r2,1);
    }
  }
  else { die "unhandled type $t"; }
  return $o;
}

# ---- main walk -----------------------------------------------------------------
my @out;
my $i=0; my $N=scalar @L;
my $inblock=0;   # inside /* */ ?

# header comment
push @out, header_comment();

while ($i < $N) {
  my $line = $L[$i];
  # track block comments crudely for instance detection only (still copy lines verbatim)
  my $code = $line;
  # remove full-line // comment content for detection
  (my $probe = $line) =~ s{//.*$}{};
  # if we're inside a block comment, just copy until it closes
  if ($inblock) {
    push @out,$line;
    $inblock=0 if $line =~ m{\*/};
    $i++; next;
  }
  # module rename lines
  if ($probe =~ /^\s*module\s+ym7101\s*$/ || $probe =~ /^\s*module\s+ym7101\s*\(/ ) {
    $line =~ s/\bym7101\b/ym7101_rtl/; push @out,$line; $i++; next;
  }
  if ($probe =~ /^\s*module\s+ym7101_rs_trig\b/) { $line =~ s/\bym7101_rs_trig\b/ym7101_rs_trig_rtl/; push @out,$line; $i++; next; }
  if ($probe =~ /^\s*module\s+ym7101_dff\b/) { $line =~ s/\bym7101_dff\b/ym7101_dff_rtl/; push @out,$line; $i++; next; }

  # detect start of a block comment on this line (that opens and does not close)
  if ($probe =~ m{/\*} && $line !~ m{\*/}) { push @out,$line; $inblock=1; $i++; next; }

  # instance detection: leading identifier token
  if ($probe =~ /^(\s*)([A-Za-z_]\w*)\b/) {
    my $tok=$2;
    if ($INLINE{$tok} || $HELPER{$tok}) {
      # gather full statement until code part ends with );
      my $j=$i; my $raw=""; my $clean="";
      while ($j < $N) {
        my $pl=$L[$j];
        $raw .= $pl;
        (my $c=$pl) =~ s{//.*$}{};
        $clean .= $c;
        if ($c =~ /\)\s*;\s*$/) { last; }
        $j++;
      }
      if ($j >= $N) { die "unterminated instance at line ".($i+1); }
      $counts{$tok}++;
      if ($HELPER{$tok}) {
        # keep as module instance, just retype; record l1/l2 or q/nq for the bench
        (my $newraw=$raw) =~ s/\b\Q$tok\E\b/$HELPER{$tok}/;
        push @out,$newraw;
        my $hh = parse_inst($clean);
        my $inst = $hh->{inst};
        my $dw = exists $hh->{params}{DATA_WIDTH} ? $hh->{params}{DATA_WIDTH}+0 : 1;
        if ($tok eq 'ym7101_dff') {
          push @man, join("\t","$inst.l1","$inst.l1","$inst.l1",$dw);
          push @man, join("\t","$inst.l2","$inst.l2","$inst.l2",$dw);
        } else {
          push @man, join("\t","$inst.q","$inst.q","$inst.q",1);
          push @man, join("\t","$inst.nq","$inst.nq","$inst.nq",1);
        }
      } else {
        my $h = parse_inst($clean);
        push @out, emit_inline($h,$raw);
      }
      $i=$j+1; next;
    }
  }
  # default copy
  push @out,$line;
  # opening block comment that also closes handled by inblock=0 path above
  $i++;
}

open(my $of,">",$DST) or die "write $DST: $!"; print $of @out; close $of;
open(my $mf,">",$MAN) or die "write $MAN: $!"; print $mf map {"$_\n"} @man; close $mf;

# census to stderr
print STDERR "wrote $DST (".scalar(@out)." chunks) and $MAN (".scalar(@man)." storage rows)\n";
print STDERR "instance census:\n";
for my $t (sort keys %counts) { printf STDERR "  %-18s %d\n",$t,$counts{$t}; }

sub header_comment {
  return <<'H';
/*
 * ym7101_rtl -- 1:1 synthesis-friendly representation of ym7101 (rtl/nuked-md/ym7101.v), the
 * Mega Drive VDP (315-5313 / YM7101).  Generated by sim/ym7101/transform.pl.
 *
 * Same port list, same logic, same storage, same MCLK (the 107.386 MHz sampling clock,
 * md_board's MCLK2).  Every `assign`, every wire/reg declaration, every procedural always
 * block and every memory (vsram/sat/sprdata/linebuffer/color_ram/vram_*) is copied VERBATIM
 * from ym7101.v (same names, same expressions, same order).  Only the ym_lib primitive
 * instances in the module bodies are replaced by inline registered logic that produces the
 * same value at every posedge MCLK; storage regs are named <instance>_<reg> after the
 * primitive's instance and its internal register, and each primitive output wire (val/nval/
 * sr_out/data_out/next/c_out/q/nq) keeps its original net name, assigned from that storage.
 * STAGE 1 only: no register collapse (master-slave pairs stay two registers); MCLK is the clock.
 *
 * Primitive/helper census of ym7101.v and the rule applied to each (semantics = ym_lib.v as
 * sampled on MCLK, not idealised latch semantics):
 *   ym_slatch        248   mem<=en?inp:mem      -> if(en) mem<=inp; val=mem, nval=~mem
 *   ym_slatch_t        8   as ym_slatch, but val/nval read the OPEN latch value mem_assign
 *                          (en?inp:mem) -- feed-through kept explicitly
 *   ym_slatch_r        6   if(rst) mem<=0; else if(en) mem<=inp
 *   ym_dlatch_1       57   if(c1) mem<=inp; val=mem, nval=~mem
 *   ym_dlatch_2       29   if(c2) mem<=inp
 *   ym_sr_bit        322   two regs v1,v2 (each SR_LENGTH bits, 1 unless #(SR_LENGTH)):
 *                          if(c1) v1<={v2[L-2:0],bit_in}; if(c2) v2<=v1; sr_out=v2[L-1]
 *   ym_sr_bit_array   49   DATA_WIDTH parallel ym_sr_bit cells (each SR_LENGTH bits)
 *   ym_sr_bit_en      13   SR_LENGTH-bit shift register (en1 shifts data_in in, en2 recirculates)
 *                          built on a ym_sr_bit_array of SR_LENGTH 1-bit cells
 *   ym_cnt_bit         8   ym_sr_bit_array(len 1) + {sum=data_out+c_in; data_in=reset?0:sum}
 *   ym_cnt_bit_load   13   + load mux (base_val = load?load_val:data_out)
 *   ym_cnt_bit_rs      1   + set mux (data_out_s = set?~0:data_out); val=data_out_s
 *   ym_cnt_bit_rev     1   + {DATA_WIDTH{dec}} term in the sum (down/up count)
 *   ym_dbg_read        7   ym_sr_bit_array(len 1) + shift/load chain; next=data_out[0]
 *   ym7101_dff        57   module-local master-slave dff (l1<=inp while ~clk, l2<=l1 while clk,
 *                          rst clears both; outp reads the OPEN value rst?0:(clk?l1:l2)).
 *                          ALREADY in two-register posedge-MCLK form -> KEPT as module
 *                          ym7101_dff_rtl (renamed), instances retyped; l1/l2 compared as-is.
 *   ym7101_rs_trig    44   module-local rs latch (q<=set?1:(rst?0:q); nq<=rst?1:(set?0:~q)).
 *                          ALREADY posedge-MCLK -> KEPT as module ym7101_rs_trig_rtl.
 *
 * Storage is one-for-one with the die model: every v1/v2/mem inlined here maps to the die
 * primitive's internal register (see sim/ym7101/storage_manifest.txt), and the two kept
 * helper modules carry the same l1/l2 and q/nq.  The A/B bench (sim/ym7101) compares every
 * output and every one of these storage elements twice per MCLK.
 *
 * Irregular constructs reviewed by hand (see report): ym_slatch_t / ym7101_dff transparent
 * (open-latch) outputs; ym_sr_bit / ym_sr_bit_array with SR_LENGTH>1 (in-cell shift); the
 * SR_LENGTH-and-DATA_WIDTH ym_sr_bit_arrays (sr440/442/443, vdp_de_delay*); the counter
 * families' reset/set/load/dec combinational wraps.  All copied bit-for-bit from ym_lib.v.
 */
H
}
