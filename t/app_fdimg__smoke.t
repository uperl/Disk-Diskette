use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Capture::Tiny qw( capture );

my $script = path('bin/fdimg')->absolute;
my $lib    = path('lib')->absolute;

sub fdimg (@args) {
  my($out, $err, $exit) = capture { system $^X, "-I$lib", "$script", @args; $? >> 8 };
  return { out => $out, err => $err, exit => $exit };
}

ok -f $script, 'script exists';

my $r = fdimg('--version');
is $r->{exit}, 0;
like $r->{out}, qr/\Afdimg version/;

$r = fdimg();
is $r->{exit}, 0, 'no arguments shows help';
like $r->{out}, qr/Usage: fdimg/;

$r = fdimg('bogus');
is $r->{exit}, 2, 'usage error status';

require_mtools();

my $work = tmpdir('work');
my $src = make_tree($work->child('smoke'), 'hello.txt' => 'hello');

$r = fdimg('create', "$src", $work->child('smoke.img')->stringify);
is $r->{exit}, 0, 'create';
like $r->{out}, qr/Created .*smoke\.img \(720K FAT12\)/;

$r = fdimg('validate', $work->child('smoke.img')->stringify);
is $r->{exit}, 0, 'validate';

$r = fdimg('info', $work->child('missing.img')->stringify);
is $r->{exit}, 1, 'operation failure status';

done_testing;
