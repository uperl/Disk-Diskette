package Disk::Diskette::Config;

use v5.42;
use warnings;
use Path::Tiny ();
use Scalar::Util qw( blessed );
use Encode ();
use TOML::Tiny 0.16 ();
use Disk::Diskette::Error;
use Disk::Diskette::Format;
use Disk::Diskette::Name qw( volume_label );
use Disk::Diskette::Manifest;

# ABSTRACT: Configuration loading, validation and precedence
# VERSION

=head1 SYNOPSIS

 use Disk::Diskette::Config;

 # load and validate a single file
 my $settings = Disk::Diskette::Config->load('utilities/.fdimg.toml');

 # effective settings for a source directory
 my $effective = Disk::Diskette::Config->resolve(
   source => 'utilities',
   args   => { label => 'TOOLS' },   # explicit arguments
 );

=head1 DESCRIPTION

Source directories may contain a C<.fdimg.toml> file at their root:

 format = "auto-1440k"
 label = "UTILITIES"
 follow_symlinks = true
 exclude = ["README.md", "*.bak"]

Only the source root is consulted; parent and nested directories are not
searched.  The file is host-side metadata and is never copied to an image.

Precedence is per key: explicit arguments, then configuration, then
built-in or derived defaults.  An explicit exclusion list replaces (does
not extend) the configured list.  C<label = ""> requests an unlabeled
image.  Unknown keys, wrong types, invalid values and malformed TOML are
errors that name the file, even when an explicit argument would have
overridden the value.

=head1 CLASS METHODS

=head2 filename

The discovered configuration filename, C<.fdimg.toml>.

=cut

sub filename ($class) { '.fdimg.toml' }

=head2 supported_keys

Supported configuration keys.

=cut

my @KEYS = qw( format label follow_symlinks exclude );
my %KEYS = map { $_ => 1 } @KEYS;

sub supported_keys ($class) { @KEYS }

=head2 discover

 my $path = Disk::Diskette::Config->discover($source_directory);

Returns the configuration path in the source root as a L<Path::Tiny>, or
C<undef> if there is none.

=cut

sub discover ($class, $source) {
  my $path = Path::Tiny::path($source)->child($class->filename);
  return -e $path || -l $path ? $path : undef;
}

my $TYPED = 'Disk::Diskette::Config::TypedValue';

sub _typed ($type) {
  sub ($value) { bless { type => $type, value => $value }, $TYPED };
}

sub _type_of ($value) {
  return $value->{type} if blessed $value && $value isa $TYPED;
  return 'array' if ref $value eq 'ARRAY';
  return 'table' if ref $value eq 'HASH';
  return 'string';
}

=head2 load

 my $settings = Disk::Diskette::Config->load($path);

Parses and validates the given file, returning a hash reference with only
the keys present in the file.  C<label> is normalized to uppercase, or
C<undef> for C<label = "">; C<follow_symlinks> is C<1> or C<0>.

=cut

sub load ($class, $path) {
  $path = Path::Tiny::path($path);
  Disk::Diskette::Error->throw("config file does not exist: $path") unless -e $path;
  Disk::Diskette::Error->throw("config file is not a regular file: $path") unless -f $path;
  Disk::Diskette::Error->throw("config file is not readable: $path") unless -r $path;

  my $bytes = eval { $path->slurp_raw };
  Disk::Diskette::Error->throw("unable to read config file: $path", "$@" =~ s/\s+\z//r) unless defined $bytes;

  my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
  Disk::Diskette::Error->throw("$path: config file is not valid UTF-8") unless defined $text;

  my $parser = TOML::Tiny->new(
    strict           => 1,
    inflate_boolean  => _typed('boolean'),
    inflate_integer  => _typed('integer'),
    inflate_float    => _typed('float'),
    inflate_datetime => _typed('datetime'),
  );

  my($data, $error);
  try {
    ($data, $error) = $parser->decode($text);
  }
  catch ($e) {
    $error = $e;
  }
  if(defined $error) {
    $error = "$error" =~ s/\s+\z//r;
    $error =~ s/ at \S+ line \d+\.\z//;
    Disk::Diskette::Error->throw("$path: malformed TOML", $error);
  }

  my @errors;
  my %settings;

  for my $key (sort keys %$data) {
    my $value = $data->{$key};
    my $type  = _type_of($value);
    unless($KEYS{$key}) {
      push @errors, "unknown key '$key' (supported keys: @KEYS)";
      next;
    }
    if($key eq 'format') {
      if($type ne 'string') {
        push @errors, "'format' must be a string, not $type";
      } elsif(!Disk::Diskette::Format->is_selector($value)) {
        push @errors, "'format' has an unknown value '$value' (valid formats: @{[ Disk::Diskette::Format->selectors ]})";
      } else {
        $settings{format} = lc $value;
      }
    } elsif($key eq 'label') {
      if($type ne 'string') {
        push @errors, "'label' must be a string, not $type";
      } elsif($value eq '') {
        $settings{label} = undef;
      } else {
        my($label, $why) = volume_label($value);
        if(defined $label) {
          $settings{label} = $label;
        } else {
          push @errors, "'label' is invalid: $why";
        }
      }
    } elsif($key eq 'follow_symlinks') {
      if($type ne 'boolean') {
        push @errors, "'follow_symlinks' must be a boolean, not $type";
      } else {
        $settings{follow_symlinks} = $value->{value} eq 'true' ? 1 : 0;
      }
    } elsif($key eq 'exclude') {
      if($type ne 'array') {
        push @errors, "'exclude' must be an array of strings, not $type";
        next;
      }
      my @patterns;
      for my $i (0..$#$value) {
        my $item = $value->[$i];
        my $item_type = _type_of($item);
        if($item_type ne 'string') {
          push @errors, "'exclude' item $i must be a string, not $item_type";
          next;
        }
        my $why = Disk::Diskette::Manifest->check_pattern($item);
        if(defined $why) {
          push @errors, "'exclude' item $i ('$item') is invalid: $why";
          next;
        }
        push @patterns, $item;
      }
      $settings{exclude} = \@patterns;
    }
  }

  Disk::Diskette::Error->throw("$path: invalid configuration", @errors) if @errors;

  return \%settings;
}

=head2 resolve

 my $effective = Disk::Diskette::Config->resolve(
   source => $source_directory,   # optional
   args   => \%explicit,          # optional
 );

Combines explicit arguments, configuration and defaults.  Recognized
explicit arguments are C<format>, C<label>, C<follow_symlinks>,
C<exclude> and C<config>.  Presence matters: an C<exists> key with an
C<undef> C<label> is an explicit request for no label, and C<config>
set to C<undef> disables discovery.  C<config> set to a path selects an
explicit configuration file, which must exist.

Returns a hash reference with C<format>, C<label> (C<undef> for
unlabeled), C<follow_symlinks>, C<exclude> (array reference) and
C<config> (the L<Path::Tiny> used, or C<undef>).

Without a source (empty image creation) no configuration is discovered
and the label defaults to none.  With a source and no label setting,
the label is derived from the uppercase source directory basename; a
derived label that is not a legal volume label is an error suggesting an
explicit label.

=cut

sub resolve ($class, %opts) {
  my $args   = $opts{args} // {};
  my $source = defined $opts{source} ? Path::Tiny::path($opts{source}) : undef;

  for my $key (sort keys %$args) {
    next if $KEYS{$key} || $key eq 'config';
    Disk::Diskette::Error->throw("unknown option: $key");
  }

  my $config_path;
  if(exists $args->{config}) {
    $config_path = defined $args->{config} ? Path::Tiny::path($args->{config}) : undef;
    Disk::Diskette::Error->throw("config file does not exist: $config_path")
      if defined $config_path && !-e $config_path;
  } elsif(defined $source) {
    $config_path = $class->discover($source);
  }

  my $config = defined $config_path ? $class->load($config_path) : {};

  my %effective = ( config => $config_path );

  # format
  if(exists $args->{format}) {
    $effective{format} = Disk::Diskette::Format->check_selector($args->{format});
  } else {
    $effective{format} = $config->{format} // Disk::Diskette::Format->default_selector;
  }

  # follow_symlinks
  if(exists $args->{follow_symlinks}) {
    $effective{follow_symlinks} = $args->{follow_symlinks} ? 1 : 0;
  } else {
    $effective{follow_symlinks} = $config->{follow_symlinks} // 1;
  }

  # exclude
  my $exclude = exists $args->{exclude} ? $args->{exclude} : $config->{exclude} // [];
  $exclude = [$exclude] unless ref $exclude eq 'ARRAY';
  for my $pattern (@$exclude) {
    my $why = Disk::Diskette::Manifest->check_pattern($pattern);
    Disk::Diskette::Error->throw("invalid exclude pattern '@{[ $pattern // 'undef' ]}': $why") if defined $why;
  }
  $effective{exclude} = [@$exclude];

  # label
  if(exists $args->{label}) {
    $effective{label} = $class->_explicit_label($args->{label});
  } elsif(exists $config->{label}) {
    $effective{label} = $config->{label};
  } elsif(defined $source) {
    $effective{label} = $class->_derived_label($source);
  } else {
    $effective{label} = undef;
  }

  return \%effective;
}

sub _explicit_label ($class, $label) {
  return undef if !defined $label || $label eq '';
  my($normalized, $why) = volume_label($label);
  Disk::Diskette::Error->throw("invalid volume label '$label': $why") unless defined $normalized;
  return $normalized;
}

=head2 source_basename

 my $name = Disk::Diskette::Config->source_basename($source);

The basename used for label and output derivation.  Trailing separators
are ignored and C<.> or C<..> are resolved against the filesystem.
Returns C<undef> when there is no usable basename (the filesystem root).

=cut

sub source_basename ($class, $source) {
  my $path = Path::Tiny::path($source);
  my $base = $path->basename;
  if($base eq '' || $base eq '.' || $base eq '..' || $path->is_rootdir) {
    my $real = eval { $path->realpath };
    return undef unless defined $real;
    return undef if $real->is_rootdir;
    $base = $real->basename;
  }
  return length $base ? $base : undef;
}

sub _derived_label ($class, $source) {
  my $base = $class->source_basename($source);
  Disk::Diskette::Error->throw(
    "unable to derive a volume label: source directory has no usable name",
    "use --label LABEL (API: label => ...) or --no-label (API: label => undef)",
  ) unless defined $base;
  my($label, $why) = volume_label($base);
  return $label if defined $label;
  Disk::Diskette::Error->throw(
    "unable to derive a volume label from source directory name '$base': $why",
    "set a label with --label LABEL (API: label => ...)",
    "or set label in @{[ $class->filename ]}",
    "or request an unlabeled image with --no-label (API: label => undef)",
  );
}
