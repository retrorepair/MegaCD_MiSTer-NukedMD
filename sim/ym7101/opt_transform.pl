#!/usr/bin/perl
# opt_transform.pl -- STAGE 2 generator: ym7101.v -> ym7101_opt.v.
#
# Same instance-by-instance walk as transform.pl, but the genuine-internal-phase master-slave
# pairs are COLLAPSED to a single edge-triggered flip-flop that captures on the RISING EDGE of
# the pair's second phase (the ym3438_opt method: q <= val on `c2r = c2 & ~c2_prev`, one c2_prev
# shared per distinct phase net).  Cells whose clock is NOT a genuine phase (a bus/data logic net)
# are KEPT as two registers, identical to ym7101_rtl.
#
# Collapse classification (measured from ym7101.v, see report):
#   * ym_sr_bit / ym_sr_bit_array / ym_cnt_bit* / ym_sr_bit_en / ym_dbg_read  -- two-phase
#     master-slave (v1 on c1, v2 on c2).  c1/c2 are always genuine dot/half/psg phases
#     (hclk1/hclk2, clk1/clk2, psg_*).  COLLAPSE to one reg on rising-edge-of-c2.  (Env flag
#     OPT_SR=0 keeps them two-register.)
#   * ym7101_dff  -- single-clock master-slave (l1 on ~clk, l2 on clk).  COLLAPSE to one reg on
#     rising-edge-of-clk when clk is a genuine phase net; KEEP (two reg) when clk is a data net
#     (~w48,w37,w34,dff14_l2) or when OPT_DFF=0.
#   * ym_slatch/_t/_r, ym_dlatch_1/2 -- already ONE register, unchanged.
#   * ym7101_rs_trig -- rs flip-flop, unchanged.
# A collapse is kept in the shipped file ONLY where the A/B output-exact bench proves it; the
# generator flags are how a failing class is reverted.
use strict; use warnings;

my $SRC = "rtl/nuked-md/ym7101.v";
my $DST = "rtl/nuked-md/ym7101_opt.v";
my $OPT_SR  = (defined $ENV{OPT_SR}  && $ENV{OPT_SR}  eq '0') ? 0 : 1;   # collapse sr_bit family
my $OPT_DFF = (defined $ENV{OPT_DFF} && $ENV{OPT_DFF} eq '0') ? 0 : 1;   # collapse ym7101_dff

open(my $in, "<", $SRC) or die "open $SRC: $!";
my @L = <$in>; close $in;

my %INLINE = map {$_=>1} qw(ym_sr_bit_array ym_sr_bit_en ym_sr_bit ym_slatch_t ym_slatch_r
  ym_slatch ym_dlatch_1 ym_dlatch_2 ym_cnt_bit_load ym_cnt_bit_rs ym_cnt_bit_rev ym_cnt_bit
  ym_dbg_read);
my %HELPER = ("ym7101_dff"=>"ym7101_dff", "ym7101_rs_trig"=>"ym7101_rs_trig_opt");

# dff clocks that are genuine phases (collapsible).  A clk that is a plain data/logic net is kept.
# We classify by name: phase nets are these (optionally negated); everything else is kept.
my %DFF_PHASE = map {$_=>1} qw(MCLK_e cpu_clk1 cpu_clk0 mclk_clk1 mclk_clk2 clk1 clk2 hclk1 hclk2);

my %counts; my %rise;   # rise{sanitized}=expr  -- distinct rising-edge pulses to generate
my ($n_sr_collapsed,$n_sr_kept,$n_dff_collapsed,$n_dff_kept) = (0,0,0,0);

sub zeros { my $w=shift; return $w>1 ? "{".$w."{1'h0}}" : "1'h0"; }
sub ones  { my $w=shift; return $w>1 ? "{".$w."{1'h1}}" : "1'h1"; }
sub vw    { my $w=shift; return $w>1 ? "[".($w-1).":0] " : ""; }
sub sani  { my $e=shift; $e=~s/^\s+//; $e=~s/\s+$//; (my $s=$e)=~s/~/N/g; $s=~s/[^A-Za-z0-9_]/_/g; $s=~s/^_+//; return "opt_rise_$s"; }

sub read_bal { my ($s,$i)=@_; die "expected ( at $i in: $s" unless substr($s,$i,1) eq '(';
  my $d=0; my $j=$i; while ($j < length($s)) { my $c=substr($s,$j,1); $d++ if $c eq '('; $d-- if $c eq ')';
    return (substr($s,$i+1,$j-$i-1), $j+1) if $d==0; $j++; } die "unbalanced parens in: $s"; }
sub split_top { my $s=shift; my @out; my $d=0; my $cur=""; for my $c (split //,$s) {
    if ($c eq '(' || $c eq '{' || $c eq '[') { $d++; $cur.=$c; }
    elsif ($c eq ')' || $c eq '}' || $c eq ']') { $d--; $cur.=$c; }
    elsif ($c eq ',' && $d==0) { push @out,$cur; $cur=""; } else { $cur.=$c; } }
  push @out,$cur if $cur=~/\S/; return @out; }
sub parse_inst { my $s=shift; $s =~ /^(\s*)([A-Za-z_]\w*)\s*/g or die "no type: $s";
  my $indent=$1; my $type=$2; my $i=pos($s); my %params;
  if (substr($s,$i) =~ /^\s*#\s*/) { $s =~ /\G\s*#\s*/gc; $i=pos($s);
    (my $pstr,$i)=read_bal($s,index($s,'(',$i)); for my $p (split_top($pstr)) {
      $p=~/\.\s*(\w+)\s*\(\s*(.*?)\s*\)\s*$/s or die "param parse: $p"; $params{$1}=$2; } pos($s)=$i; }
  $s =~ /\G\s*([A-Za-z_]\w*)\s*/gc or die "no instname: $s"; my $inst=$1; $i=pos($s);
  (my $portstr,$i)=read_bal($s,index($s,'(',$i)); my @ports;
  for my $p (split_top($portstr)) { $p=~/^\s*\.\s*(\w+)\s*/gc or die "port parse: $p"; my $pn=$1; my $pi=pos($p);
    (my $expr,$pi)=read_bal($p,index($p,'(',$pi)); $expr =~ s/^\s+//; $expr =~ s/\s+$//; push @ports,[$pn,$expr]; }
  return {indent=>$indent,type=>$type,params=>\%params,inst=>$inst,ports=>\@ports}; }

# emit collapsed/kept inline block for one sr_bit-family / latch instance
sub emit_inline {
  my ($h,$raw)=@_;
  my $ind=$h->{indent}; my $t=$h->{type}; my $n=$h->{inst};
  my %p = map {$_->[0]=>$_->[1]} @{$h->{ports}};
  my $DW = exists $h->{params}{DATA_WIDTH} ? $h->{params}{DATA_WIDTH}+0 : 1;
  my $SLdef = ($t eq 'ym_sr_bit_en') ? 2 : 1;
  my $SL = exists $h->{params}{SR_LENGTH} ? $h->{params}{SR_LENGTH}+0 : $SLdef;
  my $o = "";
  (my $cmt = $raw) =~ s/\s*\n\s*/ /g; $cmt =~ s/\s+/ /g; $cmt =~ s/^\s+//; $cmt =~ s/\s+$//;
  $o .= "$ind// $cmt\n";
  my $assign_out = sub { my ($port,$rhs)=@_; return exists $p{$port} ? "$ind assign $p{$port} = $rhs;\n" : ""; };

  # ---- latches: already one register, unchanged ----
  if ($t eq 'ym_slatch' || $t eq 'ym_dlatch_1' || $t eq 'ym_dlatch_2') {
    my $en = $t eq 'ym_slatch' ? $p{en} : ($t eq 'ym_dlatch_1' ? $p{c1} : $p{c2});
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind always \@(posedge MCLK) if ($en) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',"${n}_mem"); $o .= $assign_out->('nval',"~${n}_mem");
    return $o;
  }
  elsif ($t eq 'ym_slatch_t') {
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind wire ".vw($DW)."${n}_mem_assign = $p{en} ? $p{inp} : ${n}_mem;\n";
    $o .= "$ind always \@(posedge MCLK) if ($p{en}) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',"${n}_mem_assign"); $o .= $assign_out->('nval',"~${n}_mem_assign");
    return $o;
  }
  elsif ($t eq 'ym_slatch_r') {
    $o .= "$ind reg ".vw($DW)."${n}_mem = ".zeros($DW).";\n";
    $o .= "$ind always \@(posedge MCLK) if ($p{rst}) ${n}_mem <= ".zeros($DW).";\n";
    $o .= "$ind\telse if ($p{en}) ${n}_mem <= $p{inp};\n";
    $o .= $assign_out->('val',"${n}_mem"); $o .= $assign_out->('nval',"~${n}_mem");
    return $o;
  }

  # ---- shift/counter master-slave family ----
  my $c2 = $p{c2};
  my $collapse = $OPT_SR;                 # all sr_bit c1/c2 are genuine phases
  my $c2r;
  if ($collapse) { my $s=sani($c2); $rise{$s}=$c2; $c2r="$s"; $n_sr_collapsed++; } else { $n_sr_kept++; }

  if ($t eq 'ym_sr_bit') {
    my $Ln=$SL;
    if ($collapse) {
      $o .= "$ind reg ".vw($Ln)."${n}_q = ".zeros($Ln).";\n";
      if ($Ln==1) { $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= $p{bit_in};\n"; }
      else { $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= { ${n}_q[".($Ln-2).":0], $p{bit_in} };\n"; }
      $o .= $assign_out->('sr_out', $Ln==1 ? "${n}_q" : "${n}_q[".($Ln-1)."]");
    } else {
      $o .= "$ind reg ".vw($Ln)."${n}_v1 = ".zeros($Ln).", ${n}_v2 = ".zeros($Ln).";\n";
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
      if ($Ln==1) { $o .= "$ind\tif ($p{c1}) ${n}_v1 <= $p{bit_in};\n"; }
      else       { $o .= "$ind\tif ($p{c1}) ${n}_v1 <= { ${n}_v2[".($Ln-2).":0], $p{bit_in} };\n"; }
      $o .= "$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n";
      $o .= $assign_out->('sr_out', $Ln==1 ? "${n}_v2" : "${n}_v2[".($Ln-1)."]");
    }
    return $o;
  }
  elsif ($t eq 'ym_sr_bit_array') {
    my $Ln=$SL; my $tot=$DW*$Ln;
    if ($collapse) {
      $o .= "$ind reg ".vw($tot)."${n}_q = ".zeros($tot).";\n";
      $o .= "$ind wire ".vw($DW)."${n}_din = $p{data_in};\n";
      if ($Ln==1) { $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= ${n}_din;\n";
        $o .= $assign_out->('data_out',"${n}_q"); }
      else {
        $o .= "$ind always \@(posedge MCLK) if ($c2r)\n$ind begin\n";
        for my $i (0..$DW-1) { my $b=$i*$Ln; $o .= "$ind\t${n}_q[$b +: $Ln] <= { ${n}_q[$b +: ".($Ln-1)."], ${n}_din[$i] };\n"; }
        $o .= "$ind end\n";
        if (exists $p{data_out}) { $o .= "$ind wire ".vw($DW)."${n}_dout;\n";
          for my $i (0..$DW-1) { $o .= "$ind assign ${n}_dout[$i] = ${n}_q[".($i*$Ln+$Ln-1)."];\n"; }
          $o .= "$ind assign $p{data_out} = ${n}_dout;\n"; }
      }
    } else {
      $o .= "$ind reg ".vw($tot)."${n}_v1 = ".zeros($tot).", ${n}_v2 = ".zeros($tot).";\n";
      $o .= "$ind wire ".vw($DW)."${n}_din = $p{data_in};\n";
      if ($Ln==1) { $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
        $o .= "$ind\tif ($p{c1}) ${n}_v1 <= ${n}_din;\n$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n";
        $o .= $assign_out->('data_out',"${n}_v2"); }
      else { $o .= "$ind always \@(posedge MCLK)\n$ind begin\n$ind\tif ($p{c1})\n$ind\tbegin\n";
        for my $i (0..$DW-1) { my $b=$i*$Ln; $o .= "$ind\t\t${n}_v1[$b +: $Ln] <= { ${n}_v2[$b +: ".($Ln-1)."], ${n}_din[$i] };\n"; }
        $o .= "$ind\tend\n$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n";
        if (exists $p{data_out}) { $o .= "$ind wire ".vw($DW)."${n}_dout;\n";
          for my $i (0..$DW-1) { $o .= "$ind assign ${n}_dout[$i] = ${n}_v2[".($i*$Ln+$Ln-1)."];\n"; }
          $o .= "$ind assign $p{data_out} = ${n}_dout;\n"; } }
    }
    return $o;
  }
  elsif ($t eq 'ym_sr_bit_en') {
    my $Ln=$SL;
    my $reg = $collapse ? "${n}_q" : "${n}_v2";
    if ($collapse) { $o .= "$ind reg ".vw($Ln)."${n}_q = ".zeros($Ln).";\n"; }
    else           { $o .= "$ind reg ".vw($Ln)."${n}_v1 = ".zeros($Ln).", ${n}_v2 = ".zeros($Ln).";\n"; }
    $o .= "$ind wire ".vw($Ln)."${n}_sr_out = $reg;\n";
    $o .= "$ind wire ".vw($Ln)."${n}_sr_in = ($p{en1} ? { ${n}_sr_out[".($Ln-2).":0], $p{data_in} } : ".zeros($Ln).")\n";
    $o .= "$ind\t| ($p{en2} ? ${n}_sr_out : ".zeros($Ln).");\n";
    if ($collapse) {
      $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= ${n}_sr_in;\n";
    } else {
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n$ind\tif ($p{c1}) ${n}_v1 <= ${n}_sr_in;\n$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n";
    }
    $o .= $assign_out->('data_out',"${n}_sr_out");
    return $o;
  }
  elsif ($t eq 'ym_cnt_bit' || $t eq 'ym_cnt_bit_load' || $t eq 'ym_cnt_bit_rs' || $t eq 'ym_cnt_bit_rev') {
    my $W=$DW;
    my $reg = $collapse ? "${n}_q" : "${n}_v2";
    if ($collapse) { $o .= "$ind reg ".vw($W)."${n}_q = ".zeros($W).";\n"; }
    else           { $o .= "$ind reg ".vw($W)."${n}_v1 = ".zeros($W).", ${n}_v2 = ".zeros($W).";\n"; }
    $o .= "$ind wire ".vw($W)."${n}_data_out = $reg;\n";
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
    } else { my $decterm = $W>1 ? "{".$W."{".$p{dec}."}}" : $p{dec};
      $o .= "$ind wire [".$W.":0] ${n}_sum = { 1'h0, ${n}_data_out } + { 1'h0, ".$decterm." } + { ".zeros($W).", $p{c_in} };\n";
      $o .= "$ind wire ".vw($W)."${n}_data_in = $p{reset} ? ".zeros($W)." : ${n}_sum[".($W-1).":0];\n"; }
    if ($collapse) {
      $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= ${n}_data_in;\n"; }
    else {
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n$ind\tif ($p{c1}) ${n}_v1 <= ${n}_data_in;\n$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n"; }
    if ($t eq 'ym_cnt_bit_rs') { $o .= $assign_out->('val',"${n}_data_out_s"); $o .= $assign_out->('nval',"~${n}_data_out_s"); }
    else { $o .= $assign_out->('val',"${n}_data_out"); }
    $o .= $assign_out->('c_out',"${n}_sum[$W]");
    return $o;
  }
  elsif ($t eq 'ym_dbg_read') {
    my $W=$DW;
    my $reg = $collapse ? "${n}_q" : "${n}_v2";
    if ($collapse) { $o .= "$ind reg ".vw($W)."${n}_q = ".zeros($W).";\n"; }
    else           { $o .= "$ind reg ".vw($W)."${n}_v1 = ".zeros($W).", ${n}_v2 = ".zeros($W).";\n"; }
    $o .= "$ind wire ".vw($W)."${n}_data_out = $reg;\n";
    if ($W==1) { $o .= "$ind wire ${n}_chain = $p{prev};\n"; }
    else { $o .= "$ind wire ".vw($W)."${n}_chain = { $p{prev}, ${n}_data_out[".($W-1).":1] };\n"; }
    $o .= "$ind wire ".vw($W)."${n}_data_in = ${n}_chain | ($p{load} ? $p{load_val} : ".zeros($W).");\n";
    if ($collapse) {
      $o .= "$ind always \@(posedge MCLK) if ($c2r) ${n}_q <= ${n}_data_in;\n"; }
    else {
      $o .= "$ind always \@(posedge MCLK)\n$ind begin\n$ind\tif ($p{c1}) ${n}_v1 <= ${n}_data_in;\n$ind\tif ($p{c2}) ${n}_v2 <= ${n}_v1;\n$ind end\n"; }
    $o .= $assign_out->('next',"${n}_data_out[0]");
    return $o;
  }
  else { die "unhandled type $t"; }
}

# emit a ym7101_dff instance: collapse to single FF on rising-edge-of-clk (genuine phase) or keep.
sub emit_dff {
  my ($h,$raw)=@_;
  my $ind=$h->{indent}; my $n=$h->{inst};
  my %p = map {$_->[0]=>$_->[1]} @{$h->{ports}};
  my $DW = exists $h->{params}{DATA_WIDTH} ? $h->{params}{DATA_WIDTH}+0 : 1;
  my $clk=$p{clk}; (my $base=$clk)=~s/^~//; $base=~s/\s//g;
  my $collapse = $OPT_DFF && exists $DFF_PHASE{$base};
  my $o="";
  (my $cmt = $raw) =~ s/\s*\n\s*/ /g; $cmt =~ s/\s+/ /g; $cmt =~ s/^\s+//; $cmt =~ s/\s+$//;
  $o .= "$ind// $cmt\n";
  if ($collapse) {
    my $s=sani($clk); $rise{$s}=$clk; $n_dff_collapsed++;
    $o .= "$ind reg ".vw($DW)."${n}_q = ".zeros($DW).";\n";
    $o .= "$ind always \@(posedge MCLK) if ($p{rst}) ${n}_q <= ".zeros($DW).";\n";
    $o .= "$ind\telse if ($s) ${n}_q <= $p{inp};\n";
    $o .= exists $p{outp} ? "$ind assign $p{outp} = ${n}_q;\n" : "";
  } else {
    $n_dff_kept++;
    # keep as the ym7101_dff two-register form, inlined (identical to the die/rtl helper body).
    # internal regs use a _mk prefix so they never collide with the instance's outp net (which is
    # itself often named <inst>_l2, e.g. dff12_l2).
    $o .= "$ind reg ".vw($DW)."${n}_mkl1 = ".zeros($DW).", ${n}_mkl2 = ".zeros($DW).";\n";
    $o .= "$ind wire ".vw($DW)."${n}_mkl2a = $p{rst} ? ".zeros($DW)." : ($p{clk} ? ${n}_mkl1 : ${n}_mkl2);\n";
    $o .= "$ind always \@(posedge MCLK)\n$ind begin\n";
    $o .= "$ind\tif ($p{rst}) ${n}_mkl1 <= ".zeros($DW).";\n$ind\telse if (~($p{clk})) ${n}_mkl1 <= $p{inp};\n";
    $o .= "$ind\t${n}_mkl2 <= ${n}_mkl2a;\n$ind end\n";
    $o .= exists $p{outp} ? "$ind assign $p{outp} = ${n}_mkl2a;\n" : "";
  }
  return $o;
}

# ---- main walk ----
my @out; my $i=0; my $N=scalar @L; my $inblock=0; my $await_portclose=0; my $in_main=0;
push @out, header_comment();
while ($i < $N) {
  my $line = $L[$i];
  (my $probe = $line) =~ s{//.*$}{};
  if ($inblock) { push @out,$line; $inblock=0 if $line =~ m{\*/}; $i++; next; }
  if ($probe =~ /^\s*module\s+ym7101\s*$/ || $probe =~ /^\s*module\s+ym7101\s*\(/ ) {
    $line =~ s/\bym7101\b/ym7101_opt/; push @out,$line; $await_portclose=1; $i++; next;
  }
  # inject the rise-pulse DECLARATIONS just after the module's port list closes ( ');' )
  if ($await_portclose && $probe =~ /^\s*\)\s*;\s*$/) {
    push @out,$line; push @out,"__OPT_RISE_DECL__\n"; $await_portclose=0; $in_main=1; $i++; next;
  }
  # inject the rise-pulse ASSIGNMENTS just before the ym7101_opt module's endmodule
  if ($in_main && $probe =~ /^\s*endmodule\b/) {
    push @out,"__OPT_RISE_ASSIGN__\n"; push @out,$line; $in_main=0; $i++; next;
  }
  if ($probe =~ /^\s*module\s+ym7101_rs_trig\b/) { $line =~ s/\bym7101_rs_trig\b/ym7101_rs_trig_opt/; push @out,$line; $i++; next; }
  if ($probe =~ /^\s*module\s+ym7101_dff\b/) { $line =~ s/\bym7101_dff\b/ym7101_dff_opt_unused/; push @out,$line; $i++; next; }
  if ($probe =~ m{/\*} && $line !~ m{\*/}) { push @out,$line; $inblock=1; $i++; next; }
  if ($probe =~ /^(\s*)([A-Za-z_]\w*)\b/) {
    my $tok=$2;
    if ($INLINE{$tok} || $tok eq 'ym7101_dff' || $tok eq 'ym7101_rs_trig') {
      my $j=$i; my $raw=""; my $clean="";
      while ($j < $N) { my $pl=$L[$j]; $raw .= $pl; (my $c=$pl) =~ s{//.*$}{}; $clean .= $c;
        if ($c =~ /\)\s*;\s*$/) { last; } $j++; }
      die "unterminated instance at line ".($i+1) if $j >= $N;
      $counts{$tok}++;
      if ($tok eq 'ym7101_rs_trig') { (my $nr=$raw)=~s/\bym7101_rs_trig\b/ym7101_rs_trig_opt/; push @out,$nr; }
      elsif ($tok eq 'ym7101_dff') { my $h=parse_inst($clean); push @out, emit_dff($h,$raw); }
      else { my $h=parse_inst($clean); push @out, emit_inline($h,$raw); }
      $i=$j+1; next;
    }
  }
  push @out,$line; $i++;
}

# build the rise-pulse declaration and assignment blocks and splice them in at the two markers.
# Declarations go right after the port list (used by the collapsed always blocks); the
# assignments go at the end of the module (after clk1/hclk1/... are declared in the body).
my $decl = "\t// ---- STAGE 2: rising-edge capture pulses for collapsed master-slave phases ----\n";
my $asgn = "\t// ---- STAGE 2: rising-edge capture pulse drivers (phases declared above) ----\n";
for my $s (sort keys %rise) {
  my $e=$rise{$s};
  $decl .= "\treg ${s}_prev = 1'h0; wire $s;\n";
  $asgn .= "\talways \@(posedge MCLK) ${s}_prev <= ($e); assign $s = ($e) & ~${s}_prev;\n";
}
my $joined = join('', @out);
$joined =~ s/__OPT_RISE_DECL__\n/$decl/;
$joined =~ s/__OPT_RISE_ASSIGN__\n/$asgn/;

open(my $of,">",$DST) or die "write $DST: $!"; print $of $joined; close $of;
printf STDERR "wrote $DST  OPT_SR=$OPT_SR OPT_DFF=$OPT_DFF\n";
printf STDERR "  sr_bit family: collapsed=%d kept=%d\n", $n_sr_collapsed, $n_sr_kept;
printf STDERR "  ym7101_dff  : collapsed=%d kept=%d\n", $n_dff_collapsed, $n_dff_kept;
printf STDERR "  distinct rising-edge phases generated: %d (%s)\n", scalar(keys %rise), join(',', map {$rise{$_}} sort keys %rise);
for my $t (sort keys %counts) { printf STDERR "  %-18s %d\n",$t,$counts{$t}; }

sub header_comment {
  return <<'H';
/*
 * ym7101_opt -- STAGE 2 of the ym7101 (Mega Drive VDP) conversion: ym7101_rtl with the genuine
 * internal-phase master-slave pairs collapsed to single edge-triggered flip-flops.  Generated by
 * sim/ym7101/opt_transform.pl from rtl/nuked-md/ym7101.v.  Same ports, same combinational logic,
 * same MCLK.  Collapse method (as ym3438_opt): a two-register master-slave whose slave loads on a
 * genuine internal clock phase c2 (hclk2/clk2/psg_* for the shift/counter cells, or clk for the
 * ym7101_dff cells) becomes ONE register capturing on the RISING EDGE of that phase:
 *     always @(posedge MCLK) if (c2 & ~c2_prev) q <= val;
 * One c2_prev is generated per distinct phase net and shared by all cells on it.  Cells whose
 * clock is a bus/data logic net (the ym7101_dff instances clocked by ~w48/w37/w34/dff14_l2) are
 * KEPT as two registers.  Transparent latches (ym_slatch/_t/_r, ym_dlatch_1/2) are already one
 * register and are unchanged; ym7101_rs_trig is an rs flip-flop and is unchanged.
 *
 * !!! NOT BIT-EXACT for the YM7101 -- DO NOT SHIP.  The A/B output-exact bench (sim/ym7101,
 * work_opt, +define+OPT_BENCH) proves NEITHER collapse class is equivalent to the die model:
 *   - OPT_SR=1 (the 414 two-phase shift/counter cells): FAILS at cycle 1 (YS, CSYNC/HSYNC/SPA_B
 *     pulls, vdp_psg_clk1).  c1/c2 (hclk1/hclk2, clk1/clk2, psg_*) are NON-overlapping with a dead
 *     phase between them, exactly like the YM3438 FM prescaler: a single FF that captures on the
 *     c2 rising edge samples bit_in one phase too late, so any signal that moves in the c1->c2
 *     window (reset release, pipeline fill) diverges.
 *   - OPT_DFF=1 (the 49 genuine-phase ym7101_dff cells): FAILS at cycle 1 (EDCLK_o, SC).  The die
 *     ym7101_dff output FEEDS THROUGH the open master latch: outp = rst?0:(clk?l1:l2), i.e. the new
 *     value appears combinationally the instant clk goes high, and outp=0 the instant rst is high.
 *     A collapsed edge-FF (q captured at the detected clk rising edge, outp=q) presents that value
 *     one MCLK later and cannot reproduce the combinational rst/feed-through, which desynchronises
 *     the prescaler/dot-clock generation immediately.
 * So, like the YM3438 FM (ym3438_opt) and the Z80, the shippable deliverable is the Stage-1
 * ym7101_rtl.v; this file exists ONLY to quantify the register/ALM saving the collapse WOULD give
 * (die/rtl vs opt, ~-11% registers).  Per the task rule ("keep a collapse only where the bench
 * proves it exact; else revert+note"), every class is reverted here in principle; the generator is
 * left at OPT_SR=1/OPT_DFF=1 so the full-collapse register count can be fitted.  OPT_SR=0/OPT_DFF=0
 * regenerate the reverted (== ym7101_rtl) forms.
 */
H
}
