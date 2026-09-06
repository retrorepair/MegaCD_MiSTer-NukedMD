#!/usr/bin/perl
use strict; use warnings;
my $f = "rtl/nuked-md/ym7101.v";
open(my $fh, "<", $f) or die $!;
my @lines = <$fh>; close $fh;
# known instance types
my @types = qw(ym_sr_bit_array ym_sr_bit_en ym_sr_bit ym_slatch_t ym_slatch_r ym_slatch
  ym_dlatch_1 ym_dlatch_2 ym_cnt_bit_load ym_cnt_bit_rs ym_cnt_bit_rev ym_cnt_bit
  ym_dbg_read ym7101_dff ym7101_rs_trig);
my $typere = join("|", @types);
my %count; my %examples;
my $i = 0; my $n = scalar @lines;
while ($i < $n) {
  my $line = $lines[$i];
  if ($line =~ /^\s*($typere)\b/) {
    my $type = $1;
    # accumulate until line ends with ); (ignoring trailing comment)
    my $stmt = "";
    my $j = $i;
    while ($j < $n) {
      my $l = $lines[$j];
      $stmt .= $l;
      my $stripped = $l; $stripped =~ s{//.*$}{};
      if ($stripped =~ /\);\s*$/) { last; }
      $j++;
    }
    $count{$type}++;
    push @{$examples{$type}}, $stmt if scalar(@{$examples{$type}//[]}) < 3;
    $i = $j+1;
  } else { $i++; }
}
for my $t (@types) {
  printf("=== %-18s count=%d ===\n", $t, $count{$t}//0);
  for my $ex (@{$examples{$t}//[]}) { print $ex; print "----\n"; }
}
