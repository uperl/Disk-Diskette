use v5.42;
use Test2::V0 -no_srand => 1;
use Disk::Diskette::Entry;

my $file = Disk::Diskette::Entry->new(
  name => 'README.TXT', path => '/DOCS/README.TXT', type => 'file',
  size => 42, mtime => 946684800, attributes => 0x21,
);

ok $file->is_file;
ok !$file->is_directory;
is $file->size, 42;
is $file->mtime, 946684800;
ok $file->is_read_only;
ok $file->is_archive;
ok !$file->is_hidden;
ok !$file->is_system;
is $file->attribute_string, 'R--A';

my $dir = Disk::Diskette::Entry->new(name => 'DOCS', path => '/DOCS', type => 'directory', attributes => 0x06);
ok $dir->is_directory;
is $dir->size, 0;
is $dir->attribute_string, '-HS-';

done_testing;
