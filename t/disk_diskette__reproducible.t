use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;

require_mtools();

my $epoch = 1700000000;
my $src = make_tree(tmpdir('repro'), 'a.txt' => 'alpha', 'sub/b.txt' => 'beta', 'sub/deep/' => undef);
utime 1600000000, 1600000000, $src->child('a.txt');
utime 1800000000, 1800000000, $src->child('sub/b.txt');

sub build ($name, %args) {
  Disk::Diskette->create(source => $src, path => tmpdir()->child($name), source_date_epoch => $epoch, %args);
}

my $one = build('one.img');
sleep 2;
my $two = build('two.img');

ok $one->path->slurp_raw eq $two->path->slurp_raw, 'repeated builds are byte-for-byte identical';
is $one->serial, $two->serial, 'deterministic serial';
is $one->serial, sprintf('%04X-%04X', $epoch >> 16, $epoch & 0xFFFF), 'serial is the epoch';
is $one->lookup('/A.TXT')->mtime, 1600000000, 'older file keeps its mtime';
is $one->lookup('/SUB/B.TXT')->mtime, $epoch, 'newer file clamped to SOURCE_DATE_EPOCH';
is $one->lookup('/SUB')->mtime, $epoch, 'directory uses SOURCE_DATE_EPOCH';
is $one->lookup('/SUB/DEEP')->mtime, $epoch;

{
  local $ENV{SOURCE_DATE_EPOCH} = $epoch;
  my $env = Disk::Diskette->create(source => $src, path => tmpdir()->child('env.img'));
  ok $env->path->slurp_raw eq $one->path->slurp_raw, 'SOURCE_DATE_EPOCH environment variable honored';
  my $off = Disk::Diskette->create(source => $src, path => tmpdir()->child('off.img'), source_date_epoch => undef);
  isnt $off->lookup('/SUB')->mtime, $epoch, 'explicit undef disables reproducible mode';
}

my $other = build('other.img', source_date_epoch => $epoch + 86400);
isnt $other->serial, $one->serial, 'serial depends on the epoch';

done_testing;
