use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use POSIX ();
use Disk::Diskette::Manifest;
use Disk::Diskette::Format;

my $class = 'Disk::Diskette::Manifest';

sub build (@args) { $class->build(@args) }

subtest 'patterns' => sub {
  is $class->check_pattern('*.bak'), undef;
  is $class->check_pattern('docs/*.txt'), undef;
  is $class->check_pattern('/README.md'), undef;
  is $class->check_pattern('[abc]?.x'), undef;
  is $class->check_pattern('[!0-9]*'), undef;
  is $class->check_pattern('a\\*b'), undef;
  like $class->check_pattern(''), qr/empty/;
  like $class->check_pattern('/'), qr/trailing/;
  like $class->check_pattern('**/*.c'), qr/\*\*/;
  like $class->check_pattern('dir/'), qr/trailing/;
  like $class->check_pattern('[abc'), qr/unterminated/;
  like $class->check_pattern('a\\'), qr/backslash/;
  like $class->check_pattern(undef), qr/not a string/;
  like $class->check_pattern([]), qr/not a string/;
};

subtest 'exclusion matching' => sub {
  my $src = make_tree(tmpdir('src'),
    'a.bak'          => 'x',
    'keep.txt'       => 'x',
    'README.md'      => 'x',
    'docs/README.md' => 'x',
    'docs/b.bak'     => 'x',
    'docs/c.txt'     => 'x',
    'docs/d1.txt'    => 'x',
    'build/'         => undef,
    'build/bad name' => 'x',
    'x1.c'           => 'x',
    'y.c'            => 'x',
    'star*.c'        => 'x',
  );
  my $paths = sub (@exclude) { map { $_->{dos_path} } build(source => $src, exclude => \@exclude)->nodes };

  is [ $paths->('*.bak', '/README.md', 'build', 'star\\*.c', 'docs/d?.txt', '[x]1.c', 'README.md') ],
     [ '/DOCS', '/DOCS/C.TXT', '/KEEP.TXT', '/Y.C' ], 'mixed patterns';

  is [ $paths->('/README.md', 'build', '*.c', '*.bak') ],
     [ '/DOCS', '/DOCS/README.MD', '/DOCS/C.TXT', '/DOCS/D1.TXT', '/KEEP.TXT' ], 'anchored pattern only at root';

  is [ $paths->('docs/*', 'build', '*.c', '*.bak', 'README.md') ],
     [ '/DOCS', '/KEEP.TXT' ], '* does not cross / but matches within';

  is [ $paths->('build', '[!k]*', 'docs') ], [ '/KEEP.TXT' ], 'negated class';

  error_like { build(source => $src, exclude => [q{BUILD}]) } qr/invalid DOS filename: .*bad name/, 'case-sensitive: BUILD does not exclude build';
};

subtest 'hidden entries' => sub {
  my $src = make_tree(tmpdir('src'),
    '.hidden'           => 'x',
    '.git/config'       => 'x',
    '.fdimg.toml'       => 'format = "360k"',
    'sub/.secret'       => 'x',
    'sub/.dir/bad name' => 'x',
    'sub/ok.txt'        => 'x',
  );
  is [ map { $_->{dos_path} } build(source => $src)->nodes ], [ '/SUB', '/SUB/OK.TXT' ];
};

subtest 'names and collisions' => sub {
  my $src;
  my $e;
  SKIP: {
    skip 'case-insensitive filesystem cannot hold names differing only by case', 3 unless case_sensitive_fs();
    $src = make_tree(tmpdir('files'),
      'README.TXT' => 'a',
      'readme.txt' => 'b',
    );
    $e = error_like { build(source => $src) } qr{DOS filename collision: /README\.TXT};
    like "$e", qr{files/README\.TXT and .*files/readme\.txt map to the same name}, 'both source paths';

    $src = make_tree(tmpdir('src'), 'Doc/' => undef, 'doc' => 'x');
    error_like { build(source => $src) } qr{collision: /DOC}, 'file/directory collision';
  }

  $src = make_tree(tmpdir('src'), 'a/x.txt' => 'x', 'b/x.txt' => 'y');
  is [ map { $_->{dos_path} } build(source => $src)->nodes ], [ '/A', '/A/X.TXT', '/B', '/B/X.TXT' ], 'same name in different directories';

  $src = make_tree(tmpdir('src'), 'toolongname.txt' => 'x', 'ok.txt' => 'x', 'bad+.txt' => 'x');
  $e = error_like { build(source => $src) } qr/2 problems found/;
  like "$e", qr/toolongname\.txt.*longer than 8/s;
  like "$e", qr/bad\+\.txt.*'\+'/s;

  $src = make_tree(tmpdir('src'), 'MixedCase.Txt' => 'x', 'Sub/lower.c' => 'y');
  error_like { build(source => $src) } qr/MixedCase\.Txt.*longer than 8/s, 'no truncation';
};

subtest 'symlinks' => sub {
  my $tmp = Path::Tiny->tempdir;
  my $outside = make_tree($tmp->child('outside'), 'target.exe' => 'outside data');
  my $src = make_tree($tmp->child('src'), 'real.exe' => 'real data', 'dir/' => undef);
  symlink 'real.exe', $src->child('alias.exe') or die;
  symlink 'alias.exe', $src->child('chain.exe') or die;
  symlink $outside->child('target.exe')->stringify, $src->child('ext.exe') or die;

  my $m = build(source => $src);
  my %files = map { $_->{dos_path} => $_ } $m->files;
  is [ sort keys %files ], [ '/ALIAS.EXE', '/CHAIN.EXE', '/EXT.EXE', '/REAL.EXE' ];
  is $files{'/EXT.EXE'}->{size}, length 'outside data', 'external target size';
  is $files{'/CHAIN.EXE'}->{size}, length 'real data', 'chain size';
  is $m->requirements(Disk::Diskette::Format->get('1440k'))->{clusters}, 5, 'each link counted separately (+1 dir)';

  my $e = error_like { build(source => $src, follow_symlinks => 0) } qr/3 problems/;
  like "$e", qr/symbolic link not permitted: .*alias\.exe/;

  my $bad = make_tree($tmp->child('bad'), 'ok.txt' => 'x', 'realdir/' => undef);
  symlink 'nowhere', $bad->child('dangle') or die;
  symlink 'realdir', $bad->child('dirlink') or die;
  symlink 'loop1', $bad->child('loop2') or die;
  symlink 'loop2', $bad->child('loop1') or die;
  $e = error_like { build(source => $bad) } qr/4 problems/;
  like "$e", qr/dangling symbolic link: .*dangle/;
  like "$e", qr/directory symbolic links are not supported: .*dirlink/;
  like "$e", qr/circular symbolic link: .*loop1/;
  like "$e", qr/circular symbolic link: .*loop2/;

  is [ map { $_->{dos_path} } build(source => $bad, exclude => ['dangle', 'dirlink', 'loop?'])->nodes ],
     [ '/OK.TXT', '/REALDIR' ], 'excluded links are not inspected';

  my $named = make_tree($tmp->child('named'), 'longer-target-name.exe' => 'x');
  symlink 'longer-target-name.exe', $named->child('short.exe') or die;
  is [ map { $_->{dos_path} } build(source => $named, exclude => ['longer*'])->nodes ], [ '/SHORT.EXE' ], 'link name used, not target name';
};

subtest 'special files' => sub {
  my $tmp = Path::Tiny->tempdir;
  my $src = make_tree($tmp->child('src'), 'ok.txt' => 'x');
  if(POSIX::mkfifo($src->child('fifo')->stringify, oct 600)) {
    error_like { build(source => $src) } qr/special file not supported: .*fifo/;
    symlink 'fifo', $src->child('flink');
    error_like { build(source => $src, exclude => ['fifo']) } qr/symbolic link to a special file: .*flink/;
  } else {
    pass 'mkfifo not supported';
  }
};

subtest 'unreadable' => sub {
  skip_all 'running as root' if $> == 0;
  my $src = make_tree(tmpdir('src'), 'secret.txt' => 'x', 'locked/a.txt' => 'y');
  chmod 0000, $src->child('secret.txt');
  chmod 0000, $src->child('locked');
  my $e = error_like { build(source => $src) } qr/2 problems/;
  like "$e", qr/unable to read file: .*secret\.txt/;
  like "$e", qr/unable to read directory: .*locked/;
  chmod 0755, $src->child('locked');
};

subtest 'skip and source errors' => sub {
  my $src = make_tree(tmpdir('src'), 'alt.toml' => 'x', 'keep.txt' => 'y');
  is [ map { $_->{dos_path} } build(source => $src, skip => [ $src->child('alt.toml') ])->nodes ], [ '/KEEP.TXT' ];
  error_like { build(source => "$src/nope") } qr/source does not exist/;
  error_like { build(source => "$src/keep.txt") } qr/source is not a directory/;
  error_like { build(source => $src, exclude => ['**']) } qr/invalid exclude pattern/;
};

subtest 'capacity' => sub {
  my $f360  = Disk::Diskette::Format->get('360k');   # 1024 byte clusters, 112 root entries
  my $f1440 = Disk::Diskette::Format->get('1440k');  # 512 byte clusters, 224 root entries

  my $src = make_tree(tmpdir('src'),
    'empty.txt' => '',
    'one.txt'   => \1,
    'k.txt'     => \1024,
    'k1.txt'    => \1025,
    'dir/'      => undef,
  );
  my $m = build(source => $src);
  is $m->total_file_bytes, 2050;
  is $m->requirements($f360),  { root_entries => 5, clusters => 0 + 1 + 1 + 2 + 1 };
  is $m->requirements($f1440, label => 1), { root_entries => 6, clusters => 0 + 1 + 2 + 3 + 1 };
  is [ $m->fits($f360) ], [], 'fits';

  # directory growth: 2 + 30 entries = 1024 bytes = 1 cluster on 360k, 2 on 1440k; 31 needs more
  my $big = make_tree(tmpdir('src'), map { ("d/f$_.txt" => '') } 1..30);
  is build(source => $big)->requirements($f360)->{clusters}, 1;
  is build(source => $big)->requirements($f1440)->{clusters}, 2;
  $big->child('d/f31.txt')->spew('');
  is build(source => $big)->requirements($f360)->{clusters}, 2, 'directory grows';

  my $root = make_tree(tmpdir('src'), map { ("f$_" => '') } 1..112);
  my $rm = build(source => $root);
  is [ $rm->fits($f360) ], [], '112 root entries fit 360k';
  like [ $rm->fits($f360, label => 1) ], [ qr/root directory needs 113 entries \(including the volume label\) but 360k allows 112/ ];

  my $full = make_tree(tmpdir('src'), 'big' => \($f360->data_bytes + 1));
  like [ build(source => $full)->fits($f360) ], [ qr/data needs 355 clusters \(363520 bytes\) but 360k has 354 \(362496 bytes\)/ ];
};

done_testing;
