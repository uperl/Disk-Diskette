use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;
use Disk::Diskette::Backend::Mtools;

require_mtools();

sub leftovers ($dir) { [ grep { /\.fdimg-/ } map { $_->basename } $dir->children ] }

my $src = make_tree(tmpdir('src'), 'a.txt' => 'alpha', 'b.txt' => 'beta');

subtest 'existing destination' => sub {
  my $dir = tmpdir();
  my $dest = $dir->child('disk.img');
  $dest->spew('not an image');
  error_like { Disk::Diskette->create(source => $src, path => $dest) } qr/destination already exists: .*--force/s;
  is $dest->slurp, 'not an image', 'untouched';
  my $image = Disk::Diskette->create(source => $src, path => $dest, force => 1);
  is $image->format, '720k', 'replaced with force';
  is leftovers($dir), [];
};

subtest 'unsafe destinations' => sub {
  my $dir = tmpdir();
  my $victim = $dir->child('victim');
  $victim->spew('precious');
  symlink "$victim", $dir->child('link.img') or die;
  error_like { Disk::Diskette->create(source => $src, path => $dir->child('link.img'), force => 1) } qr/destination is a symbolic link/;
  is $victim->slurp, 'precious';

  $dir->child('dir.img')->mkpath;
  error_like { Disk::Diskette->create(source => $src, path => $dir->child('dir.img'), force => 1) } qr/not a regular file/;

  error_like { Disk::Diskette->create(source => $src, path => $src->child('inside.img')) } qr/destination is inside the source tree/;
  error_like { Disk::Diskette->create(source => $src, path => $src->child('sub/inside.img')) } qr/inside the source tree|does not exist/;
  ok !-e $src->child('inside.img');

  my $alias = tmpdir('alias')->child('srclink');
  symlink "$src", $alias or die;
  error_like { Disk::Diskette->create(source => $src, path => $alias->child('x.img')) } qr/inside the source tree/, 'aliased via symlink';
};

package Test::Backend::Failing {
  use v5.42;
  use Moo 2;
  extends 'Disk::Diskette::Backend::Mtools';
  has fail_on => ( is => 'ro' );
  has hook    => ( is => 'ro' );
  sub copy_file ($self, $path, $host, $dos_path, %opts) {
    $self->hook->($path, $host, $dos_path) if $self->hook;
    return if $self->fail_on && $self->fail_on eq 'skip' && $dos_path eq '/B.TXT';
    Disk::Diskette::Error->throw('simulated backend failure') if $self->fail_on && $self->fail_on eq 'die';
    $self->SUPER::copy_file($path, $host, $dos_path, %opts);
  }
}

subtest 'backend failure preserves existing image' => sub {
  my $dir = tmpdir();
  my $dest = $dir->child('disk.img');
  Disk::Diskette->create(source => $src, path => $dest);
  my $before = $dest->slurp_raw;

  error_like {
    Disk::Diskette->create(source => $src, path => $dest, force => 1, backend => Test::Backend::Failing->new(fail_on => 'die'))
  } qr/simulated backend failure/;
  is $dest->slurp_raw, $before, 'failed forced replacement keeps the old image';
  is leftovers($dir), [], 'temporary file cleaned up';

  my $e = error_like {
    Disk::Diskette->create(source => $src, path => $dest, force => 1, backend => Test::Backend::Failing->new(fail_on => 'skip'))
  } qr/image verification failed/;
  like "$e", qr{/B\.TXT is missing from the image};
  is $dest->slurp_raw, $before;
  is leftovers($dir), [];

  my $new = $dir->child('new.img');
  error_like {
    Disk::Diskette->create(source => $src, path => $new, backend => Test::Backend::Failing->new(fail_on => 'die'))
  } qr/simulated/;
  ok !-e $new, 'nothing published';
};

subtest 'source changes while building' => sub {
  my $dir = tmpdir();
  my $changing = make_tree(tmpdir('changing'), 'a.txt' => 'alpha', 'b.txt' => 'beta');
  my $backend = Test::Backend::Failing->new(hook => sub ($path, $host, $dos_path) {
    $changing->child('b.txt')->spew('beta changed and longer') if $dos_path eq '/A.TXT';
  });
  my $e = error_like { Disk::Diskette->create(source => $changing, path => $dir->child('c.img'), backend => $backend) } qr/image verification failed/;
  like "$e", qr/source file changed while the image was being built/;
  ok !-e $dir->child('c.img');
};

subtest 'missing mtools' => sub {
  my $dir = tmpdir();
  my $backend = Disk::Diskette::Backend::Mtools->new(path => []);
  error_like { Disk::Diskette->create(source => $src, path => $dir->child('m.img'), backend => $backend) } qr/unable to find the mtools program/;
  is leftovers($dir), [];
  local $ENV{PATH} = '';
  error_like { Disk::Diskette->create(source => $src, path => $dir->child('m.img')) } qr/unable to find the mtools program/;
};

subtest 'unreadable source' => sub {
  skip_all 'running as root' if $> == 0;
  my $locked = make_tree(tmpdir('locked'), 'secret.txt' => 'x');
  chmod 0000, $locked->child('secret.txt');
  my $dir = tmpdir();
  error_like { Disk::Diskette->create(source => $locked, path => $dir->child('l.img')) } qr/unable to read file/;
  ok !-e $dir->child('l.img');
};

subtest 'disk full is caught before writing' => sub {
  my $dir = tmpdir();
  my $big = make_tree(tmpdir('big'), 'big' => \400_000);
  error_like { Disk::Diskette->create(source => $big, path => $dir->child('f.img'), format => '360k') } qr/does not fit/;
  is leftovers($dir), [];
};

done_testing;
