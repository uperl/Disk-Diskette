use v5.42;
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use Test::Diskette;
use Path::Tiny qw( path );
use Disk::Diskette;
use Disk::Diskette::Format;

require_mtools();

my $src = make_tree(tmpdir('content'),
  'command.com'  => \5000,
  'autoexec.bat' => "\@echo off\r\n",
  'dos/edit.com' => \20000,
  'dos/help/'    => undef,
  'empty.txt'    => '',
);

for my $format (Disk::Diskette::Format->all) {
  my $name = $format->name;
  subtest $name => sub {
    my $dir = tmpdir($name);

    my $empty = Disk::Diskette->create(path => $dir->child('empty.img'), format => $name);
    is -s $empty->path, $format->size_bytes, 'empty image length';
    is $empty->format, $name;
    is $empty->free_bytes, $format->data_bytes, 'all clusters free';

    my $data = $empty->path->slurp_raw;
    my($bps, $spc, $res, $nfat, $root, $total, $media, $fatsz, $spt, $heads) = unpack 'x11 v C v C v v C v v v', $data;
    is [ $bps, $spc, $res, $nfat, $root, $total, $media, $fatsz, $spt, $heads ],
       [ 512, $format->sectors_per_cluster, 1, 2, $format->root_entries, $format->total_sectors,
         $format->media_descriptor, $format->fat_sectors, $format->sectors_per_track, $format->heads ], 'BPB';
    is substr($data, 54, 8), 'FAT12   ', 'filesystem type';
    is ord(substr($data, $format->fat_start_sector * 512, 1)), $format->media_descriptor, 'FAT media byte';
    fsck_ok($empty->path, "$name empty: fsck.fat");

    my $full = Disk::Diskette->create(source => $src, path => $dir->child('full.img'), format => $name);
    is $full->format, $name;
    is $full->label, 'CONTENT';
    is -s $full->path, $format->size_bytes, 'populated image length';
    ok lives { $full->validate }, 'validates';
    fsck_ok($full->path, "$name populated: fsck.fat");
    is mdir_paths($full->path), [ '/AUTOEXEC.BAT', '/COMMAND.COM', '/DOS', '/DOS/EDIT.COM', '/DOS/HELP', '/EMPTY.TXT' ], 'mtools listing';

    my $out = $dir->child('out');
    $full->extract_to($out);
    is $out->child('COMMAND.COM')->slurp_raw, $src->child('command.com')->slurp_raw, 'round trip';
    is $out->child('DOS/EDIT.COM')->slurp_raw, $src->child('dos/edit.com')->slurp_raw, 'round trip nested';
  };
}

done_testing;
