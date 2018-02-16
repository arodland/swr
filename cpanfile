requires 'Moo';
requires 'CLI::Osprey';

on 'develop' => sub {
  requires 'App::FatPacker';
  requires 'Perl::Strip';
};

