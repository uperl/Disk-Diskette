package Disk::Diskette::Manifest;

use v5.42;
use warnings;
use Moo 2;
use Path::Tiny ();
use Fcntl qw( S_ISREG S_ISDIR );
use List::Util qw( any );
use Disk::Diskette::Error;
use Disk::Diskette::Name qw( short_name );

# ABSTRACT: Source tree traversal, normalization, exclusions and capacity planning
# VERSION

=head1 SYNOPSIS

 use Disk::Diskette::Manifest;
 use Disk::Diskette::Format;

 my $manifest = Disk::Diskette::Manifest->build(
   source          => 'utilities',
   exclude         => ['*.bak'],
   follow_symlinks => 1,
 );

 for my $file ($manifest->files) {
   say "$file->{dos_path} <- $file->{source}";
 }

 my @problems = $manifest->fits(Disk::Diskette::Format->get('360k'), label => 1);

=head1 DESCRIPTION

A manifest is the normalized, validated plan for the contents of an image
built from a host directory.  It is built in deterministic order (host
names sorted bytewise within each directory) and records, for each entry,
the DOS short name, the image path, the host path to read and, for files,
the size and modification time.

Building a manifest applies these rules:

=over 4

=item *

Entries whose names start with C<.> are ignored at every level, including
hidden directories and their descendants.

=item *

Explicit exclusion patterns are applied next.  Excluded directories are
not traversed.  See L</EXCLUSION PATTERNS>.

=item *

Each remaining name must already be a legal DOS 8.3 name, ignoring case
(see L<Disk::Diskette::Name>).  Names are uppercased; nothing is
truncated or replaced.

=item *

Names that collide after normalization within one destination directory
are errors.

=item *

Regular files are copied and regular directories traversed.  Symbolic
links resolving to regular files are followed by default (the link name
is used, not the target's).  Directory symlinks, dangling or circular
links, special files and links to special files are errors.  With
C<follow_symlinks> disabled every symlink is an error.

=back

All problems found are reported together in a single
L<Disk::Diskette::Error>.

=head1 EXCLUSION PATTERNS

Patterns are shell-style globs matched against source-relative host
paths using C</> separators, before name validation.

=over 4

=item *

A pattern without a C</> matches an entry's basename at any depth.

=item *

A pattern containing a C</> matches the whole source-relative path.  A
leading C</> is permitted and anchors a pattern to the source root (so
C</README.md> excludes only the top level file).

=item *

C<*> matches any run of characters and C<?> one character, neither
crossing C</>.  Character classes such as C<[abc]>, C<[a-z]> and C<[!0-9]>
(or C<[^0-9]>) are supported.  A backslash makes the next character
literal.

=item *

Matching is case-sensitive on the host name.

=item *

C<**>, a trailing C</>, empty patterns and unterminated character
classes are rejected.

=back

=head1 CLASS METHODS

=head2 check_pattern

 my $error = Disk::Diskette::Manifest->check_pattern($pattern);

Returns C<undef> for a valid exclusion pattern, otherwise a reason.

=cut

sub check_pattern ($class, $pattern) {
  my(undef, $error) = _compile_pattern($pattern);
  return $error;
}

sub _compile_pattern ($pattern) {
  return (undef, 'pattern is not a string') if !defined $pattern || ref $pattern;
  return (undef, 'pattern is empty') if $pattern eq '';
  return (undef, 'recursive ** patterns are not supported') if $pattern =~ /\*\*/;
  return (undef, 'a trailing / is not supported') if $pattern =~ m{/\z};

  my $anchored = $pattern =~ m{/};
  my $glob = $pattern =~ s{\A/+}{}r;
  return (undef, 'pattern is empty') if $glob eq '';

  my $regex = '';
  my @chars = split //, $glob;
  while(@chars) {
    my $c = shift @chars;
    if($c eq '\\') {
      return (undef, 'pattern ends with a backslash') unless @chars;
      $regex .= quotemeta shift @chars;
    } elsif($c eq '*') {
      $regex .= '[^/]*';
    } elsif($c eq '?') {
      $regex .= '[^/]';
    } elsif($c eq '[') {
      my $class = '';
      my $negate = 0;
      if(@chars && ($chars[0] eq '!' || $chars[0] eq '^')) {
        shift @chars;
        $negate = 1;
      }
      my $first = 1;
      my $closed = 0;
      while(@chars) {
        my $d = shift @chars;
        if($d eq ']' && !$first) {
          $closed = 1;
          last;
        }
        $first = 0;
        if($d eq '\\' && @chars) {
          $class .= quotemeta shift @chars;
        } elsif($d eq '-' && length $class && @chars && $chars[0] ne ']') {
          $class .= '-';
        } elsif($d eq '/') {
          return (undef, 'a character class cannot match /');
        } else {
          $class .= quotemeta $d;
        }
      }
      return (undef, 'unterminated character class') unless $closed;
      $regex .= $negate ? "[^/$class]" : "[$class]";
    } else {
      $regex .= quotemeta $c;
    }
  }

  my $compiled = eval { qr/\A$regex\z/s };
  return (undef, 'invalid character class') unless $compiled;
  return ({ pattern => $pattern, anchored => $anchored, regex => $compiled }, undef);
}

=head2 build

 my $manifest = Disk::Diskette::Manifest->build(
   source          => $directory,
   exclude         => \@patterns,
   follow_symlinks => $bool,
   skip            => \@host_paths,
 );

Traverses and validates the source tree.  C<skip> lists host paths
(typically an explicit configuration file inside the source tree) that
are silently left out.

=cut

has source          => ( is => 'ro', required => 1 );
has exclude         => ( is => 'ro', default => sub { [] } );
has follow_symlinks => ( is => 'ro', default => 1 );

=head1 ATTRIBUTES

=head2 source

The source directory as given.

=head2 exclude

Exclusion patterns.

=head2 follow_symlinks

=head2 root

The root node.  Nodes are hash references with C<type> (C<file> or
C<directory>), C<name> (DOS name, empty for the root), C<dos_path>,
C<rel> (source-relative host path), C<source> (host path) and, for
directories, C<children>; files also have C<size> and C<mtime>.

=cut

has root => ( is => 'rwp' );

sub build ($class, %args) {
  my $skip = delete $args{skip} // [];
  my $self = $class->new(%args);
  $self->_traverse($skip);
  return $self;
}

sub _display ($self, $rel) {
  Path::Tiny::path($self->source)->child($rel)->stringify;
}

sub _traverse ($self, $skip) {
  my $source = Path::Tiny::path($self->source);

  Disk::Diskette::Error->throw("source does not exist: $source") unless -e $source || -l $source;
  Disk::Diskette::Error->throw("source is not a directory: $source") unless -d $source;

  my @patterns;
  for my $pattern ($self->exclude->@*) {
    my($compiled, $error) = _compile_pattern($pattern);
    Disk::Diskette::Error->throw("invalid exclude pattern '@{[ $pattern // 'undef' ]}': $error") unless $compiled;
    push @patterns, $compiled;
  }

  my %skip;
  for my $path (@$skip) {
    my $real = eval { Path::Tiny::path($path)->realpath };
    $skip{"$real"} = 1 if defined $real;
  }
  my $source_real = $source->realpath;

  my @problems;

  my $root = {
    type     => 'directory',
    name     => '',
    dos_path => '/',
    rel      => '',
    source   => $source,
    children => [],
  };

  my $walk = sub ($dir) {
    my $host = $dir->{source};
    my $dh;
    unless(opendir $dh, $host) {
      push @problems, [ "unable to read directory: " . $self->_display($dir->{rel}), "$!" ];
      return;
    }
    my @names = sort grep { !/\A\./ } readdir $dh;
    closedir $dh;

    my %seen;
    for my $host_name (@names) {
      my $rel = length $dir->{rel} ? "$dir->{rel}/$host_name" : $host_name;
      next if any { ($_->{anchored} ? $rel : $host_name) =~ $_->{regex} } @patterns;

      my $path = $host->child($host_name);
      next if %skip && $skip{ $source_real->child($rel) };

      my $display = $self->_display($rel);

      my @lstat = lstat $path;
      unless(@lstat) {
        push @problems, [ "unable to stat: $display", "$!" ];
        next;
      }

      my($type, @stat);
      if(-l _) {
        unless($self->follow_symlinks) {
          push @problems, [ "symbolic link not permitted: $display", 'symlinks are rejected because follow_symlinks is disabled' ];
          next;
        }
        @stat = stat $path;
        unless(@stat) {
          if($!{ELOOP}) {
            push @problems, [ "circular symbolic link: $display" ];
          } elsif($!{ENOENT} || $!{ENOTDIR}) {
            push @problems, [ "dangling symbolic link: $display", "target @{[ readlink($path) // '?' ]} does not exist" ];
          } else {
            push @problems, [ "unable to resolve symbolic link: $display", "$!" ];
          }
          next;
        }
        if(S_ISDIR($stat[2])) {
          push @problems, [ "directory symbolic links are not supported: $display" ];
          next;
        } elsif(!S_ISREG($stat[2])) {
          push @problems, [ "symbolic link to a special file: $display" ];
          next;
        }
        $type = 'file';
      } else {
        @stat = @lstat;
        if(S_ISDIR($stat[2])) {
          $type = 'directory';
        } elsif(S_ISREG($stat[2])) {
          $type = 'file';
        } else {
          push @problems, [ "special file not supported: $display" ];
          next;
        }
      }

      my($dos_name, $why) = short_name($host_name);
      unless(defined $dos_name) {
        push @problems, [
          "invalid DOS filename: $display",
          "$why; rename it or exclude it",
        ];
        next;
      }

      my $dos_path = $dir->{dos_path} eq '/' ? "/$dos_name" : "$dir->{dos_path}/$dos_name";

      if(my $other = $seen{$dos_name}) {
        push @problems, [
          "DOS filename collision: $dos_path",
          "@{[ $self->_display($other->{rel}) ]} and $display map to the same name",
        ];
        next;
      }

      my $node = {
        type     => $type,
        name     => $dos_name,
        dos_path => $dos_path,
        rel      => $rel,
        source   => $path,
      };

      if($type eq 'file') {
        if(open my $fh, '<', $path) {
          close $fh;
        } else {
          push @problems, [ "unable to read file: $display", "$!" ];
          next;
        }
        $node->{size}  = $stat[7];
        $node->{mtime} = $stat[9];
      } else {
        $node->{children} = [];
      }

      $seen{$dos_name} = $node;
      push $dir->{children}->@*, $node;
      __SUB__->($node) if $type eq 'directory';
    }
  };

  $walk->($root);

  if(@problems == 1) {
    Disk::Diskette::Error->throw($problems[0]->@*);
  } elsif(@problems) {
    Disk::Diskette::Error->throw(
      "@{[ scalar @problems ]} problems found in source tree $source",
      map { my($m, @d) = @$_; ($m, map { "  $_" } @d) } @problems,
    );
  }

  $self->_set_root($root);
}

=head1 METHODS

=head2 nodes

 my @nodes = $manifest->nodes;

All non-root nodes, depth first, parents before children.

=cut

sub nodes ($self) {
  my @nodes;
  my $walk = sub ($dir) {
    for my $child ($dir->{children}->@*) {
      push @nodes, $child;
      __SUB__->($child) if $child->{type} eq 'directory';
    }
  };
  $walk->($self->root);
  return @nodes;
}

=head2 files

=head2 directories

Files, or non-root directories, in L</nodes> order.

=cut

sub files       ($self) { grep { $_->{type} eq 'file' } $self->nodes }
sub directories ($self) { grep { $_->{type} eq 'directory' } $self->nodes }

=head2 total_file_bytes

Sum of file sizes.

=cut

sub total_file_bytes ($self) {
  my $total = 0;
  $total += $_->{size} for $self->files;
  return $total;
}

=head2 requirements

 my $req = $manifest->requirements($format, label => $bool);

Returns a hash reference with C<root_entries> (including any volume label
entry) and C<clusters> (file data rounded up to whole clusters, plus each
subdirectory including its C<.> and C<..> entries).

=cut

sub requirements ($self, $format, %opts) {
  my $cb = $format->cluster_bytes;
  my $clusters = 0;
  for my $node ($self->nodes) {
    if($node->{type} eq 'file') {
      $clusters += int(($node->{size} + $cb - 1) / $cb);
    } else {
      my $bytes = (2 + scalar $node->{children}->@*) * 32;
      $clusters += int(($bytes + $cb - 1) / $cb);
    }
  }
  return {
    root_entries => scalar($self->root->{children}->@*) + ($opts{label} ? 1 : 0),
    clusters     => $clusters,
  };
}

=head2 fits

 my @problems = $manifest->fits($format, label => $bool);

Returns an empty list if the content fits the format, otherwise one
message per failed constraint.

=cut

sub fits ($self, $format, %opts) {
  my $req = $self->requirements($format, %opts);
  my @problems;
  if($req->{root_entries} > $format->root_entries) {
    push @problems, sprintf "root directory needs %d entries%s but %s allows %d",
      $req->{root_entries}, ($opts{label} ? ' (including the volume label)' : ''),
      $format->name, $format->root_entries;
  }
  if($req->{clusters} > $format->cluster_count) {
    push @problems, sprintf "data needs %d clusters (%d bytes) but %s has %d (%d bytes)",
      $req->{clusters}, $req->{clusters} * $format->cluster_bytes,
      $format->name, $format->cluster_count, $format->data_bytes;
  }
  return @problems;
}
