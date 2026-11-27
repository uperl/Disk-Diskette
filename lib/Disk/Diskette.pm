package Disk::Diskette;

use v5.42;
use warnings;
use Path::Tiny ();
use Fcntl qw( O_WRONLY O_CREAT O_EXCL S_ISREG );
use Time::Local ();
use Disk::Diskette::Error;
use Disk::Diskette::Format;
use Disk::Diskette::Config;
use Disk::Diskette::Manifest;
use Disk::Diskette::FAT12;
use Disk::Diskette::Image;
use Disk::Diskette::Backend::Mtools;

# ABSTRACT: Perl library for creating and manipulating raw DOS FAT12 floppy images
# VERSION

=head1 SYNOPSIS

 use v5.42;
 use warnings;
 use Disk::Diskette;

 # utilities/ -> utilities.img, smallest of 720k or 1440k that fits
 my $disk = Disk::Diskette->create(source => './utilities');
 say $disk->format;   # actual selected fixed format
 say $disk->path;

 my $release = Disk::Diskette->create(
   source          => './utilities',
   path            => './release/disk.img',
   format          => 'auto-1200k',
   label           => 'UTILITIES',
   follow_symlinks => 1,
   exclude         => ['README.md'],
   force           => 1,
 );

 my $empty = Disk::Diskette->create(
   path   => 'blank.img',
   format => '360k',
   label  => undef,
 );

 my $existing = Disk::Diskette->open('disk.img');

=head1 DESCRIPTION

C<Disk::Diskette> creates and inspects raw (uncompressed sector dump)
DOS FAT12 floppy images, suitable for Gotek/FlashFloppy USB sticks,
emulators and release pipelines.  No root privileges, mounting or loop
devices are needed.  The L<fdimg> command is a thin interface to this
library.

Images are populated with strict DOS 8.3 names: host names must already
be legal short names (case is ignored and normalized to uppercase); no
long file names, aliases, truncation or sanitization are ever produced.
See L<Disk::Diskette::Manifest> for the source tree rules and
L<Disk::Diskette::Format> for the supported geometries.

The library is silent: it returns objects and throws
L<Disk::Diskette::Error> exceptions with descriptive messages.

=head1 REQUIREMENTS

The mtools programs (C<mformat>, C<mcopy>, C<mmd>) must be installed and
in C<PATH>.  They are available from most package managers, for example
C<apt install mtools>, C<dnf install mtools> or C<brew install mtools>.
Your own mtools configuration is not used; see
L<Disk::Diskette::Backend::Mtools>.

=head1 CLASS METHODS

=head2 create

 my $image = Disk::Diskette->create(%options);

Creates an image and returns a L<Disk::Diskette::Image> once it has been
verified and published.  Options:

=over 4

=item source

Host directory to copy.  Omit for an empty image (then C<path> is
required and the source-only options C<follow_symlinks>, C<exclude> and
C<config> are rejected).

=item path

Output image path.  Defaults to the source directory path with C<.img>
appended (for example C<utilities/> becomes C<utilities.img>).

=item format

A fixed format (C<360k>, ...) or automatic selector (C<auto-1440k>, ...);
defaults to C<auto-1440k>.  Automatic selectors choose the smallest
candidate that fits the content; see L<Disk::Diskette::Format>.

=item label

Volume label.  Omit to use the configuration or derive it from the
uppercase source directory name; C<undef> (or the empty string) means
unlabeled.  Empty images are unlabeled by default.

=item follow_symlinks

Follow symlinks to regular files (default true).  When false every
symlink in the source is an error.

=item exclude

Array reference of exclusion patterns, replacing any configured list
(an empty list clears it).  See L<Disk::Diskette::Manifest/EXCLUSION PATTERNS>.

=item config

Path of an explicit configuration file, or C<undef> to disable
discovery of C<.fdimg.toml>.  See L<Disk::Diskette::Config>.

=item force

Replace an existing image (atomically).  Without it an existing
destination is an error.

=item source_date_epoch

Reproducible mode timestamp (integer seconds since the Unix epoch, UTC).
Defaults to the C<SOURCE_DATE_EPOCH> environment variable when set;
C<undef> disables reproducible mode.  In reproducible mode file
timestamps are clamped to this time, directories and the volume label
use it, and the volume serial number is the low 32 bits of the epoch.

=back

Creation never modifies an existing image until the new one has been
fully built and verified in a temporary file beside the destination.
The destination must not be a symlink or non-regular file, and must not
be inside the source tree.

Concurrent writers to the same destination are not supported (there is
no locking).  Without C<force>, publication cannot overwrite an image
that appeared after the initial check; with C<force>, the last writer
wins.

=cut

my %CREATE_OPTIONS = map { $_ => 1 } qw(
  source path format label follow_symlinks exclude config force source_date_epoch backend
);

my $FAT_MIN_TIME = Time::Local::timegm_modern(0, 0, 0, 1, 0, 1980);
my $FAT_MAX_TIME = Time::Local::timegm_modern(58, 59, 23, 31, 11, 2107);

sub create ($class, %args) {
  for my $key (sort keys %args) {
    Disk::Diskette::Error->throw("unknown create option: $key") unless $CREATE_OPTIONS{$key};
  }

  my $source  = $args{source};
  my $backend = $args{backend} // Disk::Diskette::Backend::Mtools->new;

  my %config_args = map { exists $args{$_} ? ($_ => $args{$_}) : () } qw( format label follow_symlinks exclude config );

  if(defined $source) {
    $source = Path::Tiny::path($source);
    Disk::Diskette::Error->throw("source does not exist: $source") unless -e $source;
    Disk::Diskette::Error->throw("source is not a directory: $source") unless -d $source;
  } else {
    Disk::Diskette::Error->throw("an output path is required when creating an empty image") unless defined $args{path};
    my @bad = grep { exists $config_args{$_} } qw( follow_symlinks exclude config );
    Disk::Diskette::Error->throw("option not meaningful without a source: @bad") if @bad;
  }

  my $epoch = $class->_source_date_epoch(\%args);

  my $settings = Disk::Diskette::Config->resolve(
    source => $source,
    args   => \%config_args,
  );

  my $dest = $class->_output_path($source, $args{path});
  $class->_check_destination($dest, $source, $args{force});

  my $manifest;
  if(defined $source) {
    my @skip;
    push @skip, $settings->{config} if defined $settings->{config};
    $manifest = Disk::Diskette::Manifest->build(
      source          => $source,
      exclude         => $settings->{exclude},
      follow_symlinks => $settings->{follow_symlinks},
      skip            => \@skip,
    );
  }

  my $format = $class->_select_format($settings->{format}, $manifest, defined $settings->{label});
  my $label  = $settings->{label};

  # build in a temporary file beside the destination
  my $tmp = Path::Tiny->tempfile(TEMPLATE => '.fdimg-XXXXXXXX', DIR => $dest->parent->stringify, SUFFIX => '.img');
  $tmp->spew_raw("\0" x $format->size_bytes);

  # in reproducible mode the serial number is the low 32 bits of the epoch
  my $serial = defined $epoch ? $epoch & 0xFFFFFFFF : undef;
  $backend->format_image($tmp, $format, label => $label, epoch => $epoch, serial => $serial);

  if($manifest) {
    my @dirs = map { $_->{dos_path} } $manifest->directories;
    $backend->make_directories($tmp, \@dirs, epoch => $epoch);
    for my $file ($manifest->files) {
      my $mtime = $file->{mtime};
      $mtime = $epoch if defined $epoch && $mtime > $epoch;
      $mtime = $FAT_MIN_TIME if $mtime < $FAT_MIN_TIME;
      $mtime = $FAT_MAX_TIME if $mtime > $FAT_MAX_TIME;
      $backend->copy_file($tmp, $file->{source}, $file->{dos_path}, mtime => $mtime);
    }
  }

  $class->_verify($tmp, $format, $label, $manifest);

  $class->_publish($tmp, $dest, $args{force});

  return Disk::Diskette::Image->open($dest);
}

sub _source_date_epoch ($class, $args) {
  my($epoch, $from);
  if(exists $args->{source_date_epoch}) {
    ($epoch, $from) = ($args->{source_date_epoch}, 'source_date_epoch');
  } elsif(defined $ENV{SOURCE_DATE_EPOCH}) {
    ($epoch, $from) = ($ENV{SOURCE_DATE_EPOCH}, 'SOURCE_DATE_EPOCH');
  }
  return undef unless defined $epoch;
  Disk::Diskette::Error->throw("invalid $from: '$epoch'", 'expected a non-negative integer number of seconds since 1970-01-01T00:00:00Z')
    unless $epoch =~ /\A[0-9]+\z/;
  Disk::Diskette::Error->throw(
    "$from is outside the FAT timestamp range: $epoch",
    'FAT timestamps cover 1980-01-01T00:00:00Z to 2107-12-31T23:59:58Z',
  ) if $epoch < $FAT_MIN_TIME || $epoch > $FAT_MAX_TIME;
  return $epoch + 0;
}

sub _output_path ($class, $source, $path) {
  return Path::Tiny::path($path) if defined $path;
  my $base = Disk::Diskette::Config->source_basename($source);
  Disk::Diskette::Error->throw(
    "unable to derive an output path: source directory has no usable name",
    "give an explicit image path",
  ) unless defined $base;
  my $given = $source->basename;
  if($given ne '' && $given ne '.' && $given ne '..') {
    return Path::Tiny::path("$source.img");
  }
  return $source->realpath->parent->child("$base.img");
}

sub _check_destination ($class, $dest, $source, $force) {
  if(my @st = lstat $dest) {
    Disk::Diskette::Error->throw("destination is a symbolic link: $dest", 'refusing to write through a symlink') if -l _;
    Disk::Diskette::Error->throw("destination exists and is not a regular file: $dest") unless S_ISREG($st[2]);
    Disk::Diskette::Error->throw("destination already exists: $dest", 'use --force (API: force => 1) to replace it') unless $force;
  }
  my $parent = $dest->parent;
  Disk::Diskette::Error->throw("destination directory does not exist: $parent") unless -d $parent;

  if(defined $source) {
    my $src = $source->realpath;
    my $out = $parent->realpath->child($dest->basename);
    if($out eq $src || $src->subsumes($out)) {
      Disk::Diskette::Error->throw("destination is inside the source tree: $dest", 'write the image outside the source directory');
    }
  }
}

sub _select_format ($class, $selector, $manifest, $labeled) {
  my @candidates = Disk::Diskette::Format->candidates($selector);
  return $candidates[0] unless $manifest;
  my @reasons;
  for my $format (@candidates) {
    my @problems = $manifest->fits($format, label => $labeled);
    return $format unless @problems;
    push @reasons, map { "@{[ $format->name ]}: $_" } @problems;
  }
  Disk::Diskette::Error->throw(
    "source does not fit in $selector: @{[ $manifest->source ]}",
    @reasons,
  );
}

sub _verify ($class, $tmp, $format, $label, $manifest) {
  my $fs = eval { Disk::Diskette::FAT12->load($tmp) };
  Disk::Diskette::Error->throw('backend produced an unreadable image', $@ =~ /(.+)/) unless $fs;

  my @problems;
  push @problems, "image length is @{[ -s $tmp ]}, expected @{[ $format->size_bytes ]}"
    unless -s $tmp == $format->size_bytes;
  push @problems, "backend produced format @{[ $fs->format->name ]}, expected @{[ $format->name ]}"
    unless $fs->format->name eq $format->name;
  push @problems, $fs->check;
  push @problems, "backend created @{[ $fs->long_name_entries ]} long file name entries"
    if $fs->long_name_entries;

  my $got_label = $fs->label;
  push @problems, "volume label is '@{[ $got_label // '' ]}', expected '@{[ $label // '' ]}'"
    unless ($got_label // '') eq ($label // '');

  if(!@problems) {
    my %actual = map { $_->path => $_ } $fs->walk;
    if($manifest) {
      for my $node ($manifest->nodes) {
        my $entry = delete $actual{ $node->{dos_path} };
        unless($entry) {
          push @problems, "$node->{dos_path} is missing from the image";
          next;
        }
        if($entry->type ne $node->{type}) {
          push @problems, "$node->{dos_path} is a @{[ $entry->type ]} in the image, expected a $node->{type}";
          next;
        }
        next unless $node->{type} eq 'file';
        my @st = stat $node->{source};
        if(!@st || $st[7] != $node->{size} || $st[9] != $node->{mtime}) {
          push @problems, "source file changed while the image was being built: $node->{source}";
          next;
        }
        if($entry->size != $node->{size}) {
          push @problems, "$node->{dos_path} has size @{[ $entry->size ]} in the image, expected $node->{size}";
          next;
        }
        my $want = eval { Path::Tiny::path($node->{source})->slurp_raw };
        if(!defined $want) {
          push @problems, "unable to re-read source file: $node->{source}";
        } elsif($want ne $fs->read_file($entry)) {
          push @problems, "$node->{dos_path} contents differ from $node->{source}";
        }
      }
    }
    push @problems, "unexpected entry in image: $_" for sort keys %actual;
  }

  Disk::Diskette::Error->throw('image verification failed', @problems) if @problems;
  return;
}

sub _publish ($class, $tmp, $dest, $force) {
  if($force) {
    if(my @st = lstat $dest) {
      Disk::Diskette::Error->throw("destination is a symbolic link: $dest") if -l _;
      Disk::Diskette::Error->throw("destination exists and is not a regular file: $dest") unless S_ISREG($st[2]);
    }
    rename "$tmp", "$dest" or Disk::Diskette::Error->throw("unable to replace $dest", "$!");
    return;
  }

  # link() fails if the destination exists, closing the race between the
  # earlier check and publication.
  return if link "$tmp", "$dest";
  my $error = $!;
  Disk::Diskette::Error->throw("destination already exists: $dest", 'use --force (API: force => 1) to replace it')
    if $!{EEXIST};

  # filesystems without hard links: reserve the name exclusively, then
  # rename over the reservation.
  sysopen my $fh, "$dest", O_WRONLY|O_CREAT|O_EXCL, 0666
    or Disk::Diskette::Error->throw(
      $!{EEXIST} ? ("destination already exists: $dest", 'use --force (API: force => 1) to replace it')
                 : ("unable to create $dest", "$error", "$!"),
    );
  close $fh;
  unless(rename "$tmp", "$dest") {
    my $rename_error = "$!";
    unlink "$dest";
    Disk::Diskette::Error->throw("unable to create $dest", $rename_error);
  }
  return;
}

=head2 open

 my $image = Disk::Diskette->open($path);

Opens an existing image without modifying it, validating that it has a
supported geometry and FAT12 boot sector.  Returns a
L<Disk::Diskette::Image>.

=cut

sub open ($class, $path) {
  Disk::Diskette::Image->open($path);
}

=head2 formats

 my @formats = Disk::Diskette->formats;

The supported fixed formats as L<Disk::Diskette::Format> objects,
smallest first.  The registry itself, including automatic selectors and
their candidates, is L<Disk::Diskette::Format>.

=cut

sub formats ($class) { Disk::Diskette::Format->all }

=head1 SEE ALSO

=over 4

=item L<fdimg>

Command line interface.

=item L<Disk::Diskette::Image>

=item L<Disk::Diskette::Format>

=item L<Disk::Diskette::Config>

=item L<Disk::Diskette::Manifest>

=back

=cut
