package Disk::Diskette::Name;

use v5.42;
use warnings;
use Exporter 'import';

# ABSTRACT: DOS 8.3 short name and volume label rules (internal)
# VERSION

our @EXPORT_OK = qw( short_name volume_label );

=head1 SYNOPSIS

 use Disk::Diskette::Name qw( short_name volume_label );

 my($name, $error) = short_name('readme.txt');   # ('README.TXT', undef)
 my($label, $error) = volume_label('my disk');    # ('MY DISK', undef)

=head1 DESCRIPTION

This module is internal to L<Disk::Diskette>; its interface may change.

Names are restricted to the DOS-compatible ASCII subset.  Letters are
uppercased with ASCII-only rules (no locale or Unicode case folding).
There is no truncation, alias generation or replacement: a name that is
not already a legal 8.3 name (ignoring case) is rejected with a reason.

Permitted characters in short names are C<A>-C<Z>, C<0>-C<9> and
C<! # $ % & ( ) - @ ^ _ ` { } ~>.  The apostrophe is legal in DOS but is
rejected because mtools turns it into a long file name entry.

Volume labels allow the same characters plus embedded (not leading or
trailing) spaces, up to 11 characters, with no extension dot.

=cut

my $CHARS = q{A-Z0-9!#$%&()\-@^_`\{\}~};

my %RESERVED = map { $_ => 1 } qw( CON PRN AUX NUL CLOCK$ ), map { ("COM$_", "LPT$_") } 1..9;

=head1 FUNCTIONS

=head2 short_name

 my($normalized, $error) = short_name($name);

Returns the uppercase 8.3 name, or C<undef> and a human readable reason.

=cut

sub short_name ($name) {
  return (undef, 'name is empty') unless defined $name && length $name;
  return (undef, 'name contains non-ASCII characters') if $name =~ /[^\x00-\x7f]/;
  return (undef, 'name contains control characters') if $name =~ /[\x00-\x1f\x7f]/;
  return (undef, 'name contains a path separator') if $name =~ m{[/\\]};
  return (undef, 'name contains a space') if $name =~ / /;
  return (undef, 'name has a trailing dot') if $name =~ /\.\z/;

  my $upper = $name =~ tr/a-z/A-Z/r;
  my @parts = split /\./, $upper, -1;
  return (undef, 'name has more than one dot') if @parts > 2;
  my($base, $ext) = @parts;
  return (undef, 'name has an empty base name') unless length $base;
  return (undef, 'base name is longer than 8 characters') if length $base > 8;
  return (undef, 'extension is longer than 3 characters') if defined $ext && length $ext > 3;
  for my $part (grep { defined } $base, $ext) {
    if($part =~ /([^$CHARS])/) {
      return (undef, "name contains the character '$1', which is not permitted in DOS short names");
    }
  }
  return (undef, "'$base' is a reserved DOS device name") if $RESERVED{$base};
  return ($upper, undef);
}

=head2 volume_label

 my($normalized, $error) = volume_label($label);

Returns the uppercase label, or C<undef> and a human readable reason.

=cut

sub volume_label ($label) {
  return (undef, 'label is empty') unless defined $label && length $label;
  return (undef, 'label contains non-ASCII characters') if $label =~ /[^\x00-\x7f]/;
  return (undef, 'label contains control characters') if $label =~ /[\x00-\x1f\x7f]/;
  return (undef, 'label is longer than 11 characters') if length $label > 11;
  return (undef, 'label has leading or trailing spaces') if $label =~ /\A | \z/;
  my $upper = $label =~ tr/a-z/A-Z/r;
  if($upper =~ /([^$CHARS ])/) {
    return (undef, "label contains the character '$1', which is not permitted in volume labels");
  }
  return ($upper, undef);
}
