use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;
use Disk::Diskette::FAT12;
use Disk::Diskette::Backend::Mtools;

my $class = 'Disk::Diskette::FAT12';

subtest 'normalize_path' => sub {
  is $class->normalize_path('/'), '/';
  is $class->normalize_path(undef), '/';
  is $class->normalize_path(''), '/';
  is $class->normalize_path('docs'), '/DOCS';
  is $class->normalize_path('/docs//a.txt/'), '/DOCS/A.TXT';
  is $class->normalize_path('./docs/./a.txt'), '/DOCS/A.TXT';
  error_like { $class->normalize_path('../x') } qr/may not contain \.\./;
  error_like { $class->normalize_path('a:/x') } qr/drive/;
  error_like { $class->normalize_path('a\\b') } qr/separator/;
};

subtest 'not images' => sub {
  my $dir = tmpdir();
  error_like { $class->load($dir->child('missing.img')) } qr/image does not exist/;
  error_like { $class->load($dir) } qr/not a regular file/;
  $dir->child('short.img')->spew_raw('x' x 100);
  error_like { $class->load($dir->child('short.img')) } qr/too short/;
  $dir->child('zero.img')->spew_raw("\0" x 368640);
  error_like { $class->load($dir->child('zero.img')) } qr/not a supported FAT12 floppy image.*supported formats/s;
};

require_mtools();

my $src = make_tree(tmpdir('src'),
  'a.txt'       => 'alpha',
  'big.bin'     => \5000,
  'empty.txt'   => '',
  'sub/b.txt'   => 'beta',
  'sub/deep/c'  => 'gamma',
);

sub fresh_image ($name = 'disk.img') {
  my $path = tmpdir()->child($name);
  Disk::Diskette->create(source => $src, path => $path, format => '720k', label => 'FATTEST');
  return $path;
}

sub patch ($path, $offset, $bytes) {
  my $data = path($path)->slurp_raw;
  substr($data, $offset, length $bytes, $bytes);
  path($path)->spew_raw($data);
}

subtest 'reading' => sub {
  my $img = fresh_image();
  my $fs = $class->load($img);
  is $fs->format->name, '720k';
  is $fs->label, 'FATTEST';
  like $fs->serial_string, qr/\A[0-9A-F]{4}-[0-9A-F]{4}\z/;
  is [ map { $_->path } $fs->entries ], [ '/SUB', '/A.TXT', '/BIG.BIN', '/EMPTY.TXT' ], 'root order: directories created first';
  is [ map { $_->path } $fs->walk ], [ '/SUB', '/SUB/DEEP', '/SUB/DEEP/C', '/SUB/B.TXT', '/A.TXT', '/BIG.BIN', '/EMPTY.TXT' ];
  is [ map { $_->name } $fs->entries('sub') ], [ 'DEEP', 'B.TXT' ];
  is $fs->read_file($fs->lookup('/big.bin')), 'x' x 5000;
  is $fs->read_file($fs->lookup('/EMPTY.TXT')), '';
  is $fs->lookup('/SUB/DEEP/C')->size, 5;
  is $fs->lookup('/nope'), undef;
  is $fs->lookup('/A.TXT/x'), undef;
  is $fs->lookup('/'), undef, 'root has no entry';
  error_like { $fs->entries('/A.TXT') } qr/not a directory/;
  error_like { $fs->entries('/NOPE') } qr/no such directory/;
  # 5 + 5000 + 4 + 5 bytes => 1 + 5 + 1 + 1 clusters, directories 2
  is $fs->free_clusters, 713 - 10;
  is $fs->free_bytes, (713 - 10) * 1024;
  is [ $fs->check ], [];
  is $fs->long_name_entries, 0;
};

subtest 'unlabeled' => sub {
  my $path = tmpdir()->child('e.img');
  Disk::Diskette->create(path => $path, format => '1440k');
  is $class->load($path)->label, undef;
};

subtest 'corruption' => sub {
  my $img = fresh_image();
  my $fs = $class->load($img);
  my $f = $fs->format;

  my $copy = sub { my $p = tmpdir()->child('c.img'); path($img)->copy($p); $p };

  my $p = $copy->();
  patch($p, 510, "\0\0");
  like [ $class->load($p)->check ], bag { item qr/boot sector signature/; etc };

  $p = $copy->();
  patch($p, ($f->fat_start_sector + $f->fat_sectors) * 512 + 10, "\x12\x34");
  like [ $class->load($p)->check ], bag { item qr/FAT copy 2 differs/; etc };

  $p = $copy->();
  patch($p, $f->fat_start_sector * 512, "\xF0");
  like [ $class->load($p)->check ], bag { item qr/FAT media byte 0xF0 does not match/; etc };

  # lost cluster: mark the last cluster allocated in both FATs
  $p = $copy->();
  my $n = $f->cluster_count + 1;
  my $off = int($n * 3 / 2);
  for my $copy_n (0, 1) {
    my $base = ($f->fat_start_sector + $copy_n * $f->fat_sectors) * 512;
    my $data = path($p)->slurp_raw;
    my $pair = unpack 'v', substr($data, $base + $off, 2);
    $pair = $n & 1 ? ($pair & 0x000F) | (0xFFF << 4) : ($pair & 0xF000) | 0xFFF;
    patch($p, $base + $off, pack 'v', $pair);
  }
  like [ $class->load($p)->check ], [ qr/1 lost clusters/ ];

  # wrong file size against chain
  $p = $copy->();
  my $root = $f->root_dir_start_sector * 512;
  my $data = path($p)->slurp_raw;
  my $i = 0;
  $i++ until substr($data, $root + $i * 32, 11) eq 'BIG     BIN';
  patch($p, $root + $i * 32 + 28, pack 'V', 100);
  like [ $class->load($p)->check ], bag { item qr{/BIG\.BIN: size 100 needs 1 clusters but chain has 5}; etc };

  # cross link: point A.TXT at BIG.BIN's first cluster
  $p = $copy->();
  my $big_cluster = unpack 'v', substr($data, $root + $i * 32 + 26, 2);
  my $j = 0;
  $j++ until substr($data, $root + $j * 32, 11) eq 'A       TXT';
  patch($p, $root + $j * 32 + 26, pack 'v', $big_cluster);
  like [ $class->load($p)->check ], bag { item qr/cross-linked/; etc };

  # wrong length
  $p = $copy->();
  path($p)->append_raw("\0");
  error_like { $class->load($p) } qr/image length does not match its geometry/;
};

subtest 'long file name entries are counted' => sub {
  my $img = fresh_image();
  my $backend = Disk::Diskette::Backend::Mtools->new;
  $backend->run('mcopy', [ '-i', "$img", $src->child('a.txt')->stringify, '::/x+y.txt' ]);
  my $fs = $class->load($img);
  ok $fs->long_name_entries > 0, 'counted';
  is [ $fs->long_names ], [ [ '/X_Y~1.TXT', 'x+y.txt' ] ], 'long name decoded';
  is [ $fs->check ], [], 'still consistent';
  ok !(grep { $_->name eq '' } $fs->walk), 'not listed';
};

done_testing;
