package Disk::Diskette::Format;

use v5.42;
use warnings;
use Moo 2;
use Disk::Diskette::Error;

# ABSTRACT: Floppy geometry registry and FAT12 layout
# VERSION

=head1 SYNOPSIS

 use Disk::Diskette::Format;

 my $format = Disk::Diskette::Format->get('1440k');
 say $format->size_bytes;      # 1474560
 say $format->cluster_count;   # 2847

 my @candidates = Disk::Diskette::Format->candidates('auto-1200k');  # 360k, 1200k

=head1 DESCRIPTION

The format registry is the single source of truth for supported
geometries, their FAT12 layouts, the automatic selectors and their
candidate lists.  Format objects are immutable.

All formats use 512 byte sectors, one reserved (boot) sector and two
FAT copies.

 Selector  C  H  S   Bytes    Media  Cluster  Root  FAT sectors
 160k      40 1  8   163840   0xFE   1        64    1
 180k      40 1  9   184320   0xFC   1        64    2
 320k      40 2  8   327680   0xFF   2        112   1
 360k      40 2  9   368640   0xFD   2        112   2
 720k      80 2  9   737280   0xF9   2        112   3
 1200k     80 2  15  1228800  0xF9   1        224   7
 1440k     80 2  18  1474560  0xF0   1        224   9
 2880k     80 2  36  2949120  0xF0   2        240   9

Automatic selectors choose the first candidate (smallest first) that
can hold the content:

 auto-360k    360k
 auto-720k    720k
 auto-1200k   360k, 1200k
 auto-1440k   720k, 1440k      (default)
 auto-2880k   720k, 1440k, 2880k

=head1 ATTRIBUTES

=head2 name

The fixed selector, for example C<1440k>.

=head2 cylinders

=head2 heads

=head2 sectors_per_track

=head2 bytes_per_sector

=head2 media_descriptor

=head2 sectors_per_cluster

=head2 reserved_sectors

=head2 fat_count

=head2 fat_sectors

Sectors per FAT copy.

=head2 root_entries

Maximum number of root directory entries.

=head2 description

Short human readable description of the conventional media.

=cut

has name                => ( is => 'ro', required => 1 );
has cylinders           => ( is => 'ro', required => 1 );
has heads               => ( is => 'ro', required => 1 );
has sectors_per_track   => ( is => 'ro', required => 1 );
has bytes_per_sector    => ( is => 'ro', default => 512 );
has media_descriptor    => ( is => 'ro', required => 1 );
has sectors_per_cluster => ( is => 'ro', required => 1 );
has reserved_sectors    => ( is => 'ro', default => 1 );
has fat_count           => ( is => 'ro', default => 2 );
has fat_sectors         => ( is => 'ro', required => 1 );
has root_entries        => ( is => 'ro', required => 1 );
has description         => ( is => 'ro', required => 1 );

=head1 METHODS

=head2 total_sectors

=cut

sub total_sectors ($self) { $self->cylinders * $self->heads * $self->sectors_per_track }

=head2 size_bytes

Raw image length in bytes.

=cut

sub size_bytes ($self) { $self->total_sectors * $self->bytes_per_sector }

=head2 cluster_bytes

=cut

sub cluster_bytes ($self) { $self->sectors_per_cluster * $self->bytes_per_sector }

=head2 root_dir_sectors

=cut

sub root_dir_sectors ($self) {
  my $bytes = $self->root_entries * 32;
  int(($bytes + $self->bytes_per_sector - 1) / $self->bytes_per_sector);
}

=head2 fat_start_sector

=head2 root_dir_start_sector

=head2 data_start_sector

=cut

sub fat_start_sector      ($self) { $self->reserved_sectors }
sub root_dir_start_sector ($self) { $self->fat_start_sector + $self->fat_count * $self->fat_sectors }
sub data_start_sector     ($self) { $self->root_dir_start_sector + $self->root_dir_sectors }

=head2 cluster_count

Number of allocatable data clusters.

=cut

sub cluster_count ($self) {
  int(($self->total_sectors - $self->data_start_sector) / $self->sectors_per_cluster);
}

=head2 data_bytes

Allocatable bytes in an empty filesystem (C<cluster_count * cluster_bytes>).

=cut

sub data_bytes ($self) { $self->cluster_count * $self->cluster_bytes }

=head2 display_name

Uppercase form used in messages, for example C<720K>.

=cut

sub display_name ($self) { uc $self->name }

my @FIXED = (
  [ '160k',  40, 1,  8, 0xFE, 1,  64, 1, '5.25" single-sided double-density (DOS 1.0)' ],
  [ '180k',  40, 1,  9, 0xFC, 1,  64, 2, '5.25" single-sided double-density' ],
  [ '320k',  40, 2,  8, 0xFF, 2, 112, 1, '5.25" double-sided double-density (DOS 1.1)' ],
  [ '360k',  40, 2,  9, 0xFD, 2, 112, 2, '5.25" double-sided double-density' ],
  [ '720k',  80, 2,  9, 0xF9, 2, 112, 3, '3.5" double-density' ],
  [ '1200k', 80, 2, 15, 0xF9, 1, 224, 7, '5.25" high-density' ],
  [ '1440k', 80, 2, 18, 0xF0, 1, 224, 9, '3.5" high-density' ],
  [ '2880k', 80, 2, 36, 0xF0, 2, 240, 9, '3.5" extra-high-density' ],
);

my %FIXED;
my @FIXED_NAMES;
for my $row (@FIXED) {
  my %args;
  @args{qw( name cylinders heads sectors_per_track media_descriptor sectors_per_cluster root_entries fat_sectors description )} = @$row;
  push @FIXED_NAMES, $args{name};
  $FIXED{$args{name}} = __PACKAGE__->new(%args);
}

my @AUTO = (
  [ 'auto-360k',  [qw( 360k )] ],
  [ 'auto-720k',  [qw( 720k )] ],
  [ 'auto-1200k', [qw( 360k 1200k )] ],
  [ 'auto-1440k', [qw( 720k 1440k )] ],
  [ 'auto-2880k', [qw( 720k 1440k 2880k )] ],
);
my %AUTO = map { $_->[0] => $_->[1] } @AUTO;
my @AUTO_NAMES = map { $_->[0] } @AUTO;

=head1 CLASS METHODS

=head2 fixed_names

 my @names = Disk::Diskette::Format->fixed_names;

Fixed selectors, smallest first.

=cut

sub fixed_names ($class) { @FIXED_NAMES }

=head2 auto_names

 my @names = Disk::Diskette::Format->auto_names;

=cut

sub auto_names ($class) { @AUTO_NAMES }

=head2 selectors

All fixed and automatic selectors.

=cut

sub selectors ($class) { (@FIXED_NAMES, @AUTO_NAMES) }

=head2 default_selector

C<auto-1440k>.

=cut

sub default_selector ($class) { 'auto-1440k' }

=head2 all

 my @formats = Disk::Diskette::Format->all;

All fixed format objects, smallest first.

=cut

sub all ($class) { map { $FIXED{$_} } @FIXED_NAMES }

=head2 is_selector

 my $bool = Disk::Diskette::Format->is_selector($string);

=cut

sub is_selector ($class, $name) {
  return !!0 unless defined $name;
  my $lc = lc $name;
  !!($FIXED{$lc} || $AUTO{$lc});
}

=head2 is_auto

=cut

sub is_auto ($class, $name) { !!(defined $name && $AUTO{lc $name}) }

=head2 get

 my $format = Disk::Diskette::Format->get('720k');

Returns the fixed format object; throws for an unknown or automatic selector.

=cut

sub get ($class, $name) {
  my $format = defined $name ? $FIXED{lc $name} : undef;
  return $format if $format;
  Disk::Diskette::Error->throw(
    "not a fixed format: @{[ $name // 'undef' ]}",
    "fixed formats are: @FIXED_NAMES",
  );
}

=head2 candidates

 my @formats = Disk::Diskette::Format->candidates($selector);

Candidate formats for a selector in order; a fixed selector yields just
that format.  Throws for an unknown selector.

=cut

sub candidates ($class, $name) {
  $class->check_selector($name);
  my $lc = lc $name;
  return $FIXED{$lc} if $FIXED{$lc};
  map { $FIXED{$_} } $AUTO{$lc}->@*;
}

=head2 check_selector

 my $normalized = Disk::Diskette::Format->check_selector($selector);

Returns the lowercase selector or throws a descriptive error.

=cut

sub check_selector ($class, $name) {
  return lc $name if $class->is_selector($name);
  Disk::Diskette::Error->throw(
    "unknown format: @{[ $name // 'undef' ]}",
    "valid formats are: @{[ $class->selectors ]}",
  );
}

=head2 from_bpb

 my $format = Disk::Diskette::Format->from_bpb(%bpb);

Returns the registered format matching the given boot sector parameters
(C<bytes_per_sector>, C<sectors_per_cluster>, C<reserved_sectors>,
C<fat_count>, C<root_entries>, C<total_sectors>, C<media_descriptor>,
C<fat_sectors>, C<sectors_per_track>, C<heads>), or C<undef>.

=cut

sub from_bpb ($class, %bpb) {
  my @fields = qw(
    total_sectors bytes_per_sector sectors_per_cluster reserved_sectors
    fat_count root_entries media_descriptor fat_sectors sectors_per_track heads
  );
  FORMAT: for my $format ($class->all) {
    for my $field (@fields) {
      next FORMAT unless defined $bpb{$field} && $bpb{$field} == $format->$field;
    }
    return $format;
  }
  return undef;
}
