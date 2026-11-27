use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;

my $class = 'Disk::Diskette';

is [ map { $_->name } $class->formats ], [qw( 160k 180k 320k 360k 720k 1200k 1440k 2880k )], 'formats';

subtest 'argument validation (no mtools needed)' => sub {
  my $dir = tmpdir();
  error_like { $class->create(colour => 'red', path => 'x.img') } qr/unknown create option: colour/;
  error_like { $class->create() } qr/output path is required when creating an empty image/;
  error_like { $class->create(path => "$dir/x.img", exclude => ['a']) } qr/not meaningful without a source: exclude/;
  error_like { $class->create(path => "$dir/x.img", follow_symlinks => 0) } qr/not meaningful without a source: follow_symlinks/;
  error_like { $class->create(path => "$dir/x.img", config => undef) } qr/not meaningful without a source: config/;
  error_like { $class->create(source => "$dir/missing") } qr/source does not exist/;
  $dir->child('file')->spew('x');
  error_like { $class->create(source => "$dir/file") } qr/source is not a directory/;
  error_like { $class->create(path => "$dir/x.img", format => 'bogus') } qr/unknown format: bogus/;
  error_like { $class->create(path => "$dir/x.img", source_date_epoch => 'soon') } qr/invalid source_date_epoch: 'soon'/;
  error_like { $class->create(path => "$dir/x.img", source_date_epoch => 0) } qr/outside the FAT timestamp range/;
  local $ENV{SOURCE_DATE_EPOCH} = '-1';
  error_like { $class->create(path => "$dir/x.img") } qr/invalid SOURCE_DATE_EPOCH/;
};

require_mtools();

subtest 'create from source with defaults' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('utilities'),
    'readme.txt'  => "hello\r\n",
    'tools/x.com' => \3000,
    'tools/empty' => '',
  );
  my $orig = Path::Tiny->cwd;
  chdir $work;
  my $image = $class->create(source => 'utilities/');
  chdir $orig;

  isa_ok $image, 'Disk::Diskette::Image';
  is $image->format, '720k', 'smallest auto-1440k candidate';
  is $image->label, 'UTILITIES', 'derived label';
  is $image->path->stringify, 'utilities.img', 'derived output path';
  ok -f $work->child('utilities.img');
  is -s $work->child('utilities.img'), 737280;
  fsck_ok($work->child('utilities.img'));
  is mdir_paths($work->child('utilities.img')), [ '/README.TXT', '/TOOLS', '/TOOLS/EMPTY', '/TOOLS/X.COM' ], 'mtools sees the expected names';
  is [ grep { /\.fdimg-/ } map { $_->basename } $work->children ], [], 'no temporary files left';
};

subtest 'explicit options' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('src'), 'a.txt' => 'a', 'b.bak' => 'b', 'README.md' => 'r');
  error_like {
    $class->create(source => $src, path => $work->child('out/disk.img'))
  } qr/destination directory does not exist/;
  $work->child('out')->mkpath;
  my $image = $class->create(
    source  => $src,
    path    => $work->child('out/disk.img'),
    format  => 'auto-1200k',
    label   => 'my tools',
    exclude => ['*.bak', 'README.md'],
  );
  is $image->format, '360k';
  is $image->label, 'MY TOOLS';
  is [ map { $_->path } $image->walk ], [ '/A.TXT' ];

  my $unlabeled = $class->create(source => $src, path => $work->child('nolabel.img'), label => undef, exclude => ['*.bak', 'README.md']);
  is $unlabeled->label, undef, 'explicit unlabeled';
};

subtest 'empty images' => sub {
  my $dir = tmpdir();
  my $image = $class->create(path => $dir->child('blank.img'), format => '360k', label => undef);
  is $image->format, '360k';
  is $image->label, undef;
  is [ $image->entries ], [];
  is $image->free_bytes, 354 * 1024;
  fsck_ok($image->path);

  is $class->create(path => $dir->child('auto.img'))->format, '720k', 'empty auto: first candidate';
  is $class->create(path => $dir->child('labeled.img'), label => 'blank')->label, 'BLANK';
};

subtest 'configuration' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('cfg'),
    '.fdimg.toml' => qq{format = "auto-1200k"\nlabel = "CONFIGURED"\nexclude = ["*.bak"]\n},
    'a.txt'       => 'a',
    'b.bak'       => 'b',
    'alt.cfg'     => qq{label = "ALT"\n},
  );
  my $image = $class->create(source => $src, path => $work->child('1.img'));
  is $image->format, '360k';
  is $image->label, 'CONFIGURED';
  is [ map { $_->name } $image->entries ], [ 'A.TXT', 'ALT.CFG' ], 'config file not copied, exclusion applied';

  $image = $class->create(source => $src, path => $work->child('2.img'), config => $src->child('alt.cfg'));
  is $image->label, 'ALT';
  is [ map { $_->name } $image->entries ], [ 'A.TXT', 'B.BAK' ], 'alternate config inside source excluded from copy';

  $image = $class->create(source => $src, path => $work->child('3.img'), config => undef);
  is $image->label, 'CFG', 'no-config';
  is $image->format, '720k';

  $image = $class->create(source => $src, path => $work->child('4.img'), exclude => []);
  is [ map { $_->name } $image->entries ], [ 'A.TXT', 'ALT.CFG', 'B.BAK' ], 'explicit empty exclusion list';
};

subtest 'round trip' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('rt'),
    'a.txt'          => "line\r\n" x 100,
    'bin/tool.exe'   => join('', map { chr($_ % 256) } 0 .. 20000),
    'bin/zero.dat'   => '',
    'docs/x/y/z.doc' => 'deep',
  );
  utime 1000000000, 1000000000, $src->child('a.txt');
  utime 1000000001, 1000000001, $src->child('bin/tool.exe');
  my $image = $class->create(source => $src, path => $work->child('rt.img'));
  my $out = $work->child('out');
  $image->extract_to($out);
  is $out->child('A.TXT')->slurp_raw, $src->child('a.txt')->slurp_raw;
  is $out->child('BIN/TOOL.EXE')->slurp_raw, $src->child('bin/tool.exe')->slurp_raw;
  is -s $out->child('BIN/ZERO.DAT'), 0;
  is $out->child('DOCS/X/Y/Z.DOC')->slurp_raw, 'deep';
  is $out->child('A.TXT')->stat->mtime, 1000000000, 'mtime preserved';
  is $out->child('BIN/TOOL.EXE')->stat->mtime, 1000000000, 'two second granularity';
};

subtest 'timestamps outside the FAT range are clamped' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('ts'), 'old.txt' => 'o', 'new.txt' => 'n');
  utime 0, 0, $src->child('old.txt');
  utime 4500000000, 4500000000, $src->child('new.txt');
  my $image = $class->create(source => $src, path => $work->child('ts.img'));
  is $image->lookup('/OLD.TXT')->mtime, 315532800, 'clamped to 1980-01-01';
  is $image->lookup('/NEW.TXT')->mtime, 4354819198, 'clamped to 2107-12-31 23:59:58';
};

subtest 'symlinked executables' => sub {
  my $work = tmpdir('work');
  my $src = make_tree($work->child('ln'), 'real.exe' => 'MZ...');
  symlink 'real.exe', $src->child('alias.exe') or die;
  my $image = $class->create(source => $src, path => $work->child('ln.img'));
  is $image->read_file('/ALIAS.EXE'), 'MZ...';
  isnt $image->lookup('/ALIAS.EXE')->cluster, $image->lookup('/REAL.EXE')->cluster, 'independent copies';
  error_like { $class->create(source => $src, path => $work->child('no.img'), follow_symlinks => 0) } qr/symbolic link not permitted/;
  ok !-e $work->child('no.img');
};

done_testing;
