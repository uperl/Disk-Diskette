package Disk::Diskette::Image;

use v5.42;
use warnings;
use Moo 2;
use Path::Tiny ();
use Fcntl qw( O_WRONLY O_CREAT O_EXCL O_NOFOLLOW S_ISDIR );
use Disk::Diskette::Error;
use Disk::Diskette::FAT12;

# ABSTRACT: A FAT12 floppy image
# VERSION

=head1 SYNOPSIS

 use v5.42;
 use warnings;
 use Disk::Diskette;

 my $image = Disk::Diskette->open('disk.img');

 say $image->format;             # 1440k
 say $image->label // '(none)';
 say $image->free_bytes;

 for my $entry ($image->entries('/')) {
   say $entry->path;
 }

 $image->validate;
 $image->extract_to('unpacked');

=head1 DESCRIPTION

An image object is returned by L<Disk::Diskette/create> and
L<Disk::Diskette/open>.  Metadata is read directly from the image file;
the object holds no open file handle.  Inspection methods read the image
afresh each time they are called.

Image paths use C</> separators independent of the host, are resolved
from the root, and are case-insensitive (they are normalized to
uppercase).  C<..>, drive letters and backslashes are rejected.

=head1 CONSTRUCTOR

=head2 open

 my $image = Disk::Diskette::Image->open($path);

Opens an existing image without modifying it.  Throws unless it has a
supported geometry and a FAT12 boot sector consistent with its length.
Use L</validate> for a full structural check.

=cut

has path     => ( is => 'ro', required => 1, coerce => sub ($p) { Path::Tiny::path($p) } );
has geometry => ( is => 'ro', required => 1 );
has label    => ( is => 'ro' );
has serial   => ( is => 'ro' );

sub open ($class, $path) {
  my $fs = Disk::Diskette::FAT12->load($path);
  return $class->new(
    path     => $path,
    geometry => $fs->format,
    label    => $fs->label,
    serial   => $fs->serial_string,
  );
}

sub _fs ($self) { Disk::Diskette::FAT12->load($self->path) }

=head1 ATTRIBUTES

=head2 path

The image path as a L<Path::Tiny>.

=head2 geometry

The image's L<Disk::Diskette::Format> object (cylinders, heads,
sectors per track and FAT layout).

=head2 label

The volume label, or C<undef> if unlabeled.

=head2 serial

The volume serial number formatted as C<XXXX-XXXX>, or C<undef>.

=head1 METHODS

=head2 format

The actual fixed format selector, for example C<720k>.

=cut

sub format ($self) { $self->geometry->name }

=head2 size_bytes

Raw image size in bytes.

=cut

sub size_bytes ($self) { $self->geometry->size_bytes }

=head2 free_bytes

Free allocatable data bytes.

=cut

sub free_bytes ($self) { $self->_fs->free_bytes }

=head2 entries

 my @entries = $image->entries;
 my @entries = $image->entries('/DOCS');

L<Disk::Diskette::Entry> objects for a directory (root by default), in
directory order, excluding the volume label and C<.>/C<..> entries.

=cut

sub entries ($self, $directory = '/') { $self->_fs->entries($directory) }

=head2 walk

 my @entries = $image->walk;

All entries recursively, parents before children.

=cut

sub walk ($self, $directory = '/') { $self->_fs->walk($directory) }

=head2 lookup

 my $entry = $image->lookup('/DOCS/README.TXT');

The entry for an image path, or C<undef>.

=cut

sub lookup ($self, $path) { $self->_fs->lookup($path) }

=head2 read_file

 my $bytes = $image->read_file('/DOCS/README.TXT');

Contents of a file in the image.

=cut

sub read_file ($self, $path) {
  my $fs = $self->_fs;
  my $entry = $fs->lookup($path);
  Disk::Diskette::Error->throw("no such file in image: @{[ $fs->normalize_path($path) ]}") unless $entry;
  Disk::Diskette::Error->throw("not a file in image: @{[ $entry->path ]}") unless $entry->is_file;
  $fs->read_file($entry);
}

=head2 validate

 my $result = $image->validate;

Checks the image layout and filesystem structure: geometry and length,
boot signature, FAT media byte, identical FAT copies, cluster chains
(range, termination, cross-links, length against file size), C<.> and
C<..> entries and lost clusters.  Throws a L<Disk::Diskette::Error>
listing every problem found; otherwise returns a hash reference with
C<path>, C<format>, C<files>, C<directories>, C<free_bytes> and
C<long_name_entries> (VFAT entries are legal but are not created by this
library).

=cut

sub validate ($self) {
  my $fs = Disk::Diskette::FAT12->load($self->path);
  my @problems = $fs->check;
  Disk::Diskette::Error->throw("image is invalid: @{[ $self->path ]}", @problems) if @problems;
  my @all = $fs->walk;
  return {
    path              => $self->path->stringify,
    format            => $fs->format->name,
    files             => scalar(grep { $_->is_file } @all),
    directories       => scalar(grep { $_->is_directory } @all),
    free_bytes        => $fs->free_bytes,
    long_name_entries => $fs->long_name_entries,
  };
}

=head2 extract_to

 my @paths = $image->extract_to($host_directory);

Extracts the whole image into a host directory, which is created if it
does not exist (its parent must exist).  Names are kept exactly as
stored (uppercase 8.3).  File modification times are restored.

Extraction never overwrites: every destination is checked before
anything is written, and any existing file, symlink or non-directory in
the way is an error.  Existing real directories are reused.  Files are
created exclusively and without following symlinks, so extraction cannot
escape the destination.  Returns the host paths written.

=cut

sub extract_to ($self, $dest) {
  my $fs = $self->_fs;
  $dest = Path::Tiny::path($dest);

  if(my @st = lstat $dest) {
    Disk::Diskette::Error->throw("extraction destination is a symbolic link: $dest") if -l _;
    Disk::Diskette::Error->throw("extraction destination is not a directory: $dest") unless S_ISDIR($st[2]);
  } else {
    Disk::Diskette::Error->throw("parent of extraction destination does not exist: $dest") unless -d $dest->parent;
  }

  my @entries = $fs->walk;
  my @conflicts;
  for my $entry (@entries) {
    my $host = $dest->child(substr $entry->path, 1);
    next unless my @st = lstat $host;
    next if $entry->is_directory && !-l _ && S_ISDIR($st[2]);
    push @conflicts, "$host already exists";
  }
  Disk::Diskette::Error->throw("refusing to overwrite existing files in $dest", @conflicts) if @conflicts;

  unless(-d $dest) {
    mkdir $dest or Disk::Diskette::Error->throw("unable to create directory: $dest", "$!");
  }

  my @written;
  for my $entry (@entries) {
    my $host = $dest->child(substr $entry->path, 1);
    if($entry->is_directory) {
      unless(-d $host && !-l $host) {
        mkdir $host or Disk::Diskette::Error->throw("unable to create directory: $host", "$!");
      }
    } else {
      my $data = $fs->read_file($entry);
      sysopen my $fh, "$host", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0666
        or Disk::Diskette::Error->throw("unable to create file: $host", "$!");
      binmode $fh;
      print {$fh} $data or Disk::Diskette::Error->throw("unable to write file: $host", "$!");
      close $fh or Disk::Diskette::Error->throw("unable to write file: $host", "$!");
    }
    push @written, $host;
  }

  # restore times after all writes so directory times are not disturbed
  for my $entry (reverse @entries) {
    next unless defined $entry->mtime;
    my $host = $dest->child(substr $entry->path, 1);
    utime $entry->mtime, $entry->mtime, "$host";
  }

  return @written;
}
