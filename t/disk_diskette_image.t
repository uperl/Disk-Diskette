use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;
use Disk::Diskette::Image;

require_mtools();

my $src = make_tree(tmpdir('src'),
  'a.txt'     => 'alpha',
  'sub/b.txt' => 'beta',
  'sub/c/'    => undef,
);
utime 1000000000, 1000000000, $src->child('a.txt');
my $path = tmpdir()->child('disk.img');
Disk::Diskette->create(source => $src, path => $path, label => 'IMG');

subtest 'open and metadata' => sub {
  my $image = Disk::Diskette::Image->open($path);
  isa_ok $image, 'Disk::Diskette::Image';
  is $image->path->stringify, "$path";
  is $image->format, '720k';
  isa_ok $image->geometry, 'Disk::Diskette::Format';
  is $image->geometry->cylinders, 80;
  is $image->label, 'IMG';
  like $image->serial, qr/\A[0-9A-F]{4}-[0-9A-F]{4}\z/;
  is $image->size_bytes, 737280;
  is $image->free_bytes, (713 - 4) * 1024;
  is $path->slurp_raw, Disk::Diskette->open($path)->path->slurp_raw, 'open does not modify';
};

subtest 'entries' => sub {
  my $image = Disk::Diskette->open($path);
  my @root = $image->entries;
  is [ map { $_->name } @root ], [ 'SUB', 'A.TXT' ];
  my($file) = grep { $_->name eq 'A.TXT' } @root;
  is $file->size, 5;
  is $file->mtime, 1000000000;
  is $file->type, 'file';
  ok $file->is_archive;
  is [ map { $_->path } $image->entries('/sub') ], [ '/SUB/C', '/SUB/B.TXT' ];
  is [ map { $_->path } $image->walk ], [ '/SUB', '/SUB/C', '/SUB/B.TXT', '/A.TXT' ];
  is $image->lookup('sub/b.txt')->size, 4;
  is $image->read_file('/sub/b.txt'), 'beta';
  error_like { $image->read_file('/nope') } qr/no such file in image: \/NOPE/;
  error_like { $image->read_file('/sub') } qr/not a file/;
  error_like { $image->entries('../x') } qr/may not contain/;
};

subtest 'validate' => sub {
  my $image = Disk::Diskette->open($path);
  is $image->validate, {
    path => "$path", format => '720k', files => 2, directories => 2,
    free_bytes => (713 - 4) * 1024, long_name_entries => 0,
  };
  my $bad = tmpdir()->child('bad.img');
  $path->copy($bad);
  my $data = $bad->slurp_raw;
  substr($data, 510, 2, "\0\0");
  $bad->spew_raw($data);
  my $e = error_like { Disk::Diskette->open($bad)->validate } qr/image is invalid: .*bad\.img/;
  like "$e", qr/boot sector signature/;
};

subtest 'open failures' => sub {
  my $dir = tmpdir();
  error_like { Disk::Diskette->open($dir->child('missing.img')) } qr/does not exist/;
  $dir->child('junk.img')->spew_raw('junk' x 1000);
  error_like { Disk::Diskette->open($dir->child('junk.img')) } qr/not a supported FAT12 floppy image/;
};

subtest 'extract_to' => sub {
  my $image = Disk::Diskette->open($path);
  my $dest = tmpdir('work')->child('out');
  my @written = $image->extract_to($dest);
  is [ map { $_->relative($dest)->stringify } @written ], [ 'SUB', 'SUB/C', 'SUB/B.TXT', 'A.TXT' ];
  is $dest->child('A.TXT')->slurp_raw, 'alpha';
  is $dest->child('SUB/B.TXT')->slurp_raw, 'beta';
  ok -d $dest->child('SUB/C');
  is $dest->child('A.TXT')->stat->mtime, 1000000000;

  my $e = error_like { $image->extract_to($dest) } qr/refusing to overwrite existing files/;
  is scalar $e->details->@*, 2, 'files conflict, directories do not';

  # existing empty directory structure is fine
  my $partial = tmpdir('work')->child('partial');
  $partial->child('SUB')->mkpath;
  ok lives { $image->extract_to($partial) };

  # a pre-existing symlink in the destination is never followed
  my $trap = tmpdir('trap');
  my $outside = tmpdir('outside');
  symlink "$outside", $trap->child('SUB') or die;
  $e = error_like { $image->extract_to($trap) } qr/refusing to overwrite/;
  like "$e", qr/SUB already exists/;
  is [ $outside->children ], [], 'nothing written through the symlink';

  my $file_link = tmpdir('trap2');
  my $victim = tmpdir('victim')->child('victim.txt');
  $victim->spew('precious');
  symlink "$victim", $file_link->child('A.TXT') or die;
  error_like { $image->extract_to($file_link) } qr/A\.TXT already exists/;
  is $victim->slurp, 'precious';

  my $link_dest = tmpdir('ld')->child('link');
  symlink tmpdir('real')->stringify, $link_dest or die;
  error_like { $image->extract_to($link_dest) } qr/destination is a symbolic link/;

  my $file_dest = tmpdir('fd')->child('file');
  $file_dest->spew('x');
  error_like { $image->extract_to($file_dest) } qr/not a directory/;

  error_like { $image->extract_to(tmpdir('np')->child('a/b')) } qr/parent of extraction destination does not exist/;
};

done_testing;
