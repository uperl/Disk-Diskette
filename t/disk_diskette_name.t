use v5.42;
use Test2::V0 -no_srand => 1;
use Disk::Diskette::Name qw( short_name volume_label );

subtest 'short_name valid' => sub {
  my %ok = (
    'readme.txt'   => 'README.TXT',
    'README.TXT'   => 'README.TXT',
    'ReadMe.Txt'   => 'README.TXT',
    'a'            => 'A',
    'abcdefgh.xyz' => 'ABCDEFGH.XYZ',
    'command.com'  => 'COMMAND.COM',
    'noext'        => 'NOEXT',
    'x.c'          => 'X.C',
    '12345678'     => '12345678',
    'a!#$%&()'     => 'A!#$%&()',
    '-@^_`{}~.x'   => '-@^_`{}~.X',
    'CONFIG.SYS'   => 'CONFIG.SYS',
    'CONSOLE'      => 'CONSOLE',
    'COM10'        => 'COM10',
  );
  for my $in (sort keys %ok) {
    my($name, $error) = short_name($in);
    is $name, $ok{$in}, "$in -> $ok{$in}";
    is $error, undef;
  }
};

subtest 'short_name invalid' => sub {
  my %bad = (
    ''             => qr/empty/,
    'abcdefghi'    => qr/base name is longer than 8/,
    'a.abcd'       => qr/extension is longer than 3/,
    'a.b.c'        => qr/more than one dot/,
    '.profile'     => qr/empty base/,
    'trailing.'    => qr/trailing dot/,
    'has space'    => qr/space/,
    "tab\tx"       => qr/control/,
    "caf\x{e9}"    => qr/non-ASCII/,
    "caf\xc3\xa9"  => qr/non-ASCII/,
    'a/b'          => qr/separator/,
    'a\\b'         => qr/separator/,
    'a+b'          => qr/'\+'/,
    'a,b'          => qr/','/,
    'a;b'          => qr/';'/,
    'a=b'          => qr/'='/,
    'a[b'          => qr/'\['/,
    'a]b'          => qr/'\]'/,
    'a*b'          => qr/'\*'/,
    'a?b'          => qr/'\?'/,
    'a"b'          => qr/'"'/,
    'a<b'          => qr/'<'/,
    'a|b'          => qr/'\|'/,
    'a:b'          => qr/':'/,
    "it's"         => qr/'''/,
    'con'          => qr/reserved/,
    'NUL.TXT'      => qr/reserved/,
    'com1.bat'     => qr/reserved/,
    'lpt9'         => qr/reserved/,
    'aux.c'        => qr/reserved/,
    'prn'          => qr/reserved/,
  );
  for my $in (sort keys %bad) {
    my($name, $error) = short_name($in);
    is $name, undef, "'$in' rejected";
    like $error, $bad{$in}, "reason for '$in'";
  }
  my($name, $error) = short_name(undef);
  is $name, undef;
};

subtest 'volume_label' => sub {
  is [ volume_label('utilities') ], ['UTILITIES', undef];
  is [ volume_label('My Disk') ],   ['MY DISK', undef], 'embedded space';
  is [ volume_label('ABCDEFGHIJK') ], ['ABCDEFGHIJK', undef], '11 characters';
  like [ volume_label('ABCDEFGHIJKL') ]->[1], qr/longer than 11/;
  like [ volume_label('') ]->[1], qr/empty/;
  like [ volume_label(' LEAD') ]->[1], qr/leading or trailing/;
  like [ volume_label('TRAIL ') ]->[1], qr/leading or trailing/;
  like [ volume_label('a.b') ]->[1], qr/'\.'/;
  like [ volume_label('a*b') ]->[1], qr/'\*'/;
  like [ volume_label("\x{e9}") ]->[1], qr/non-ASCII/;
  like [ volume_label("a\tb") ]->[1], qr/control/;
};

done_testing;
