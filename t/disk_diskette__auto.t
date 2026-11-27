use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;
use Disk::Diskette::Format;

require_mtools();

my $f720  = Disk::Diskette::Format->get('720k');
my $f360  = Disk::Diskette::Format->get('360k');

sub create (%args) { Disk::Diskette->create(path => tmpdir()->child('x.img'), %args) }

subtest 'data boundary' => sub {
  my $exact = make_tree(tmpdir('exact'), 'big.bin' => \$f720->data_bytes);
  is create(source => $exact, label => undef)->format, '720k', 'exactly full 720k';
  is create(source => $exact, label => 'L')->format, '720k', 'label uses no data clusters';
  ok lives { create(source => $exact, label => undef)->validate };

  my $over = make_tree(tmpdir('over'), 'big.bin' => \($f720->data_bytes + 1));
  is create(source => $over)->format, '1440k', 'one byte more promotes';

  my $dir_cost = make_tree(tmpdir('dircost'), 'big.bin' => \($f720->data_bytes - 1024), 'sub/' => undef);
  is create(source => $dir_cost)->format, '720k', 'directory cluster counted (fits)';
  $dir_cost->child('sub2')->mkpath;
  is create(source => $dir_cost)->format, '1440k', 'second directory needs a cluster';
};

subtest 'root directory exhaustion' => sub {
  my $src = make_tree(tmpdir('roots'), map { ("f$_" => '') } 1 .. 112);
  is create(source => $src, label => undef)->format, '720k', '112 entries fit unlabeled';
  my $image = create(source => $src, label => 'ROOTS');
  is $image->format, '1440k', 'label entry promotes';
  is scalar(my @e = $image->entries), 112;
};

subtest 'directory growth' => sub {
  # 360k has 1024 byte clusters: 32 entries per directory cluster
  my $src = make_tree(tmpdir('grow'), map { ("d/f$_" => 'x') } 1 .. 40);
  my $image = create(source => $src, format => '360k');
  is $image->free_bytes, $f360->data_bytes - (2 + 40) * 1024, 'two directory clusters plus file clusters';
  ok lives { $image->validate };
  fsck_ok($image->path);
};

subtest 'shrink and grow on re-creation' => sub {
  my $src = make_tree(tmpdir('change'), 'big.bin' => \1_000_000);
  my $path = tmpdir()->child('change.img');
  is Disk::Diskette->create(source => $src, path => $path)->format, '1440k';
  $src->child('big.bin')->spew_raw('small');
  is Disk::Diskette->create(source => $src, path => $path, force => 1)->format, '720k', 'smaller image when content shrinks';
  is -s $path, 737280;
};

subtest 'no cross-drive promotion' => sub {
  my $src = make_tree(tmpdir('huge'), 'big.bin' => \1_300_000);
  my $e = error_like { create(source => $src, format => 'auto-1200k') } qr/source does not fit in auto-1200k/;
  like "$e", qr/360k: data needs/;
  like "$e", qr/1200k: data needs/;
  unlike "$e", qr/1440k/;
  is create(source => $src, format => 'auto-1440k')->format, '1440k';

  error_like { create(source => make_tree(tmpdir('mid'), 'b' => \400_000), format => 'auto-360k') } qr/does not fit in auto-360k/;
  error_like { create(source => make_tree(tmpdir('mid2'), 'b' => \400_000), format => '360k') } qr/does not fit in 360k/;
  is create(source => make_tree(tmpdir('mid3'), 'b' => \400_000), format => 'auto-1200k')->format, '1200k';
  is create(source => make_tree(tmpdir('mid4'), 'b' => \2_000_000), format => 'auto-2880k')->format, '2880k';
};

done_testing;
