package Disk::Diskette::Error;

use v5.42;
use warnings;
use Moo 2;
use overload
  '""'     => sub ($self, @) { $self->as_string },
  bool     => sub { 1 },
  fallback => 1;

# ABSTRACT: Exception class for Disk::Diskette
# VERSION

=head1 SYNOPSIS

 use v5.42;
 use warnings;
 use Disk::Diskette;

 try {
   Disk::Diskette->create(source => 'utilities');
 }
 catch ($e) {
   die $e unless $e isa Disk::Diskette::Error;
   say STDERR "failed: ", $e->message;
   say STDERR "  $_" for $e->details->@*;
 }

=head1 DESCRIPTION

Expected failures (invalid input, capacity problems, backend failures and
so on) are thrown as instances of this class.  The library never prints
diagnostics itself; callers decide how to present them.  Stringification
gives the message followed by any indented detail lines, terminated by a
newline, so an uncaught error is still readable.

=head1 ATTRIBUTES

=head2 message

A one line summary of the problem.

=head2 details

Array reference of additional lines (offending paths, constraints,
suggested resolutions).  May be empty.

=cut

has message => ( is => 'ro', required => 1 );
has details => ( is => 'ro', default => sub { [] } );

=head1 METHODS

=head2 throw

 Disk::Diskette::Error->throw($message, @details);

Construct and throw an exception.

=cut

sub throw ($class, $message, @details) {
  die $class->new( message => $message, details => \@details );
}

=head2 as_string

 my $string = $e->as_string;

The message and indented details, newline terminated.

=cut

sub as_string ($self) {
  join '', map { "$_\n" } $self->message, map { "  $_" } $self->details->@*;
}
