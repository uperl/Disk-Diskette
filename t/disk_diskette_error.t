use v5.42;
use Test2::V0 -no_srand => 1;
use Disk::Diskette::Error;

my $e = dies { Disk::Diskette::Error->throw('something failed', 'detail one', 'detail two') };

isa_ok $e, 'Disk::Diskette::Error';
is $e->message, 'something failed';
is $e->details, ['detail one', 'detail two'];
is "$e", "something failed\n  detail one\n  detail two\n", 'stringifies with details';
ok $e, 'boolean true';

my $plain = dies { Disk::Diskette::Error->throw('plain') };
is "$plain", "plain\n", 'no details';

done_testing;
