use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette::Config;

my $class = 'Disk::Diskette::Config';

sub source_with ($name, $toml = undef) {
  my $dir = tmpdir($name);
  $dir->mkpath;
  $dir->child('.fdimg.toml')->spew_utf8($toml) if defined $toml;
  return $dir;
}

is $class->filename, '.fdimg.toml';
is [ $class->supported_keys ], [qw( format label follow_symlinks exclude )];

subtest 'defaults' => sub {
  my $src = source_with('utilities');
  is $class->discover($src), undef, 'no config discovered';
  is $class->resolve(source => $src), {
    format => 'auto-1440k', label => 'UTILITIES', follow_symlinks => 1, exclude => [], config => undef,
  };
  is $class->resolve(), {
    format => 'auto-1440k', label => undef, follow_symlinks => 1, exclude => [], config => undef,
  }, 'no source: unlabeled';
};

subtest 'load full config' => sub {
  my $src = source_with('src', <<~'TOML');
    format = "AUTO-720K"
    label = "my disk"
    follow_symlinks = false
    exclude = ["README.md", "*.bak"]
    TOML
  is $class->load($src->child('.fdimg.toml')), {
    format => 'auto-720k', label => 'MY DISK', follow_symlinks => 0, exclude => ['README.md', '*.bak'],
  };
  my $r = $class->resolve(source => $src);
  is $r, {
    format => 'auto-720k', label => 'MY DISK', follow_symlinks => 0,
    exclude => ['README.md', '*.bak'], config => object { prop blessed => 'Path::Tiny' },
  };
};

subtest 'precedence' => sub {
  my $src = source_with('src', qq{format = "360k"\nlabel = "CONF"\nfollow_symlinks = false\nexclude = ["a", "b"]\n});

  my $r = $class->resolve(source => $src, args => { format => '1440k', label => 'arg', follow_symlinks => 1, exclude => ['c'] });
  is $r->{format}, '1440k', 'explicit format';
  is $r->{label}, 'ARG', 'explicit label normalized';
  is $r->{follow_symlinks}, 1, 'explicit true over config false';
  is $r->{exclude}, ['c'], 'explicit exclude replaces';

  $r = $class->resolve(source => $src, args => { exclude => [] });
  is $r->{exclude}, [], 'empty list clears configured exclusions';

  $r = $class->resolve(source => $src, args => { label => undef });
  is $r->{label}, undef, 'explicit unlabeled overrides config';

  $r = $class->resolve(source => $src, args => { follow_symlinks => 0 });
  is $r->{follow_symlinks}, 0, 'explicit false';

  my $src2 = source_with('other', qq{follow_symlinks = true\n});
  is $class->resolve(source => $src2, args => { follow_symlinks => 0 })->{follow_symlinks}, 0, 'explicit false over config true';

  $r = $class->resolve(source => $src, args => { config => undef });
  is $r, { format => 'auto-1440k', label => 'SRC', follow_symlinks => 1, exclude => [], config => undef }, 'no-config';
};

subtest 'empty label in config' => sub {
  my $src = source_with('named', qq{label = ""\n});
  is $class->resolve(source => $src)->{label}, undef;
};

subtest 'explicit config file' => sub {
  my $src = source_with('src', qq{format = "360k"\n});
  my $alt = Path::Tiny->tempfile;
  $alt->spew_utf8(qq{format = "720k"\n});
  my $r = $class->resolve(source => $src, args => { config => "$alt" });
  is $r->{format}, '720k', 'explicit config used instead of discovered';
  is "$r->{config}", "$alt";
  error_like { $class->resolve(source => $src, args => { config => "$alt.missing" }) } qr/config file does not exist/;
};

subtest 'invalid config' => sub {
  my %cases = (
    qq{format = = 1\n}                   => qr/malformed TOML.*line 1/s,
    qq{bogus = 1\n}                       => qr/unknown key 'bogus'/,
    qq{format = 1440\n}                   => qr/'format' must be a string, not integer/,
    qq{format = "1.44m"\n}                => qr/'format' has an unknown value '1\.44m'/,
    qq{label = 12\n}                      => qr/'label' must be a string, not integer/,
    qq{label = "much too long name"\n}    => qr/'label' is invalid: label is longer than 11/,
    qq{follow_symlinks = "yes"\n}         => qr/'follow_symlinks' must be a boolean, not string/,
    qq{follow_symlinks = 1\n}             => qr/'follow_symlinks' must be a boolean, not integer/,
    qq{exclude = "*.bak"\n}               => qr/'exclude' must be an array of strings, not string/,
    qq{exclude = ["ok", 2]\n}             => qr/'exclude' item 1 must be a string, not integer/,
    qq{exclude = ["**/x"]\n}              => qr/'exclude' item 0 \('\*\*\/x'\) is invalid/,
    qq{[format]\nx = 1\n}                 => qr/'format' must be a string, not table/,
    qq{format = 1979-05-27\n}             => qr/not datetime/,
  );
  for my $toml (sort keys %cases) {
    my $src = source_with('src', $toml);
    error_like { $class->resolve(source => $src) } qr/\.fdimg\.toml/, "filename reported for: $toml";
    error_like { $class->resolve(source => $src, args => { format => '360k', label => 'X' }) } $cases{$toml}, "error even with overrides: $toml";
  }

  my $src = source_with('src');
  $src->child('.fdimg.toml')->spew_raw("label = \"\xff\"\n");
  error_like { $class->resolve(source => $src) } qr/not valid UTF-8/;

  my $two = source_with('src', qq{bogus = 1\nformat = 2\n});
  my $e = error_like { $class->resolve(source => $two) } qr/invalid configuration/;
  is scalar $e->details->@*, 2, 'all problems reported';
};

subtest 'invalid explicit arguments' => sub {
  my $src = source_with('src');
  error_like { $class->resolve(source => $src, args => { format => 'nope' }) } qr/unknown format: nope/;
  error_like { $class->resolve(source => $src, args => { label => 'a*b' }) } qr/invalid volume label/;
  error_like { $class->resolve(source => $src, args => { exclude => ['**'] }) } qr/invalid exclude pattern/;
  error_like { $class->resolve(source => $src, args => { colour => 1 }) } qr/unknown option: colour/;
};

subtest 'derived labels' => sub {
  error_like { $class->resolve(source => source_with('toolongname1')) } qr/unable to derive a volume label.*--label.*--no-label/s;
  error_like { $class->resolve(source => source_with('dot.dir')) } qr/'\.', which is not permitted/;
  is $class->resolve(source => source_with('dot.dir'), args => { label => undef })->{label}, undef, 'no-label avoids derivation';
  is $class->resolve(source => path(source_with('trail') . '/'))->{label}, 'TRAIL', 'trailing separator';

  is $class->source_basename('foo/bar/'), 'bar';
  is $class->source_basename('/'), undef, 'root has no basename';

  my $dir = source_with('cwdname');
  my $orig = Path::Tiny->cwd;
  chdir $dir;
  is $class->source_basename('.'), 'cwdname', '. resolved';
  is $class->resolve(source => '.')->{label}, 'CWDNAME';
  chdir $orig;

  error_like { $class->resolve(source => '/') } qr/no usable name/;
};

done_testing;
