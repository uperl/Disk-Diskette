use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Capture::Tiny qw( capture );
use App::fdimg;

sub run (@args) {
  my($out, $err, $exit) = capture { App::fdimg->main(@args) };
  return { out => $out, err => $err, exit => $exit };
}

subtest 'help and version' => sub {
  for my $args ([], ['--help'], ['-h'], ['help']) {
    my $r = run(@$args);
    is $r->{exit}, 0, "exit 0 for (@$args)";
    like $r->{out}, qr/Usage: fdimg COMMAND/;
    like $r->{out}, qr/^\s+create\s+Create an image/m;
    like $r->{out}, qr/^\s+completions\s+/m;
    is $r->{err}, '';
  }

  my $r = run('--version');
  is $r->{exit}, 0;
  like $r->{out}, qr/\Afdimg version \S+\n\z/;

  for my $args (['help', 'create'], ['create', '--help'], ['create', '-h']) {
    $r = run(@$args);
    is $r->{exit}, 0, "exit 0 for (@$args)";
    like $r->{out}, qr/Usage: fdimg create \[options\] SOURCE \[IMAGE\]\n\s+fdimg create --empty/;
    like $r->{out}, qr/--\[no-\]follow-symlinks/;
    like $r->{out}, qr/--no-label/;
  }

  for my $name (App::fdimg->commands) {
    $r = run('help', $name);
    is $r->{exit}, 0, "help $name";
    like $r->{out}, qr/Usage: fdimg $name/;
  }
};

subtest 'usage errors' => sub {
  my %cases = (
    'bogus'                                 => qr/unknown command: bogus/,
    '--bogus'                               => qr/unknown option: --bogus/,
    'help bogus'                            => qr/unknown command: bogus/,
    'create'                                => qr/missing arguments/,
    'create a b c'                          => qr/too many arguments/,
    'create --bogus x'                      => qr/Unknown option: bogus/,
    'create --format'                       => qr/requires an argument/,
    'create --label X --no-label src'       => qr/mutually exclusive/,
    'create --config x --no-config src'     => qr/mutually exclusive/,
    'create --empty'                        => qr/missing arguments/,
    'create --empty a b'                    => qr/--empty takes exactly one argument/,
    'create --empty --exclude x a.img'      => qr/--exclude is not meaningful with --empty/,
    'create --empty --no-follow-symlinks a' => qr/follow-symlinks is not meaningful with --empty/,
    'create --empty --no-config a.img'      => qr/--no-config is not meaningful with --empty/,
    'create --empty --config c a.img'       => qr/--config is not meaningful with --empty/,
    'info'                                  => qr/missing arguments/,
    'formats extra'                         => qr/too many arguments/,
    'completions tcsh'                      => qr/unsupported shell: tcsh/,
  );
  for my $line (sort keys %cases) {
    my $r = run(split / /, $line);
    is $r->{exit}, 2, "exit 2: $line";
    like $r->{err}, $cases{$line}, "message: $line";
    like $r->{err}, qr/Try 'fdimg help/, 'hint';
    is $r->{out}, '', 'nothing on stdout';
  }
};

subtest 'formats' => sub {
  my $r = run('formats');
  is $r->{exit}, 0;
  like $r->{out}, qr/^\s+1440k\s+80\s+2\s+18\s+1474560/m;
  like $r->{out}, qr/^\s+auto-1440k\s+720k, 1440k\s+\(default\)/m;
  like $r->{out}, qr/^\s+auto-1200k\s+360k, 1200k$/m;
};

subtest 'completions' => sub {
  my %check = (bash => [ 'bash', '-n' ], zsh => [ 'zsh', '-n' ], fish => [ 'fish', '--no-execute' ]);
  for my $shell (sort keys %check) {
    my $r = run('completions', $shell);
    is $r->{exit}, 0, $shell;
    like $r->{out}, qr/auto-1440k/, "$shell completes formats";
    like $r->{out}, qr/follow-symlinks/, "$shell completes options";
    like $r->{out}, qr/\bextract\b/, "$shell completes commands";
    my($exe, @flags) = $check{$shell}->@*;
    SKIP: {
      my $path = have_program($exe) or skip "$exe not installed", 1;
      my $file = tmpdir()->child("fdimg.$shell");
      $file->spew($r->{out});
      my($out, $err, $exit) = capture { system $path, @flags, "$file"; $? };
      is $exit, 0, "$shell syntax check" or diag $err;
    }
  }
};

subtest 'operation failures' => sub {
  my $r = run('info', tmpdir()->child('missing.img')->stringify);
  is $r->{exit}, 1;
  like $r->{err}, qr/\Afdimg: image does not exist/;
  is $r->{out}, '';
  unlike $r->{err}, qr/ at \S+ line \d+/, 'no stack trace';
};

{
  require_mtools();
  my $work = tmpdir('work');
  my $src = make_tree($work->child('utilities'),
    'readme.txt' => 'hello',
    'files/README.TXT' => 'a',
    'tools/x.com' => \2000,
    'x.bak' => 'b',
  );
  $src->child('files/README.TXT')->remove;

  my $orig = Path::Tiny->cwd;
  chdir $work;

  subtest 'create' => sub {
    local @ARGV = ('untouched');
    my $r = run('create', 'utilities/');
    is $r->{exit}, 0;
    is $r->{out}, "Created utilities.img (720K FAT12)\n";
    is $r->{err}, '';
    is \@ARGV, ['untouched'], 'global @ARGV untouched';

    $r = run('create', 'utilities/');
    is $r->{exit}, 1, 'exists';
    like $r->{err}, qr/fdimg: destination already exists: utilities\.img\n  use --force/;
    is $r->{out}, '', 'no success message on failure';

    $r = run('create', '--force', '-f', 'auto-1200k', '--label', 'tools', '--exclude', '*.bak', '--exclude', 'readme.txt', 'utilities', 'out.img');
    is $r->{exit}, 0;
    is $r->{out}, "Created out.img (360K FAT12)\n";

    $r = run('create', '--no-label', '--no-follow-symlinks', '--no-config', 'utilities', 'nolabel.img');
    is $r->{exit}, 0;

    $r = run('create', '--empty', '--format', '360k', 'blank.img');
    is $r->{exit}, 0;
    is $r->{out}, "Created blank.img (360K FAT12)\n";

    $src->child('files/readme.txt')->spew('b');
    $src->child('files/README.TXT')->spew('a');
    $r = run('create', 'utilities', 'collide.img');
    is $r->{exit}, 1;
    like $r->{err}, qr{\Afdimg: DOS filename collision: /FILES/README\.TXT\n  utilities/files/README\.TXT and utilities/files/readme\.txt map to the same name\n\z};
    $src->child('files/README.TXT')->remove;
    $src->child('files/readme.txt')->remove;

    $r = run('create', '-f', '360k', '-l', 'x', 'utilities', 'short.img');
    is $r->{exit}, 0, 'short options';
  };

  subtest 'info' => sub {
    my $r = run('info', 'utilities.img');
    is $r->{exit}, 0;
    like $r->{out}, qr/^Format:\s+720k \(3\.5" double-density\)$/m;
    like $r->{out}, qr/^Geometry:\s+80 cylinders, 2 heads, 9 sectors\/track, 512 bytes\/sector$/m;
    like $r->{out}, qr/^Filesystem:\s+FAT12/m;
    like $r->{out}, qr/^Label:\s+UTILITIES$/m;
    like $r->{out}, qr/^Size:\s+737280 bytes$/m;
    like $r->{out}, qr/^Free:\s+\d+ bytes$/m;
    like run('info', 'nolabel.img')->{out}, qr/^Label:\s+\(none\)$/m;
  };

  subtest 'ls' => sub {
    my $r = run('ls', 'utilities.img');
    is $r->{exit}, 0;
    my @lines = split /\n/, $r->{out};
    like \@lines, [ qr/<DIR>.*FILES\/$/, qr/<DIR>.*TOOLS\/$/, qr/^---A\s+5\s+\d{4}-\d\d-\d\d \d\d:\d\d\s+README\.TXT$/, qr/X\.BAK$/ ];
    $r = run('ls', '-r', 'utilities.img');
    like [ split /\n/, $r->{out} ], [ qr{/FILES/$}, qr{/TOOLS/$}, qr{^---A\s+2000 .* /TOOLS/X\.COM$}, qr{/README\.TXT$}, qr{/X\.BAK$} ];
    $r = run('ls', 'utilities.img', 'tools');
    like [ split /\n/, $r->{out} ], [ qr/\bX\.COM$/ ];
    $r = run('ls', 'utilities.img', 'nope');
    is $r->{exit}, 1;
    like $r->{err}, qr/no such directory in image: \/NOPE/;
  };

  subtest 'validate' => sub {
    my $r = run('validate', 'utilities.img');
    is $r->{exit}, 0;
    like $r->{out}, qr/\Autilities\.img: OK \(720K FAT12, 3 files, 2 directories, \d+ bytes free\)\n\z/;
    path('corrupt.img')->spew_raw(path('utilities.img')->slurp_raw =~ s/\x55\xAA/\0\0/r);
    $r = run('validate', 'corrupt.img');
    is $r->{exit}, 1;
    like $r->{err}, qr/fdimg: image is invalid: corrupt\.img\n  boot sector signature/;
  };

  subtest 'extract' => sub {
    my $r = run('extract', 'utilities.img', 'out');
    is $r->{exit}, 0;
    is $r->{out}, "Extracted 5 entries to out\n";
    is path('out/TOOLS/X.COM')->slurp_raw, 'x' x 2000;
    $r = run('extract', 'utilities.img', 'out');
    is $r->{exit}, 1;
    like $r->{err}, qr/refusing to overwrite/;
  };

  subtest 'repeated invocation' => sub {
    for (1 .. 3) {
      is run('info', 'utilities.img')->{exit}, 0;
      is run('bogus')->{exit}, 2;
    }
  };

  chdir $orig;
}

done_testing;
