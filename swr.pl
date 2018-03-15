#!/usr/bin/perl
package SWR;

use strict;
use warnings;

use Moo;
use CLI::Osprey
  desc => "SWR meter";

use Time::Progress;

my @BANDS = (
  { name => '160m', start => 1800000,  end => 2000000,  tags => ['mf'] },
  { name => '80m',  start => 3500000,  end => 4000000,  tags => ['hf'] },
  { name => '60m',  start => 5300000,  end => 5500000,  tags => ['hf'] },
  { name => '40m',  start => 7000000,  end => 7300000,  tags => ['hf'] },
  { name => '30m',  start => 10100000, end => 10150000, tags => ['hf', 'warc'] },
  { name => '20m',  start => 14000000, end => 14350000, tags => ['hf'] },
  { name => '17m',  start => 18068000, end => 18168000, tags => ['hf', 'warc'] },
  { name => '15m',  start => 21000000, end => 21450000, tags => ['hf'] },
  { name => '12m',  start => 24890000, end => 24990000, tags => ['hf', 'warc'] },
  { name => '10m',  start => 28000000, end => 29700000, tags => ['hf'] },
  { name => '6m',   start => 50000000, end => 54000000, tags => ['vhf'] },
);

option 'start' => (
  is => 'ro',
  format => 'f',
  doc => 'Starting frequency',
  forrmat_doc => 'kHz',
  default => 1700,
);

has 'start_hz' => (
  is => 'lazy',
  default => sub { int(shift->start * 1000 + 0.5) }
);

option 'end' => (
  is => 'ro',
  format => 'f',
  doc => 'Ending frequency',
  format_doc => 'kHz',
  default => 54000,
);

has 'end_hz' => (
  is => 'lazy',
  default => sub { int(shift->end * 1000 + 0.5) }
);

option 'step' => (
  is => 'ro',
  format => 'f',
  doc => 'Frequency step',
  format_doc => 'kHz',
  spacer_below => 1,
  default => 10,
);

has 'step_hz' => (
  is => 'lazy',
  default => sub { int(shift->step * 1000 + 0.5) }
);

option 'bands' => (
  is => 'ro',
  doc => 'Highlight amateur bands',
  default => 1,
  negatable => 1,
);

option 'warc' => (
  is => 'ro',
  doc => 'Include WARC bands',
  default => 1,
  negatable => 1,
  spacer_below => 1,
);

option 'width' => (
  is => 'ro',
  doc => 'Graph width',
  format => 'i',
  default => 1280,
);

option 'height' => (
  is => 'ro',
  doc => 'Graph height',
  format => 'i',
  default => 720,
);

option 'font' => (
  is => 'ro',
  doc =>  'Font',
  format => 's',
  default => 'sans,16',
);

option 'threshold' => (
  is => 'ro',
  doc => 'Plot horizontal lines',
  format => 'f',
  format_doc => 'SWR',
  repeatable =>  1,
  spacer_below => 1,
  default => sub { [2, 3] },
);

option 'maxswr' => (
  is => 'ro',
  doc => 'Maximum SWR for top of graph',
  format => 'f',
  format_doc =>'SWR',
);

option 'smooth' => (
  is => 'ro',
  doc => 'Smoothing',
  format => 's',
  spacer_below => 1,
);

option 'portname' => (
  is => 'ro',
  doc => 'Serial port to use',
  option => 'port',
  short => 'p',
  format => 's',
  default => '/dev/ttyUSB1',
);

has 'port' => (
  is => 'lazy',
);

option 'name' => (
  is => 'ro',
  doc => 'Output filename base',
  format => 's',
  default => 'swr',
);

sub _build_port {
  my ($self) = @_;

  open my $fh, '+<', $self->portname or die "$! opening " . $self->portname . "\n";
  my $pid = fork;
  die "$! forking child for stty\n" unless defined $pid;
  if (!$pid) { # child
    open(STDIN, '<&', $fh) or die "$! dup'ing stdin\n";
    open(STDOUT, '>&', $fh) or die "$! dup'ing stdout\n";
    exec('stty', '57600', 'cs8', '-cstopb', '-parenb', '-echo', '-icrnl', '-onlcr'); # 57600 8N1 no local echo
  }
  wait;
  die "stty returned status $?\n" if $? > 0;
  return $fh;
}

sub acquire_data {
  my ($self) = @_;

  my $port = $self->port;
  open my $out, '>', $self->name . '.txt' or die "$! opening " . $self->name . '.txt';
  $out->autoflush(1);

  printf $port "scan %d %d %d\r\n", $self->start_hz, $self->end_hz + $self->step_hz, $self->step_hz;
  my $freq = $self->start_hz;
  my $started;
  my $progress = Time::Progress->new(min => $self->start_hz, max => $self->end_hz);

  while (my $line = <$port>) {
    $line =~ s/\r?\n\z//;
    last if $line eq 'End';
    if ($line eq 'Start') {
      $started = 1;
      $progress->restart;
      next;
    }
    next unless $started;
    my ($swr, $r, $x, $z) = split ",", $line;
    print $out "$freq\t$swr\t$r\t$x\t$z\n";
    print STDERR $progress->report("\rAcquiring data [%40b] %p ETA %E " . int($freq/1000) . "kHz SWR: " . sprintf("%.2f", $swr) . "    \b\b\b\b", $freq);
    $freq += $self->step_hz;
  }
  print STDERR "\n";
}

sub gen_swrplot {
  my ($self) = @_;

  open my $out, '>', $self->name . '.gnuplot' or die "$! opening ". $self->name . ".gnuplot\n";
  print $out qq{set format x "%.2s%cHz"\n};
  print $out qq{set format y "%.2f"\n};

  if ($self->bands) {
    print $out qq{set style rect fc lt -1 fs solid 0.15 noborder\n};
    for my $band (@BANDS) {
      my %tags;
      $tags{$_} = 1 for $band->{tags};
      next if $tags{warc} && !$self->warc;

      print $out qq{set obj rect from $band->{start}, graph 0 to $band->{end}, graph 1\n};
    }
  }

  print $out "set terminal pngcairo enhanced size ", $self->width, ",", $self->height, qq{ font "}, $self->font, qq{"\n};
  print $out qq{set output "} . $self->name . qq{.png"\n};

  print $out <<EOF;
set size .975, 1
set style line 11 lc rgb '#404040' lt 1
set border 3 back ls 11
set tics nomirror
set style line 12 lc rgb '#404040' lt 0
set grid back ls 12
EOF

  if (my $threshold = $self->threshold) {
    print $out qq{set style line 13 lt 2 dt 2 lc rgb "#404040"\n};

    for my $swr (@$threshold) {
      print $out qq{set arrow from graph 0, first $swr to graph 1, first $swr ls 13 nohead\n};
    }
  }

  print $out qq{plot [}, $self->start_hz, qq{:] [1:};
  if ($self->maxswr) {
    print $out $self->maxswr;
  }
  print $out qq{] "} . $self->name . qq{.txt" using 1:2 with lines ti "SWR"};
  if ($self->smooth) {
    print $out " smooth ", $self->smooth;
  }
  print $out "\n";
  system("gnuplot", $self->name . ".gnuplot");
}

sub run {
  my ($self) = @_;
  $self->acquire_data;
  $self->gen_swrplot;
}

package main;
SWR->new_with_options->run;
