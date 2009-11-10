#!/gsc/bin/perl
#Create a BreakDancer configuration file from a set of bam files

use strict;
use warnings;
use Getopt::Std;
use Statistics::Descriptive;
use GD::Graph::histogram;
use lib '.';
use AlnParser;

my %opts = (q=>35, n=>10000, v=>1, c=>4, s=>50);
getopts('q:n:c:p:hmf:', \%opts);
die("
Usage:   bam2cfg.pl <bam files>
Options:
         -q INT    minimum mapping quality [$opts{q}]
         -m        Using mapping quality instead of alternative mapping quality
         -s        minimal mean insert size [$opts{s}]
         -c FLOAT  cutoff in unit of standard deviation [$opts{c}]
         -n INT    number of observation required to estimate mean and s.d. insert size [$opts{n}]
         -v FLOAT  cutoff on coefficients of variation [$opts{v}]
         -f STRING a two column tab-delimited text file (RG, LIB) specify the RG=>LIB mapping, useful when BAM header is incomplete
         -h        Output histogram image for each BAM library
\n
") unless (@ARGV);

my $AP=new AlnParser();

my %cRGlib; my %clibs;
if($opts{f}){
  open(RGLIB,"<$opts{f}") || die "unable to open $opts{f}\n";
  while(<RGLIB>){
    chomp;
    my ($rg,$lib)=split;
    $clibs{$lib}=1;
    $cRGlib{$rg}=$lib;
  }
}

foreach my $fbam(@ARGV){
  my %RGlib;
  my %libs;
  my %insert_stat;
  my %readlen_stat;
  my %libpos;
  my $recordcounter=0;
  my $expected_max;
  if(defined $opts{f}){
    %RGlib=%cRGlib;
    %libs=%clibs;
  }
  open(BAM,"samtools view -h $fbam |") || die "unable to open $fbam\n";
  while(<BAM>){
    chomp;
    if(/^\@RG/){  #getting RG=>LIB mapping from the bam header
      my ($id)=($_=~/ID\:(\S+)/);
      my ($lib)=($_=~/LB\:(\S+)/);
      my ($sample)=($_=~/SM\:(\S+)/);
      my ($insertsize)=($_=~/PI\:(\d+)/);
      #if(defined $insertsize && $insertsize>0){
	#$lib=$sample . '_'. $lib;
	$libs{$lib}=1;
	$RGlib{$id}=$lib;
      #}
    }
    else{
      next if(/^\@/);
      my @libas=keys %libs;
      if(!defined $expected_max){
	$expected_max=3*($#libas+1)*$opts{n};
      }
      my @selected_libs=keys %insert_stat;
      if($#libas<0){ 
	if($#selected_libs>=0){
	  last;
	}
	else{
	  $libs{'NA'}=1;
	  $RGlib{'NA'}='NA';
	}
      }
      last if($recordcounter>$expected_max);

      my $t=$AP->in($_,'sam',$opts{m});

      my $lib=($t->{readgroup})?$RGlib{$t->{readgroup}}:'NA';  #when multiple libraries are in a BAM file
      next unless(defined $lib && $libs{$lib});
      $readlen_stat{$lib}=Statistics::Descriptive::Full->new() if(!defined $readlen_stat{$lib});
      $readlen_stat{$lib}->add_data($t->{readlen});
      next if ($t->{qual}<=$opts{q});  #skip low quality mapped reads
      $recordcounter++;
      $libpos{$lib}++;
      my $nreads=(defined $insert_stat{$lib})?$insert_stat{$lib}->count():1;
      if($nreads/$libpos{$lib}<1e-4){  #single-end lane
	delete $libs{$lib};
	delete $insert_stat{$lib};
      }
      next unless(($t->{flag}==18) && $t->{dist}>=0);
      $insert_stat{$lib}=Statistics::Descriptive::Full->new() if(!defined $insert_stat{$lib});
      $insert_stat{$lib}->add_data($t->{dist});
      if($insert_stat{$lib}->count()>$opts{n}){
	delete $libs{$lib};
      }
    }
  }
  close(BAM);

  my %stdms;
  my %stdps;

  foreach my $lib(keys %insert_stat){
    my $readlen=$readlen_stat{$lib}->mean();
    my @isize=$insert_stat{$lib}->get_data();
    my $mean=$insert_stat{$lib}->mean();
    my $std=$insert_stat{$lib}->standard_deviation();

    delete $insert_stat{$lib};
    my $insertsize=Statistics::Descriptive::Full->new();
    foreach my $x(@isize){
      next if($x>$mean+5*$std);
      $insertsize->add_data($x);
    }

    $mean=$insertsize->mean();
    $std=$insertsize->standard_deviation();
    next if($mean<$opts{s});
    my $cv=$std/$mean;
    next if($cv>=$opts{v});

    my $num=$insertsize->count();
    next if($num<100);

    my ($stdm,$stdp)=(0,0);
    my ($nstdm,$nstdp)=(0,0);
    foreach my $x($insertsize->get_data()){
      if($x>$mean){
	$stdp+=($x-$mean)**2;
	$nstdp++;
      }
      else{
	$stdm+=($x-$mean)**2;
	$nstdm++;
      }
    }
    $stdm=sqrt($stdm/($nstdm-1));
    $stdp=sqrt($stdp/($nstdp-1));

    $stdms{$lib}=$stdm;
    $stdps{$lib}=$stdp;
    $insert_stat{$lib}=$insertsize;
  }

  foreach my $rg(keys %RGlib){
    my $lib=$RGlib{$rg};
    next unless($insert_stat{$lib});
    my $readlen=$readlen_stat{$lib}->mean();
    my $mean=$insert_stat{$lib}->mean();
    my $std=$insert_stat{$lib}->standard_deviation();
    my $num=$insert_stat{$lib}->count();

    my $upper=$mean+$opts{c}*$stdps{$lib} if(defined $opts{c});
    my $lower=$mean-$opts{c}*$stdms{$lib} if(defined $opts{c});
    $lower=0 if(defined $lower && $lower<0);

    printf "readgroup\:%s\tmap\:%s\treadlen\:%.2f\tlib\:%s\tnum:%d",$rg,$fbam,$readlen,$lib,$num;
    printf "\tlower\:%.2f\tupper\:%.2f",$lower,$upper if(defined $upper && defined $lower);
    printf "\tmean\:%.2f\tstd\:%.2f\texe:samtools view\n",$mean,$std;
  }

  if($opts{h}){  #plot insert size histogram for each library
    foreach my $lib(keys %insert_stat){
      my $graph = new GD::Graph::histogram(1000,600);
      my $library="$fbam.$lib";
      $graph->set(
		  x_label         => 'X Label',
		  y_label         => 'Count',
		  title           => $library,
		  x_labels_vertical => 1,
		  bar_spacing     => 0,
		  shadow_depth    => 1,
		  shadowclr       => 'dred',
		  transparent     => 0,
		  histogram_bins   => $insert_stat{$lib}->max(),
		 ) or warn $graph->error;
      my @data=$insert_stat{$lib}->get_data();
      my $gd = $graph->plot(\@data) or die $graph->error;

      $library=~s/.*\///g;
      my $imagefile="$library.insertsize_histogram.png";
      open(IMG, ">$imagefile") or die $!;
      binmode IMG;
      print IMG $gd->png;

      my $datafile="$library.insertsize_histogram";
      open(OUT,">$datafile");
      foreach my $x(@data){
	print OUT "$x\n";
      }
      close(OUT);
    }
  }
}