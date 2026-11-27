package Disk::Diskette::Backend::Mtools;

use v5.42;
use warnings;
use Moo 2;
use Path::Tiny ();
use File::Spec ();
use Capture::Tiny ();
use Disk::Diskette::Error;

# ABSTRACT: mtools based FAT12 backend (internal)
# VERSION

=head1 SYNOPSIS

 use Disk::Diskette::Backend::Mtools;

 my $backend = Disk::Diskette::Backend::Mtools->new;
 $backend->format_image($path, $format, label => 'UTILITIES');
 $backend->make_directories($path, ['/DOCS', '/DOCS/OLD']);
 $backend->copy_file($path, $host_file, '/DOCS/README.TXT', mtime => $epoch);

=head1 DESCRIPTION

This module is internal to L<Disk::Diskette>; its interface may change.

All external FAT operations go through this class.  Commands are run
with argument lists (never a shell), standard input from the null
device, and an isolated environment so that user mtools configuration
cannot change image semantics:

=over 4

=item *

C<HOME> points to an empty private directory and C<MTOOLSRC> to an empty
file, so C<~/.mtoolsrc> is not read.  Inherited C<MTOOLS_*> variables are
removed, and the environment equivalents of the relevant configuration
settings are set (C<MTOOLS_SKIP_CHECK=1>, C<MTOOLS_NO_VFAT=1>,
C<MTOOLS_LOWER_CASE=0>, C<MTOOLS_NAME_NUMERIC_TAIL=1>), which take
precedence over the system configuration file.

=item *

C<LC_ALL=POSIX> and C<TZ=UTC>; FAT timestamps are therefore written as UTC.
C<POSIX> rather than C<C> is deliberate: on macOS, mtools 4.0.50 with
C<LC_ALL=C> appends a stray character to names during charset conversion
(for example C<A.TXT_>) and so writes a long file name entry for every
entry.  On glibc the two locales are identical.

=item *

C<SOURCE_DATE_EPOCH> is removed unless a timestamp is requested for the
operation, in which case it is set to that value (mtools uses it for new
entries' timestamps).

=back

Spawn failure, termination by a signal and nonzero exit are reported as
distinct L<Disk::Diskette::Error>s that include the command and its
diagnostics.  Results are verified by reading the image directly, never
by parsing localized output.

=head1 ATTRIBUTES

=head2 path

Directories searched for mtools executables; defaults to C<PATH>.

=cut

has path => (
  is      => 'ro',
  default => sub { [ File::Spec->path ] },
);

has _home => (
  is      => 'lazy',
  default => sub { Path::Tiny->tempdir( TEMPLATE => 'fdimg-mtools-XXXXXX' ) },
);

has _programs => ( is => 'ro', default => sub { {} } );

=head1 METHODS

=head2 find_program

 my $exe = $backend->find_program('mformat');

Returns the full path of an mtools executable or throws an error
explaining how to install mtools.

=cut

sub find_program ($self, $name) {
  return $self->_programs->{$name} if $self->_programs->{$name};
  for my $dir ($self->path->@*) {
    next unless defined $dir && length $dir;
    my $exe = File::Spec->catfile($dir, $name);
    if(-f $exe && -x $exe) {
      return $self->_programs->{$name} = $exe;
    }
  }
  Disk::Diskette::Error->throw(
    "unable to find the mtools program '$name' in PATH",
    "mtools is required; install it with your package manager",
    "(for example: apt install mtools, dnf install mtools, or brew install mtools)",
  );
}

=head2 available

 my $bool = $backend->available;

True if all required mtools programs can be found.

=cut

sub available ($self) {
  for my $name (qw( mformat mcopy mmd )) {
    return !!0 unless eval { $self->find_program($name); 1 };
  }
  return !!1;
}

=head2 version

 my $version = $backend->version;

The mtools version reported by C<mformat --version>, for example C<4.0.49>.

=cut

sub version ($self) {
  my $result = $self->run('mformat', ['--version']);
  my($version) = "$result->{stdout}$result->{stderr}" =~ /(\d+\.\d+(?:\.\d+)*)/;
  return $version;
}

sub _environment ($self, %opts) {
  my %env = map { $_ => $ENV{$_} } grep { !/\A(MTOOLS|SOURCE_DATE_EPOCH\z|LC_|LANG)/ } keys %ENV;
  my $home = $self->_home;
  my $rc = $home->child('mtoolsrc');
  $rc->spew_raw('') unless -e $rc;
  %env = (
    %env,
    HOME                     => "$home",
    MTOOLSRC                 => "$rc",
    MTOOLS_SKIP_CHECK        => 1,
    MTOOLS_NO_VFAT           => 1,
    MTOOLS_LOWER_CASE        => 0,
    MTOOLS_NAME_NUMERIC_TAIL => 1,
    LC_ALL                   => 'POSIX',
    TZ                       => 'UTC',
  );
  $env{SOURCE_DATE_EPOCH} = $opts{epoch} if defined $opts{epoch};
  return %env;
}

=head2 run

 my $result = $backend->run($program, \@args, epoch => $epoch);

Runs an mtools program and returns a hash reference with C<stdout> and
C<stderr>.  Throws on spawn failure, signal or nonzero exit.

=cut

sub run ($self, $program, $args, %opts) {
  my $exe = $self->find_program($program);
  my %env = $self->_environment(%opts);

  my($stdout, $stderr, $status, $errno) = Capture::Tiny::capture(sub {
    local %ENV = %env;
    my $saved;
    my $have_stdin = open $saved, '<&', \*STDIN;
    open STDIN, '<', File::Spec->devnull or die "unable to open null device: $!";
    my $rv = system { $exe } $program, @$args;
    my($s, $e) = ($?, $!);
    if($have_stdin) {
      open STDIN, '<&', $saved or die "unable to restore STDIN: $!";
    } else {
      close STDIN;
    }
    return ($s, "$e");
  });

  my $command = join ' ', $program, map { /\A[\w\/\.:+=-]+\z/ ? $_ : "'$_'" } @$args;
  my @diag = map { "  $_" } grep { length } split /\n/, "$stderr$stdout";

  if($status == -1) {
    Disk::Diskette::Error->throw("unable to run $program ($exe): $errno");
  } elsif($status & 127) {
    Disk::Diskette::Error->throw("$program was terminated by signal @{[ $status & 127 ]}", "command: $command", @diag);
  } elsif($status >> 8) {
    Disk::Diskette::Error->throw("$program failed with exit status @{[ $status >> 8 ]}", "command: $command", @diag);
  }

  return { stdout => $stdout, stderr => $stderr };
}

=head2 format_image

 $backend->format_image($path, $format, label => $label, epoch => $epoch, serial => $serial);

Writes a fresh FAT12 filesystem with the exact geometry and layout of
C<$format> (a L<Disk::Diskette::Format>) into the existing file
C<$path>, which should already have the format's exact length.  C<epoch>
sets the label timestamp; C<serial> (an integer) sets the volume serial
number, which is otherwise chosen by mtools.

=cut

sub format_image ($self, $path, $format, %opts) {
  my @args = (
    '-i', "$path",
    '-t', $format->cylinders,
    '-h', $format->heads,
    '-s', $format->sectors_per_track,
    '-c', $format->sectors_per_cluster,
    '-r', $format->root_dir_sectors,
    '-m', $format->media_descriptor,
  );
  push @args, '-v', $opts{label} if defined $opts{label};
  push @args, '-N', sprintf('%08X', $opts{serial}) if defined $opts{serial};
  push @args, '::';
  $self->run('mformat', \@args, epoch => $opts{epoch});
  return;
}

=head2 make_directories

 $backend->make_directories($path, \@dos_paths, epoch => $epoch);

Creates directories in order (parents must precede children).

=cut

sub make_directories ($self, $path, $dirs, %opts) {
  return unless @$dirs;
  $self->run('mmd', [ '-i', "$path", map { "::$_" } @$dirs ], epoch => $opts{epoch});
  return;
}

=head2 copy_file

 $backend->copy_file($path, $host_file, $dos_path, mtime => $epoch);

Copies a host file to the given (already normalized, uppercase 8.3)
image path, with the given FAT modification time.

=cut

sub copy_file ($self, $path, $host, $dos_path, %opts) {
  my $source = Path::Tiny::path($host)->absolute;
  $self->run('mcopy', [ '-i', "$path", "$source", "::$dos_path" ], epoch => $opts{mtime});
  return;
}
