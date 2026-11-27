# Disk::Diskette ![static](https://github.com/uperl/Disk-Diskette/workflows/static/badge.svg) ![linux](https://github.com/uperl/Disk-Diskette/workflows/linux/badge.svg) ![macos](https://github.com/uperl/Disk-Diskette/workflows/macos/badge.svg)

Perl library for creating and manipulating raw DOS FAT12 floppy images

# SYNOPSIS

```perl
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
```

# DESCRIPTION

`Disk::Diskette` creates and inspects raw (uncompressed sector dump)
DOS FAT12 floppy images, suitable for Gotek/FlashFloppy USB sticks,
emulators and release pipelines.  No root privileges, mounting or loop
devices are needed.  The [fdimg](https://metacpan.org/pod/fdimg) command is a thin interface to this
library.

Images are populated with strict DOS 8.3 names: host names must already
be legal short names (case is ignored and normalized to uppercase); no
long file names, aliases, truncation or sanitization are ever produced.
See [Disk::Diskette::Manifest](https://metacpan.org/pod/Disk::Diskette::Manifest) for the source tree rules and
[Disk::Diskette::Format](https://metacpan.org/pod/Disk::Diskette::Format) for the supported geometries.

The library is silent: it returns objects and throws
[Disk::Diskette::Error](https://metacpan.org/pod/Disk::Diskette::Error) exceptions with descriptive messages.

# REQUIREMENTS

The mtools programs (`mformat`, `mcopy`, `mmd`) must be installed and
in `PATH`.  They are available from most package managers, for example
`apt install mtools`, `dnf install mtools` or `brew install mtools`.
Your own mtools configuration is not used; see
[Disk::Diskette::Backend::Mtools](https://metacpan.org/pod/Disk::Diskette::Backend::Mtools).

# CLASS METHODS

## create

```perl
my $image = Disk::Diskette->create(%options);
```

Creates an image and returns a [Disk::Diskette::Image](https://metacpan.org/pod/Disk::Diskette::Image) once it has been
verified and published.  Options:

- source

    Host directory to copy.  Omit for an empty image (then `path` is
    required and the source-only options `follow_symlinks`, `exclude` and
    `config` are rejected).

- path

    Output image path.  Defaults to the source directory path with `.img`
    appended (for example `utilities/` becomes `utilities.img`).

- format

    A fixed format (`360k`, ...) or automatic selector (`auto-1440k`, ...);
    defaults to `auto-1440k`.  Automatic selectors choose the smallest
    candidate that fits the content; see [Disk::Diskette::Format](https://metacpan.org/pod/Disk::Diskette::Format).

- label

    Volume label.  Omit to use the configuration or derive it from the
    uppercase source directory name; `undef` (or the empty string) means
    unlabeled.  Empty images are unlabeled by default.

- follow\_symlinks

    Follow symlinks to regular files (default true).  When false every
    symlink in the source is an error.

- exclude

    Array reference of exclusion patterns, replacing any configured list
    (an empty list clears it).  See ["EXCLUSION PATTERNS" in Disk::Diskette::Manifest](https://metacpan.org/pod/Disk::Diskette::Manifest#EXCLUSION-PATTERNS).

- config

    Path of an explicit configuration file, or `undef` to disable
    discovery of `.fdimg.toml`.  See [Disk::Diskette::Config](https://metacpan.org/pod/Disk::Diskette::Config).

- force

    Replace an existing image (atomically).  Without it an existing
    destination is an error.

- source\_date\_epoch

    Reproducible mode timestamp (integer seconds since the Unix epoch, UTC).
    Defaults to the `SOURCE_DATE_EPOCH` environment variable when set;
    `undef` disables reproducible mode.  In reproducible mode file
    timestamps are clamped to this time, directories and the volume label
    use it, and the volume serial number is the low 32 bits of the epoch.

Creation never modifies an existing image until the new one has been
fully built and verified in a temporary file beside the destination.
The destination must not be a symlink or non-regular file, and must not
be inside the source tree.

Concurrent writers to the same destination are not supported (there is
no locking).  Without `force`, publication cannot overwrite an image
that appeared after the initial check; with `force`, the last writer
wins.

## open

```perl
my $image = Disk::Diskette->open($path);
```

Opens an existing image without modifying it, validating that it has a
supported geometry and FAT12 boot sector.  Returns a
[Disk::Diskette::Image](https://metacpan.org/pod/Disk::Diskette::Image).

## formats

```perl
my @formats = Disk::Diskette->formats;
```

The supported fixed formats as [Disk::Diskette::Format](https://metacpan.org/pod/Disk::Diskette::Format) objects,
smallest first.  The registry itself, including automatic selectors and
their candidates, is [Disk::Diskette::Format](https://metacpan.org/pod/Disk::Diskette::Format).

# SEE ALSO

- [fdimg](https://metacpan.org/pod/fdimg)

    Command line interface.

- [Disk::Diskette::Image](https://metacpan.org/pod/Disk::Diskette::Image)
- [Disk::Diskette::Format](https://metacpan.org/pod/Disk::Diskette::Format)
- [Disk::Diskette::Config](https://metacpan.org/pod/Disk::Diskette::Config)
- [Disk::Diskette::Manifest](https://metacpan.org/pod/Disk::Diskette::Manifest)

# AUTHOR

Graham Ollis <plicease@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2026 by Graham Ollis.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
