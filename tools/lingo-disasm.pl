#!/usr/bin/perl
# Minimal disassembler for Director 5/6 compiled Lingo (Lscr chunks) in big-endian RIFX .dir/.cst files.
# Usage: perl lingo-disasm.pl <file.cst|file.dir> [handler-name-regex]
use strict; my ($file,$filter)=@ARGV;
open F,'<:raw',$file or die; local $/; my $d=<F>; close F;
# mmap
my $mo=unpack('N',substr($d,0x18,4)); # imap -> mmap offset
my $mm=$mo+8; my ($hs,$es,$max,$used)=unpack('nnNN',substr($d,$mm,12));
my @ch; for my $i(0..$used-1){ my $e=$mm+$hs+$i*$es; my($tag,$len,$off)=unpack('a4NN',substr($d,$e,12)); push @ch,[$tag,$len,$off,$i]; }
my @nam; for(@ch){ next unless $_->[0] eq 'Lnam'; my $o=$_->[2]+8; my($no,$nc)=unpack('nn',substr($d,$o+16,4)); my $p=$o+$no; for(1..$nc){my $l=ord substr($d,$p,1); push @nam,substr($d,$p+1,$l); $p+=$l+1;} print "Lnam chunk #$_->[3] names=$nc\n"; }
my %op=(1,'ret',3,'push0',4,'mul',5,'add',6,'sub',7,'div',8,'mod',9,'inv',0xa,'joinstr',0xb,'joinpadstr',0xc,'lt',0xd,'lteq',0xe,'nteq',0xf,'eq',0x10,'gt',0x11,'gteq',0x12,'and',0x13,'or',0x14,'not',0x15,'containsstr',0x16,'contains0str',0x17,'getchunk',0x18,'hilitechunk',0x1a,'putchunk',0x1b,'deletechunk',0x1c,'get',0x1d,'set',0x1e,'getmovieprop',0x1f,'setmovieprop',
0x41,'pushint',0x42,'pusharglistnoret',0x43,'pusharglist',0x44,'pushcons',0x45,'pushsymb',0x46,'pushvarref',0x48,'getglobal2',0x49,'getglobal',0x4a,'getprop',0x4b,'getparam',0x4c,'getlocal',0x4e,'setglobal2',0x4f,'setglobal',0x50,'setprop',0x51,'setparam',0x52,'setlocal',0x53,'jmp',0x54,'endrepeat',0x55,'jmpifz',0x56,'localcall',0x57,'extcall',0x58,'objcallv4',0x59,'put',0x5a,'putchunk',0x5b,'deletechunk',0x5c,'theentity',0x5d,'setentity',0x5f,'getchainedprop',0x60,'settopmost',0x61,'getobjprop',0x62,'setobjprop',0x63,'tellcall',0x64,'peek',0x65,'pop',0x66,'thebuiltin',0x67,'objcall',0x6d,'pushchunkvarref',0x6e,'pushint16',0x6f,'pushint32');
my %nameop=map{$_=>1}(0x45,0x46,0x48,0x49,0x4a,0x4e,0x4f,0x50,0x57,0x5f,0x61,0x62,0x66,0x67);
for my $c(@ch){ next unless $c->[0] eq 'Lscr'; my $o=$c->[2]+8; my $s=substr($d,$o,$c->[1]);
  my($hc,$ho)=unpack('nN',substr($s,72,6));
  for my $h(0..$hc-1){ my $r=substr($s,$ho+$h*42,42); my($nid,$vp,$cl,$co,$ac,$ao,$lc,$lo,$gc,$go)=unpack('nnNNnNnNnN',$r);
    my $hn=$nam[$nid]//"?$nid"; next if $filter && $hn!~/$filter/i;
    my @args=map{$nam[$_]}unpack('n*',substr($s,$ao,2*$ac)); my @loc=map{$nam[$_]}unpack('n*',substr($s,$lo,2*$lc)); my @gl=map{$nam[$_]}unpack('n*',substr($s,$go,2*$gc));
    print "== Lscr#$c->[3] on $hn (@args) locals(@loc) globals(@gl)\n";
    my $p=$co; while($p<$co+$cl){ my $b=ord substr($s,$p,1); my $at=$p-$co; my($arg,$n)=(undef,1);
      if($b>=0xc0){$arg=unpack('N',substr($s,$p+1,4));$n=5}elsif($b>=0x80){$arg=unpack('n',substr($s,$p+1,2));$n=3}elsif($b>=0x40){$arg=ord substr($s,$p+1,1);$n=2}
      my $base=$b>=0x40?(($b&0x3f)|0x40):$b; my $nm=$op{$base}//sprintf('op%02x',$b);
      my $extra=''; if(defined $arg){ $extra=" $arg"; $extra.=" [$nam[$arg]]" if $nameop{$base}; $extra.=" [".($args[$arg/6]//'')."]" if $base==0x4b||$base==0x51; $extra.=" [".($loc[$arg/6]//'')."]" if $base==0x4c||$base==0x52;}
      printf "  %4d %02x %s%s\n",$at,$b,$nm,$extra; $p+=$n; } } }
