use v5.42;
use Test2::V0 -no_srand => 1;
use Disk::Diskette::Format;

my $class = 'Disk::Diskette::Format';

is [ $class->fixed_names ], [qw( 160k 180k 320k 360k 720k 1200k 1440k 2880k )], 'fixed names';
is [ $class->auto_names ], [qw( auto-360k auto-720k auto-1200k auto-1440k auto-2880k )], 'auto names';
is $class->default_selector, 'auto-1440k';

# name cyl heads spt bytes media spc root fat clusters
my @table = (
  [ '160k',  40, 1,  8,  163840, 0xFE, 1,  64, 1,  313 ],
  [ '180k',  40, 1,  9,  184320, 0xFC, 1,  64, 2,  351 ],
  [ '320k',  40, 2,  8,  327680, 0xFF, 2, 112, 1,  315 ],
  [ '360k',  40, 2,  9,  368640, 0xFD, 2, 112, 2,  354 ],
  [ '720k',  80, 2,  9,  737280, 0xF9, 2, 112, 3,  713 ],
  [ '1200k', 80, 2, 15, 1228800, 0xF9, 1, 224, 7, 2371 ],
  [ '1440k', 80, 2, 18, 1474560, 0xF0, 1, 224, 9, 2847 ],
  [ '2880k', 80, 2, 36, 2949120, 0xF0, 2, 240, 9, 2863 ],
);

for my $row (@table) {
  my($name, $c, $h, $s, $bytes, $media, $spc, $root, $fat, $clusters) = @$row;
  subtest $name => sub {
    my $f = $class->get($name);
    isa_ok $f, $class;
    is $f->name, $name;
    is $f->cylinders, $c;
    is $f->heads, $h;
    is $f->sectors_per_track, $s;
    is $f->size_bytes, $bytes;
    is $f->media_descriptor, $media;
    is $f->sectors_per_cluster, $spc;
    is $f->root_entries, $root;
    is $f->fat_sectors, $fat;
    is $f->reserved_sectors, 1;
    is $f->fat_count, 2;
    is $f->cluster_count, $clusters, 'cluster count';
    ok $f->cluster_count < 4085, 'FAT12 cluster limit';
    ok $f->fat_sectors * 512 * 2 / 3 >= $f->cluster_count + 2, 'FAT large enough';
    is $f->data_bytes, $clusters * $spc * 512;
    is $f->display_name, uc $name;
    is $f->root_dir_start_sector, 1 + 2 * $fat;
    is $f->data_start_sector, 1 + 2 * $fat + $root * 32 / 512;
    is $class->get(uc $name), exact_ref($f), 'case-insensitive lookup';
    is [ $class->candidates($name) ], [ exact_ref($f) ], 'fixed candidates';
    is $class->from_bpb(
      total_sectors => $f->total_sectors, bytes_per_sector => 512, sectors_per_cluster => $spc,
      reserved_sectors => 1, fat_count => 2, root_entries => $root, media_descriptor => $media,
      fat_sectors => $fat, sectors_per_track => $s, heads => $h,
    ), exact_ref($f), 'from_bpb';
  };
}

is [ map { $_->name } $class->candidates('auto-360k') ],  ['360k'];
is [ map { $_->name } $class->candidates('auto-720k') ],  ['720k'];
is [ map { $_->name } $class->candidates('auto-1200k') ], ['360k', '1200k'];
is [ map { $_->name } $class->candidates('auto-1440k') ], ['720k', '1440k'];
is [ map { $_->name } $class->candidates('AUTO-2880K') ], ['720k', '1440k', '2880k'];

ok $class->is_selector('auto-1440k');
ok $class->is_selector('360k');
ok !$class->is_selector('1.44m');
ok !$class->is_selector(undef);
ok $class->is_auto('auto-720k');
ok !$class->is_auto('720k');
is $class->check_selector('AUTO-720K'), 'auto-720k';

like dies { $class->get('auto-1440k') }, qr/not a fixed format/;
like dies { $class->candidates('bogus') }, qr/unknown format: bogus/;
is $class->from_bpb(total_sectors => 2880), undef, 'incomplete bpb';

is [ map { $_->name } $class->all ], [ $class->fixed_names ];

done_testing;
