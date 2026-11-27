package Disk::Diskette::FAT12;

use v5.42;
use warnings;
use Moo 2;
use Path::Tiny ();
use Time::Local ();
use Disk::Diskette::Error;
use Disk::Diskette::Format;
use Disk::Diskette::Entry;

# ABSTRACT: Read-only FAT12 image parser and checker (internal)
# VERSION

=head1 SYNOPSIS

 use Disk::Diskette::FAT12;

 my $fs = Disk::Diskette::FAT12->load('disk.img');
 say $fs->format->name;
 say $_->path for $fs->entries('/');

=head1 DESCRIPTION

This module is internal to L<Disk::Diskette>; its interface may change.

It reads image metadata and file contents directly, so that inspection,
verification and extraction do not depend on parsing human readable
mtools output.  It never modifies an image.  Images are small, so the
whole image is held in memory.

VFAT long file name entries are skipped (and counted) rather than
interpreted.

=head1 CONSTRUCTOR

=head2 load

 my $fs = Disk::Diskette::FAT12->load($path);

Reads the image and parses its boot sector.  Throws unless the boot
sector describes one of the supported formats and the image has exactly
the expected length.

=head1 ATTRIBUTES

=head2 path

=head2 data

Raw image bytes.

=head2 format

The matching L<Disk::Diskette::Format>.

=head2 bpb

Hash reference of parsed boot sector fields.

=cut

has path   => ( is => 'ro', required => 1 );
has data   => ( is => 'ro', required => 1 );
has format => ( is => 'ro', required => 1 );
has bpb    => ( is => 'ro', required => 1 );

has _fat => ( is => q{lazy} );

sub load ($class, $path) {
  $path = Path::Tiny::path($path);
  Disk::Diskette::Error->throw("image does not exist: $path") unless -e $path;
  Disk::Diskette::Error->throw("image is not a regular file: $path") unless -f $path;
  my $data = eval { $path->slurp_raw };
  Disk::Diskette::Error->throw("unable to read image: $path", "$@" =~ s/\s+\z//r) unless defined $data;

  Disk::Diskette::Error->throw("not a supported floppy image: $path", "file is too short to contain a boot sector")
    if length $data < 512;

  my $bpb = _parse_bpb(substr $data, 0, 512);

  my $format = Disk::Diskette::Format->from_bpb(%$bpb);
  unless($format) {
    Disk::Diskette::Error->throw(
      "not a supported FAT12 floppy image: $path",
      sprintf(
        "boot sector describes %d sectors of %d bytes, %d heads, %d sectors/track, media 0x%02X, %d sectors/cluster, %d root entries, %d FAT sectors",
        map { $_ // 0 } $bpb->@{qw( total_sectors bytes_per_sector heads sectors_per_track media_descriptor sectors_per_cluster root_entries fat_sectors )},
      ),
      "supported formats are: @{[ Disk::Diskette::Format->fixed_names ]}",
    );
  }

  if(length $data != $format->size_bytes) {
    Disk::Diskette::Error->throw(
      "image length does not match its geometry: $path",
      sprintf("boot sector describes %s (%d bytes), file is %d bytes", $format->name, $format->size_bytes, length $data),
    );
  }

  return $class->new( path => $path, data => $data, format => $format, bpb => $bpb );
}

sub _parse_bpb ($sector) {
  my %bpb;
  @bpb{qw( jump oem bytes_per_sector sectors_per_cluster reserved_sectors fat_count root_entries total_sectors media_descriptor fat_sectors sectors_per_track heads hidden_sectors large_sectors drive reserved ext_signature serial bpb_label fs_type )}
    = unpack 'a3 a8 v C v C v v C v v v V V C C C V a11 a8', $sector;
  $bpb{total_sectors} = $bpb{large_sectors} if !$bpb{total_sectors};
  $bpb{boot_signature} = unpack 'v', substr $sector, 510, 2;
  return \%bpb;
}

sub _sector_bytes ($self, $sector, $count = 1) {
  my $bps = $self->format->bytes_per_sector;
  substr $self->data, $sector * $bps, $count * $bps;
}

sub _build__fat ($self) {
  $self->_decode_fat(0);
}

sub _decode_fat ($self, $copy) {
  my $format = $self->format;
  my $raw = $self->_sector_bytes($format->fat_start_sector + $copy * $format->fat_sectors, $format->fat_sectors);
  my $entries = $format->cluster_count + 2;
  my @fat;
  for my $n (0 .. $entries - 1) {
    my $offset = int($n * 3 / 2);
    my $pair = unpack 'v', substr($raw, $offset, 2);
    push @fat, $n & 1 ? $pair >> 4 : $pair & 0x0FFF;
  }
  return \@fat;
}

=head1 METHODS

=head2 serial

Volume serial number as an integer, or C<undef> without an extended BPB.

=cut

sub serial ($self) {
  return undef unless ($self->bpb->{ext_signature} // 0) == 0x29;
  return $self->bpb->{serial};
}

=head2 serial_string

Serial number formatted as DOS shows it, for example C<1234-ABCD>.

=cut

sub serial_string ($self) {
  my $serial = $self->serial;
  return undef unless defined $serial;
  sprintf '%04X-%04X', $serial >> 16, $serial & 0xFFFF;
}

=head2 label

The volume label from the root directory, or C<undef>.

=cut

sub label ($self) {
  for my $raw ($self->_raw_dir_entries(undef)) {
    next if $raw->{lfn};
    next unless $raw->{attr} & 0x08;
    return $raw->{label};
  }
  return undef;
}

=head2 free_clusters

=cut

sub free_clusters ($self) {
  my $fat = $self->_fat;
  scalar grep { $fat->[$_] == 0 } 2 .. $#$fat;
}

=head2 free_bytes

=cut

sub free_bytes ($self) { $self->free_clusters * $self->format->cluster_bytes }

=head2 long_name_entries

 my $count = $fs->long_name_entries;

Number of VFAT long name entries in the whole directory tree.

=cut

sub long_name_entries ($self) {
  my $count = 0;
  my %seen;
  my $walk = sub ($cluster) {
    for my $raw ($self->_raw_dir_entries($cluster)) {
      if($raw->{lfn}) {
        $count++;
      } elsif($raw->{attr} & 0x10 && _visible($raw) && $raw->{cluster} && !$seen{$raw->{cluster}}++) {
        __SUB__->($raw->{cluster});
      }
    }
  };
  $walk->(undef);
  return $count;
}

=head2 long_names

 my @pairs = $fs->long_names;

Each VFAT long name in the tree as C<[$short_path, $long_name]>.  Non-ASCII
characters are shown as C<\x{XXXX}>.

=cut

sub long_names ($self) {
  my @pairs;
  my %seen;
  my $walk = sub ($cluster, $path) {
    for my $raw ($self->_raw_dir_entries($cluster)) {
      next if $raw->{lfn};
      my $child = $path eq '/' ? "/$raw->{name}" : "$path/$raw->{name}";
      push @pairs, [ $child, $raw->{long_name} ] if defined $raw->{long_name};
      if($raw->{attr} & 0x10 && _visible($raw) && $raw->{cluster} && !$seen{$raw->{cluster}}++) {
        __SUB__->($raw->{cluster}, $child);
      }
    }
  };
  $walk->(undef, '/');
  return @pairs;
}

sub _chain ($self, $start) {
  my $fat = $self->_fat;
  my @chain;
  my %seen;
  my $cluster = $start;
  while($cluster >= 2 && $cluster <= $#$fat && !$seen{$cluster}++) {
    push @chain, $cluster;
    my $next = $fat->[$cluster];
    last if $next >= 0xFF8 || $next < 2;
    $cluster = $next;
  }
  return @chain;
}

sub _cluster_bytes ($self, @clusters) {
  my $format = $self->format;
  join '', map {
    $self->_sector_bytes($format->data_start_sector + ($_ - 2) * $format->sectors_per_cluster, $format->sectors_per_cluster)
  } @clusters;
}

sub _fat_time ($date, $time) {
  return undef unless $date;
  my $year  = (($date >> 9) & 0x7F) + 1980;
  my $month = ($date >> 5) & 0x0F;
  my $day   = $date & 0x1F;
  my $hour  = ($time >> 11) & 0x1F;
  my $min   = ($time >> 5) & 0x3F;
  my $sec   = ($time & 0x1F) * 2;
  my $epoch = eval { Time::Local::timegm_modern($sec, $min, $hour, $day, $month - 1, $year) };
  return $epoch;
}

# directory cluster undef => root
sub _raw_dir_entries ($self, $cluster) {
  my $bytes;
  if(defined $cluster && $cluster) {
    $bytes = $self->_cluster_bytes($self->_chain($cluster));
  } else {
    my $format = $self->format;
    $bytes = $self->_sector_bytes($format->root_dir_start_sector, $format->root_dir_sectors);
  }

  my @entries;
  my @fragments;
  for(my $offset = 0; $offset + 32 <= length $bytes; $offset += 32) {
    my $raw = substr $bytes, $offset, 32;
    my $first = ord $raw;
    last if $first == 0x00;
    next if $first == 0xE5;
    my($name, $attr, $nt, undef, undef, undef, undef, $hi, $wtime, $wdate, $start, $size)
      = unpack 'a11 C C C v v v v v v v V', $raw;
    if(($attr & 0x3F) == 0x0F) {
      push @entries, { lfn => 1, name => q{}, label => q{}, attr => $attr, cluster => 0, size => 0 };
      # UTF-16LE name fragment; entries are stored last fragment first
      unshift @fragments, substr($raw, 1, 10) . substr($raw, 14, 12) . substr($raw, 28, 4);
      next;
    }
    my $long_name;
    if(@fragments) {
      $long_name = join '', map { $_ < 0x80 ? chr : sprintf '\\x{%04X}', $_ } unpack 'v*', join '', @fragments;
      $long_name =~ s/\x00.*\z//s;
      @fragments = ();
    }
    substr($name, 0, 1, "\xE5") if $first == 0x05;
    my $base = substr($name, 0, 8) =~ s/ +\z//r;
    my $ext  = substr($name, 8, 3) =~ s/ +\z//r;
    push @entries, {
      raw_name => $name,
      name     => length $ext ? "$base.$ext" : $base,
      label    => ($name =~ s/ +\z//r),
      attr     => $attr,
      nt_flags => $nt,
      cluster  => $start,
      size     => $size,
      mtime    => _fat_time($wdate, $wtime),
      offset   => $offset,
      (defined $long_name ? (long_name => $long_name) : ()),
    };
  }
  return @entries;
}

sub _entry_object ($self, $raw, $parent_path) {
  my $is_dir = $raw->{attr} & 0x10;
  Disk::Diskette::Entry->new(
    name       => $raw->{name},
    path       => $parent_path eq '/' ? "/$raw->{name}" : "$parent_path/$raw->{name}",
    type       => $is_dir ? 'directory' : 'file',
    size       => $is_dir ? 0 : $raw->{size},
    mtime      => $raw->{mtime},
    attributes => $raw->{attr} & 0x27,
    cluster    => $raw->{cluster},
  );
}

sub _visible ($raw) {
  return 0 if $raw->{lfn};
  return 0 if $raw->{attr} & 0x08;          # volume label
  return 0 if $raw->{name} eq '.' || $raw->{name} eq '..';
  return 1;
}

=head2 entries

 my @entries = $fs->entries($directory);

L<Disk::Diskette::Entry> objects for the directory (default C</>), in
on-disk order, excluding the volume label and C<.>/C<..>.

=cut

sub entries ($self, $directory = '/') {
  my $dir = $self->_lookup_directory($directory);
  map { $self->_entry_object($_, $dir->{path}) } grep { _visible($_) } $self->_raw_dir_entries($dir->{cluster});
}

=head2 walk

 my @entries = $fs->walk;

All entries, depth first, parents before children.

=cut

sub walk ($self, $directory = '/') {
  my @all;
  for my $entry ($self->entries($directory)) {
    push @all, $entry;
    push @all, $self->walk($entry->path) if $entry->is_directory;
  }
  return @all;
}

=head2 normalize_path

 my $path = Disk::Diskette::FAT12->normalize_path('sub//file.txt');  # /SUB/FILE.TXT

Normalizes an image path: C</> separators, relative to the root,
uppercase.  Throws for C<..>, drive syntax or backslashes.

=cut

sub normalize_path ($class, $path) {
  $path //= '/';
  Disk::Diskette::Error->throw("invalid image path: $path", 'drive and device syntax is not supported')
    if $path =~ /:/;
  Disk::Diskette::Error->throw("invalid image path: $path", 'use / as the separator')
    if $path =~ /\\/;
  my @parts;
  for my $part (split m{/+}, $path) {
    next if $part eq '' || $part eq '.';
    Disk::Diskette::Error->throw("invalid image path: $path", 'paths may not contain ..') if $part eq '..';
    push @parts, $part =~ tr/a-z/A-Z/r;
  }
  return '/' . join '/', @parts;
}

=head2 lookup

 my $entry = $fs->lookup('/SUB/FILE.TXT');

Returns the entry for an image path, or C<undef>.  The root has no entry.

=cut

sub lookup ($self, $path) {
  $path = $self->normalize_path($path);
  return undef if $path eq '/';
  my($parent, $name) = $path =~ m{\A(.*)/([^/]+)\z};
  $parent = '/' if $parent eq '';
  my $dir = eval { $self->_lookup_directory($parent) } or return undef;
  for my $raw ($self->_raw_dir_entries($dir->{cluster})) {
    next unless _visible($raw);
    return $self->_entry_object($raw, $dir->{path}) if $raw->{name} eq $name;
  }
  return undef;
}

sub _lookup_directory ($self, $path) {
  $path = $self->normalize_path($path);
  return { path => '/', cluster => undef } if $path eq '/';
  my $entry = $self->lookup($path);
  Disk::Diskette::Error->throw("no such directory in image: $path") unless $entry;
  Disk::Diskette::Error->throw("not a directory in image: $path") unless $entry->is_directory;
  return { path => $path, cluster => $entry->cluster };
}

=head2 read_file

 my $bytes = $fs->read_file($entry);

Contents of a file entry.

=cut

sub read_file ($self, $entry) {
  return '' unless $entry->size;
  my $bytes = $self->_cluster_bytes($self->_chain($entry->cluster));
  Disk::Diskette::Error->throw("file data is truncated in image: @{[ $entry->path ]}")
    if length $bytes < $entry->size;
  substr $bytes, 0, $entry->size;
}

=head2 check

 my @problems = $fs->check;

Checks the filesystem structure and returns a list of problems (empty if
consistent): boot signature, FAT media byte, identical FAT copies,
cluster chain validity, cross-linked and lost clusters, chain lengths
against file sizes, and C<.>/C<..> entries.

=cut

sub check ($self) {
  my @problems;
  my $format = $self->format;
  my $bpb = $self->bpb;

  push @problems, sprintf('boot sector signature is 0x%04X, expected 0xAA55', $bpb->{boot_signature})
    unless $bpb->{boot_signature} == 0xAA55;

  my $fat = $self->_fat;
  push @problems, sprintf('FAT media byte 0x%02X does not match media descriptor 0x%02X', $fat->[0] & 0xFF, $format->media_descriptor)
    unless ($fat->[0] & 0xFF) == $format->media_descriptor;

  for my $copy (1 .. $format->fat_count - 1) {
    my $other = $self->_decode_fat($copy);
    my @diff = grep { $fat->[$_] != $other->[$_] } 0 .. $#$fat;
    push @problems, "FAT copy @{[ $copy + 1 ]} differs from FAT copy 1 in @{[ scalar @diff ]} entries" if @diff;
  }

  my $cb = $format->cluster_bytes;
  my %owner;

  my $follow = sub ($path, $start) {
    my @chain;
    my $cluster = $start;
    while(1) {
      if($cluster < 2 || $cluster > $#$fat) {
        push @problems, "$path: cluster chain refers to invalid cluster $cluster";
        last;
      }
      if(defined $owner{$cluster}) {
        push @problems, "$path: cluster $cluster is cross-linked with $owner{$cluster}";
        last;
      }
      $owner{$cluster} = $path;
      push @chain, $cluster;
      my $next = $fat->[$cluster];
      last if $next >= 0xFF8;
      if($next == 0 || $next == 0xFF7 || ($next >= 0xFF0 && $next < 0xFF8)) {
        push @problems, sprintf "%s: cluster chain is broken at cluster %d (FAT entry 0x%03X)", $path, $cluster, $next;
        last;
      }
      $cluster = $next;
    }
    return @chain;
  };

  my $walk = sub ($path, $cluster, $parent_cluster) {
    my @raw = grep { !$_->{lfn} } $self->_raw_dir_entries($cluster);
    if(defined $cluster) {
      my($dot, $dotdot) = @raw;
      unless($dot && $dot->{name} eq '.' && $dot->{cluster} == $cluster) {
        push @problems, "$path: missing or incorrect '.' entry";
      }
      unless($dotdot && $dotdot->{name} eq '..' && $dotdot->{cluster} == ($parent_cluster // 0)) {
        push @problems, "$path: missing or incorrect '..' entry";
      }
    }
    my %names;
    for my $raw (@raw) {
      next if $raw->{lfn};
      next if $raw->{attr} & 0x08 && !defined $cluster;
      next if $raw->{name} eq '.' || $raw->{name} eq '..';
      my $child = $path eq '/' ? "/$raw->{name}" : "$path/$raw->{name}";
      push @problems, "$child: duplicate directory entry" if $names{$raw->{name}}++;
      if($raw->{attr} & 0x10) {
        unless($raw->{cluster}) {
          push @problems, "$child: directory has no clusters";
          next;
        }
        if(defined $owner{$raw->{cluster}}) {
          push @problems, "$child: cluster $raw->{cluster} is cross-linked with $owner{$raw->{cluster}}";
          next;
        }
        $follow->($child, $raw->{cluster});
        __SUB__->($child, $raw->{cluster}, $cluster);
      } elsif($raw->{size} == 0) {
        push @problems, "$child: empty file has cluster $raw->{cluster} allocated" if $raw->{cluster};
      } else {
        my @chain = $follow->($child, $raw->{cluster});
        my $expected = int(($raw->{size} + $cb - 1) / $cb);
        push @problems, "$child: size $raw->{size} needs $expected clusters but chain has @{[ scalar @chain ]}"
          if @chain != $expected;
      }
    }
  };
  $walk->('/', undef, undef);

  my @lost = grep { $fat->[$_] != 0 && $fat->[$_] != 0xFF7 && !defined $owner{$_} } 2 .. $#$fat;
  push @problems, "@{[ scalar @lost ]} lost clusters are allocated but not referenced" if @lost;

  return @problems;
}
