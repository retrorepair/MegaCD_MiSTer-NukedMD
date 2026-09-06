#!/usr/bin/perl
# Sum register bits declared in a module line-range (numeric widths); skip comments.
use strict; use warnings;
my ($path,$start,$end)=@ARGV;
open(my $f,"<",$path) or die $!;
my @l=<$f>; close $f;
my $text=join('', @l[$start-1..$end-1]);
$text =~ s{/\*.*?\*/}{}gs;
my $total=0; my %d;
for my $raw (split /\n/,$text) {
  (my $line=$raw) =~ s{//.*$}{};
  next unless $line =~ /^\s*reg\b(.*)/;
  my $rest=$1; $rest =~ s/;\s*$//;
  my ($width,$names);
  if ($rest =~ /^\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*(.*)/) { $width=abs($1-$2)+1; $names=$3; }
  else { $width=1; $names=$rest; }
  for my $decl (split /,/,$names) {
    $decl =~ s/=.*$//; $decl =~ s/^\s+//; $decl =~ s/\s+$//;
    next unless $decl =~ /^([A-Za-z_]\w*)/;
    my $nm=$1;
    my $arr=1; $arr=abs($1-$2)+1 if $decl =~ /\[\s*(\d+)\s*:\s*(\d+)\s*\]/;
    my $bits=$width*$arr; $total+=$bits; $d{$nm}=$bits;
  }
}
my @big = sort { $d{$b} <=> $d{$a} } keys %d;
printf "%s lines %d..%d: %d reg bits (%d decls)\n", $path,$start,$end,$total,scalar(keys %d);
printf "  largest: %s\n", join(', ', map {"$_=$d{$_}"} @big[0..7]);
