package Disk::Diskette::Entry;

use v5.42;
use warnings;
use Moo 2;

# ABSTRACT: Directory entry in a floppy image
# VERSION

=head1 SYNOPSIS

 use v5.42;
 use warnings;
 use Disk::Diskette;

 my $image = Disk::Diskette->open('disk.img');
 for my $entry ($image->entries('/')) {
   say $entry->path, $entry->is_directory ? '/' : ' ' . $entry->size;
 }

=head1 DESCRIPTION

Immutable structured metadata for one file or directory in an image, as
returned by L<Disk::Diskette::Image/entries>.

=head1 ATTRIBUTES

=head2 name

The DOS 8.3 name, for example C<README.TXT>.

=head2 path

Absolute image path using C</> separators, for example C</DOCS/README.TXT>.

=head2 type

C<file> or C<directory>.

=head2 size

File size in bytes (C<0> for directories).

=head2 mtime

Modification time as a Unix epoch, interpreting the FAT timestamp as UTC,
or C<undef> if the entry has no valid timestamp.

=head2 attributes

DOS attribute bits (read-only C<0x01>, hidden C<0x02>, system C<0x04>,
archive C<0x20>).

=cut

has name       => ( is => 'ro', required => 1 );
has path       => ( is => 'ro', required => 1 );
has type       => ( is => 'ro', required => 1 );
has size       => ( is => 'ro', default => 0 );
has mtime      => ( is => 'ro' );
has attributes => ( is => 'ro', default => 0 );
has cluster    => ( is => 'ro', default => 0 );

=head2 cluster

First data cluster (internal detail, C<0> for empty files).

=head1 METHODS

=head2 is_file

=head2 is_directory

=cut

sub is_file      ($self) { $self->type eq 'file' }
sub is_directory ($self) { $self->type eq 'directory' }

=head2 is_read_only

=head2 is_hidden

=head2 is_system

=head2 is_archive

=cut

sub is_read_only ($self) { !!($self->attributes & 0x01) }
sub is_hidden    ($self) { !!($self->attributes & 0x02) }
sub is_system    ($self) { !!($self->attributes & 0x04) }
sub is_archive   ($self) { !!($self->attributes & 0x20) }

=head2 attribute_string

Attributes in C<RHSA> order with C<-> for unset bits, for example C<---A>.

=cut

sub attribute_string ($self) {
  join '',
    $self->is_read_only ? 'R' : '-',
    $self->is_hidden    ? 'H' : '-',
    $self->is_system    ? 'S' : '-',
    $self->is_archive   ? 'A' : '-';
}
