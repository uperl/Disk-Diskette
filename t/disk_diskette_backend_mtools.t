use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette::Backend::Mtools;
use Disk::Diskette::Format;
use Disk::Diskette::FAT12;

my $class = 'Disk::Diskette::Backend::Mtools';

subtest 'missing mtools' => sub {
  my $backend = $class->new(path => [ tmpdir('empty')->stringify ]);
  ok !$backend->available, 'not available';
  error_like { $backend->find_program('mformat') } qr/unable to find the mtools program 'mformat'.*install/s;
  error_like { $backend->run('mformat', []) } qr/unable to find/;
};

subtest 'subprocess failures (fake programs)' => sub {
  my $bin = tmpdir('bin');
  my %scripts = (
    mformat => "#!/bin/sh\necho oops >&2\nexit 3\n",
    mcopy   => "#!/bin/sh\nkill -TERM \$\$\n",
    mmd     => "#!/nonexistent/interpreter\n",
    mdir    => "#!/bin/sh\nenv\n",
  );
  for my $name (sort keys %scripts) {
    $bin->child($name)->spew_raw($scripts{$name});
    $bin->child($name)->chmod(0755);
  }
  my $backend = $class->new(path => [ "$bin" ]);
  ok $backend->available;

  my $e = error_like { $backend->run('mformat', ['-i', 'x y', '::']) } qr/mformat failed with exit status 3/;
  like "$e", qr/command: mformat -i 'x y' ::/, 'command shown';
  like "$e", qr/oops/, 'stderr shown';

  error_like { $backend->run('mcopy', []) } qr/mcopy was terminated by signal 15/;
  error_like { $backend->run('mmd', []) } qr/unable to run mmd/;

  local $ENV{MTOOLS_FOO} = 'bar';
  local $ENV{SOURCE_DATE_EPOCH} = 12345;
  local $ENV{LANG} = 'de_DE.UTF-8';
  my $env = { map { split /=/, $_, 2 } split /\n/, $backend->run('mdir', [])->{stdout} };
  is $env->{MTOOLS_FOO}, undef, 'inherited MTOOLS_ variables removed';
  is $env->{SOURCE_DATE_EPOCH}, undef, 'inherited SOURCE_DATE_EPOCH removed';
  is $env->{LANG}, undef, 'LANG removed';
  is $env->{LC_ALL}, 'C';
  is $env->{TZ}, 'UTC';
  is $env->{MTOOLS_NO_VFAT}, 1;
  is $env->{MTOOLS_SKIP_CHECK}, 1;
  is $env->{MTOOLS_LOWER_CASE}, 0;
  ok -d $env->{HOME}, 'private HOME';
  isnt $env->{HOME}, $ENV{HOME};
  is -s $env->{MTOOLSRC}, 0, 'empty MTOOLSRC';

  $env = { map { split /=/, $_, 2 } split /\n/, $backend->run('mdir', [], epoch => 946684800)->{stdout} };
  is $env->{SOURCE_DATE_EPOCH}, 946684800, 'requested epoch';

};

subtest 'real mtools' => sub {
  require_mtools();
  my $backend = $class->new;
  like $backend->version, qr/\A\d+\.\d+/, 'version';

  my $format = Disk::Diskette::Format->get('360k');
  my $img = tmpdir()->child('t.img');
  $img->spew_raw("\0" x $format->size_bytes);
  $backend->format_image($img, $format, label => 'TEST DISK');
  my $fs = Disk::Diskette::FAT12->load($img);
  is $fs->format->name, '360k';
  is $fs->label, 'TEST DISK';
  is [ $fs->check ], [];

  my $src = make_tree(tmpdir('src'), 'a.txt' => 'hello');
  utime 946684800, 946684800, $src->child('a.txt');
  $backend->make_directories($img, ['/D1', '/D1/D2']);
  $backend->copy_file($img, $src->child('a.txt'), '/D1/D2/A.TXT', mtime => 946684800);
  $fs = Disk::Diskette::FAT12->load($img);
  my $entry = $fs->lookup('/D1/D2/A.TXT');
  ok $entry, 'copied';
  is $entry->mtime, 946684800, 'mtime written as UTC';
  is $fs->read_file($entry), 'hello';
  is $fs->long_name_entries, 0;
  is [ $fs->check ], [];

  error_like { $backend->copy_file($img, $src->child('a.txt'), '/NODIR/A.TXT') } qr/mcopy failed/;
  error_like { $backend->format_image(tmpdir()->child('missing/x.img'), $format) } qr/mformat failed/;
};

done_testing;
