package App::fdimg;

use v5.42;
use warnings;
use Getopt::Long::Descriptive ();
use POSIX ();
use List::Util qw( any );
use Disk::Diskette;
use Disk::Diskette::Error;
use Disk::Diskette::Format;

# ABSTRACT: Command line interface for Disk::Diskette
# VERSION

=head1 SYNOPSIS

 use v5.42;
 use warnings;
 use App::fdimg;

 exit App::fdimg->main(@ARGV);

=head1 DESCRIPTION

This module implements the L<fdimg> command.  It owns argument parsing,
presentation and exit status mapping; every operation is performed by
L<Disk::Diskette>.  See L<fdimg> for the command reference.

=head1 METHODS

=head2 main

 my $exit = App::fdimg->main(@args);

Runs one command line.  Returns the exit status (C<0> success, help or
version; C<1> operation failure; C<2> usage error).  It never exits the
process, leaves the global C<@ARGV> untouched, and may be called
repeatedly.  Normal output goes to C<STDOUT> and diagnostics to
C<STDERR>.

=head2 commands

 my @names = App::fdimg->commands;

Command names, in help order.

=head2 command

 my $spec = App::fdimg->command($name);

The registry entry for a command, or C<undef>.

=cut

my $FORMATS = sub { Disk::Diskette::Format->selectors };

my @COMMANDS = (
  create => {
    summary  => 'Create an image from a directory, or an empty image',
    usage    => [ 'create [options] SOURCE [IMAGE]', 'create --empty [options] IMAGE' ],
    min_args => 1,
    max_args => 2,
    complete => 'file',
    description => <<~'EOF',
      Copies the SOURCE directory into a new FAT12 image.  IMAGE defaults to
      the source path with .img appended.  Host names must be legal DOS 8.3
      names (case is ignored); .fdimg.toml in the source root supplies
      defaults for format, label, follow_symlinks and exclude.
      EOF
    options  => [
      { name => 'format',          short => 'f', value => 1, complete => 'format', help => 'fixed format or automatic selector (default auto-1440k)' },
      { name => 'label',           short => 'l', value => 1, help => 'volume label' },
      { name => 'no-label',        help => 'create an unlabeled image' },
      { name => 'follow-symlinks', negatable => 1, help => 'follow (default) or reject symlinks' },
      { name => 'exclude',         value => 1, repeat => 1, help => 'exclude matching paths (repeatable; replaces configured list)' },
      { name => 'config',          value => 1, complete => 'file', help => 'use this configuration file' },
      { name => 'no-config',       help => 'do not read .fdimg.toml' },
      { name => 'force',           help => 'replace an existing image' },
      { name => 'empty',           help => 'create an empty image (no source)' },
    ],
    run => \&_cmd_create,
  },
  info => {
    summary  => 'Show format, geometry, label and capacity',
    usage    => [ 'info IMAGE' ],
    min_args => 1,
    max_args => 1,
    complete => 'file',
    options  => [],
    run      => \&_cmd_info,
  },
  ls => {
    summary  => 'List image contents',
    usage    => [ 'ls [options] IMAGE [DIR]' ],
    min_args => 1,
    max_args => 2,
    complete => 'file',
    options  => [
      { name => 'recursive', short => 'r', help => 'list subdirectories recursively' },
    ],
    run => \&_cmd_ls,
  },
  extract => {
    summary  => 'Extract image contents to a host directory',
    usage    => [ 'extract IMAGE DEST' ],
    min_args => 2,
    max_args => 2,
    complete => 'file',
    description => <<~'EOF',
      DEST is created if needed.  Existing files are never overwritten; if
      any would be, nothing is extracted.
      EOF
    options  => [],
    run      => \&_cmd_extract,
  },
  validate => {
    summary  => 'Check image integrity',
    usage    => [ 'validate IMAGE' ],
    min_args => 1,
    max_args => 1,
    complete => 'file',
    options  => [],
    run      => \&_cmd_validate,
  },
  formats => {
    summary  => 'List supported formats and automatic selectors',
    usage    => [ 'formats' ],
    min_args => 0,
    max_args => 0,
    options  => [],
    run      => \&_cmd_formats,
  },
  completions => {
    summary  => 'Print shell completions (bash, zsh or fish)',
    usage    => [ 'completions SHELL' ],
    min_args => 1,
    max_args => 1,
    complete => 'shell',
    options  => [],
    run      => \&_cmd_completions,
  },
  help => {
    summary  => 'Show help for fdimg or a command',
    usage    => [ 'help [COMMAND]' ],
    min_args => 0,
    max_args => 1,
    complete => 'command',
    options  => [],
    run      => \&_cmd_help,
  },
);

my %COMMANDS = @COMMANDS;
my @COMMAND_NAMES = map { $COMMANDS[$_ * 2] } 0 .. $#COMMANDS / 2;

sub commands ($class) { @COMMAND_NAMES }
sub command  ($class, $name) { defined $name ? $COMMANDS{$name} : undef }

sub _options ($spec) {
  ( $spec->{options}->@*, { name => 'help', short => 'h', help => 'show help for this command' } );
}

sub _gld_spec ($option) {
  my $spec = $option->{name};
  $spec .= "|$option->{short}" if $option->{short};
  $spec .= '!' if $option->{negatable};
  $spec .= $option->{repeat} ? '=s@' : '=s' if $option->{value};
  return [ $spec, $option->{help} ];
}

sub _describe ($name, @args) {
  my $spec = $COMMANDS{$name};
  local @ARGV = @args;
  my @warnings;
  local $SIG{__WARN__} = sub ($w) { push @warnings, $w };
  my($opt, $usage);
  my $ok = eval {
    ($opt, $usage) = Getopt::Long::Descriptive::describe_options(
      "fdimg $name %o",
      map({ _gld_spec($_) } _options($spec)),
      { getopt_conf => [qw( no_auto_abbrev no_ignore_case bundling permute )] },
    );
    1;
  };
  unless($ok) {
    my @messages = map { s/\s+\z//r } @warnings;
    @messages = ('invalid options') unless @messages;
    die { usage_error => \@messages };
  }
  return ($opt, $usage, [@ARGV]);
}

sub _usage_error ($class, $message, $command = undef) {
  print STDERR "fdimg: $message\n";
  print STDERR defined $command
    ? "Try 'fdimg help $command' for more information.\n"
    : "Try 'fdimg help' for more information.\n";
  return 2;
}

sub version ($class) { $Disk::Diskette::VERSION // 'dev' }

sub main ($class, @args) {
  local $| = 1;

  return $class->_global_help if !@args;

  my $first = $args[0];
  return $class->_global_help if $first eq '--help' || $first eq '-h';
  if($first eq '--version' || $first eq '-V') {
    say "fdimg version @{[ $class->version ]}";
    return 0;
  }
  return $class->_usage_error("unknown option: $first") if $first =~ /\A-/;

  my $name = shift @args;
  my $spec = $COMMANDS{$name};
  return $class->_usage_error("unknown command: $name") unless $spec;

  my($opt, $usage, $argv);
  my $ok = eval { ($opt, $usage, $argv) = _describe($name, @args); 1 };
  unless($ok) {
    my $e = $@;
    if(ref $e eq 'HASH' && $e->{usage_error}) {
      return $class->_usage_error(join("\nfdimg: ", $e->{usage_error}->@*), $name);
    }
    die $e;
  }

  return $class->_command_help($name) if $opt->help;

  if(@$argv < $spec->{min_args} || @$argv > $spec->{max_args}) {
    my $problem = @$argv < $spec->{min_args} ? 'missing arguments' : 'too many arguments';
    return $class->_usage_error("$name: $problem\nusage: " . join("\n       ", map { "fdimg $_" } $spec->{usage}->@*), $name);
  }

  my $exit;
  try {
    $exit = $spec->{run}->($class, $opt, @$argv);
  }
  catch ($e) {
    if(ref $e eq 'HASH' && $e->{usage_error}) {
      return $class->_usage_error(join("\nfdimg: ", $e->{usage_error}->@*), $name);
    }
    if($e isa Disk::Diskette::Error) {
      print STDERR "fdimg: ", $e->message, "\n";
      print STDERR "  $_\n" for $e->details->@*;
    } else {
      print STDERR "fdimg: internal error: $e";
      print STDERR "\n" unless $e =~ /\n\z/;
    }
    return 1;
  }
  return $exit // 0;
}

sub _usage_die ($message) {
  die { usage_error => [ $message ] };
}

sub _global_help ($class) {
  say 'Usage: fdimg COMMAND [options] [arguments]';
  say '';
  say 'Create and inspect raw DOS FAT12 floppy images.';
  say '';
  say 'Commands:';
  my $width = 0;
  $width = length > $width ? length : $width for @COMMAND_NAMES;
  printf "  %-*s  %s\n", $width, $_, $COMMANDS{$_}->{summary} for @COMMAND_NAMES;
  say '';
  say 'Global options:';
  say '  --help, -h     show this help';
  say '  --version, -V  show the version';
  say '';
  say "Run 'fdimg help COMMAND' for command options.";
  return 0;
}

sub _command_help ($class, $name) {
  my $spec = $COMMANDS{$name};
  my(undef, $usage) = _describe($name);
  my @usage = map { "fdimg $_" } $spec->{usage}->@*;
  say 'Usage: ', shift @usage;
  say '       ', $_ for @usage;
  say '';
  say $spec->{summary}, '.';
  if($spec->{description}) {
    say '';
    print $spec->{description};
  }
  say '';
  say 'Options:';
  print $usage->option_text;
  return 0;
}

sub _cmd_help ($class, $opt, $name = undef) {
  return $class->_global_help unless defined $name;
  _usage_die("unknown command: $name") unless $COMMANDS{$name};
  return $class->_command_help($name);
}

sub _cmd_create ($class, $opt, @args) {
  my %args;

  _usage_die('--label and --no-label are mutually exclusive') if defined $opt->label && $opt->no_label;
  _usage_die('--config and --no-config are mutually exclusive') if defined $opt->config && $opt->no_config;

  if($opt->empty) {
    _usage_die('--empty takes exactly one argument: IMAGE') unless @args == 1;
    for my $o (qw( follow_symlinks exclude config no_config )) {
      my $flag = '--' . ($o =~ tr/_/-/r);
      $flag = '--[no-]follow-symlinks' if $o eq 'follow_symlinks';
      _usage_die("$flag is not meaningful with --empty") if defined $opt->$o;
    }
    $args{path} = $args[0];
  } else {
    $args{source} = $args[0];
    $args{path}   = $args[1] if defined $args[1];
  }

  $args{format}          = $opt->format          if defined $opt->format;
  $args{label}           = $opt->label           if defined $opt->label;
  $args{label}           = undef                 if $opt->no_label;
  $args{follow_symlinks} = $opt->follow_symlinks if defined $opt->follow_symlinks;
  $args{exclude}         = $opt->exclude         if defined $opt->exclude;
  $args{config}          = $opt->config          if defined $opt->config;
  $args{config}          = undef                 if $opt->no_config;
  $args{force}           = 1                     if $opt->force;

  my $image = Disk::Diskette->create(%args);
  say "Created @{[ $image->path ]} (@{[ $image->geometry->display_name ]} FAT12)";
  return 0;
}

sub _cmd_info ($class, $opt, $path) {
  my $image = Disk::Diskette->open($path);
  my $g = $image->geometry;
  my @rows = (
    [ 'Image',      $image->path ],
    [ 'Format',     sprintf('%s (%s)', $g->name, $g->description) ],
    [ 'Geometry',   sprintf('%d cylinders, %d heads, %d sectors/track, %d bytes/sector', $g->cylinders, $g->heads, $g->sectors_per_track, $g->bytes_per_sector) ],
    [ 'Filesystem', sprintf('FAT12, media 0x%02X, %d-byte clusters, %d root entries', $g->media_descriptor, $g->cluster_bytes, $g->root_entries) ],
    [ 'Label',      $image->label // '(none)' ],
    [ 'Serial',     $image->serial // '(none)' ],
    [ 'Size',       sprintf('%d bytes', $image->size_bytes) ],
    [ 'Capacity',   sprintf('%d bytes', $g->data_bytes) ],
    [ 'Free',       sprintf('%d bytes', $image->free_bytes) ],
  );
  printf "%-11s %s\n", "$_->[0]:", $_->[1] for @rows;
  return 0;
}

sub _time ($epoch) {
  return '                ' unless defined $epoch;
  POSIX::strftime('%Y-%m-%d %H:%M', gmtime $epoch);
}

sub _cmd_ls ($class, $opt, $path, $dir = '/') {
  my $image = Disk::Diskette->open($path);
  my @entries = $opt->recursive ? $image->walk($dir) : $image->entries($dir);
  for my $entry (@entries) {
    my $name = $opt->recursive ? $entry->path : $entry->name;
    $name .= '/' if $entry->is_directory;
    printf "%s  %10s  %s  %s\n",
      $entry->attribute_string,
      $entry->is_directory ? '<DIR>' : $entry->size,
      _time($entry->mtime),
      $name;
  }
  return 0;
}

sub _cmd_extract ($class, $opt, $path, $dest) {
  my $image = Disk::Diskette->open($path);
  my @written = $image->extract_to($dest);
  say "Extracted @{[ scalar @written ]} entries to $dest";
  return 0;
}

sub _count ($n, $one, $many = "${one}s") { "$n " . ($n == 1 ? $one : $many) }

sub _cmd_validate ($class, $opt, $path) {
  my $image = Disk::Diskette->open($path);
  my $result = $image->validate;
  say sprintf '%s: OK (%s FAT12, %s, %s, %d bytes free)',
    $path, uc $result->{format}, _count($result->{files}, 'file'), _count($result->{directories}, 'directory', 'directories'), $result->{free_bytes};
  return 0;
}

sub _cmd_formats ($class, $opt) {
  say 'Fixed formats:';
  printf "  %-6s %3s %2s %3s  %8s  %s\n", 'NAME', 'CYL', 'HD', 'SPT', 'BYTES', 'MEDIA';
  for my $f (Disk::Diskette::Format->all) {
    printf "  %-6s %3d %2d %3d  %8d  %s\n", $f->name, $f->cylinders, $f->heads, $f->sectors_per_track, $f->size_bytes, $f->description;
  }
  say '';
  say 'Automatic selectors (smallest fitting candidate is used):';
  for my $name (Disk::Diskette::Format->auto_names) {
    my $default = $name eq Disk::Diskette::Format->default_selector ? '  (default)' : '';
    printf "  %-11s %s%s\n", $name, join(', ', map { $_->name } Disk::Diskette::Format->candidates($name)), $default;
  }
  return 0;
}

my @SHELLS = qw( bash zsh fish );

sub _cmd_completions ($class, $opt, $shell) {
  my $method = "_completions_$shell";
  _usage_die("unsupported shell: $shell (supported: @SHELLS)") unless any { $_ eq $shell } @SHELLS;
  print $class->$method;
  return 0;
}

sub _completion_words ($kind) {
  return $FORMATS->() if $kind eq 'format';
  return @SHELLS if $kind eq 'shell';
  return @COMMAND_NAMES if $kind eq 'command';
  return ();
}

sub _option_flags ($option) {
  my @flags = ("--$option->{name}");
  push @flags, "--no-$option->{name}" if $option->{negatable};
  push @flags, "-$option->{short}" if $option->{short};
  return @flags;
}

sub _completions_bash ($class) {
  my $out = "# bash completion for fdimg\n_fdimg() {\n";
  $out .= "  local cur prev cmd\n";
  $out .= "  cur=\"\${COMP_WORDS[COMP_CWORD]}\"\n";
  $out .= "  prev=\"\${COMP_WORDS[COMP_CWORD-1]}\"\n";
  $out .= "  if [ \"\$COMP_CWORD\" -eq 1 ]; then\n";
  $out .= "    COMPREPLY=( \$(compgen -W \"@COMMAND_NAMES --help --version\" -- \"\$cur\") )\n";
  $out .= "    return\n  fi\n";
  $out .= "  cmd=\"\${COMP_WORDS[1]}\"\n";
  $out .= "  case \"\$cmd \$prev\" in\n";
  for my $name (@COMMAND_NAMES) {
    for my $option (_options($COMMANDS{$name})) {
      next unless $option->{value};
      my @flags = grep { !/\A--no-/ } _option_flags($option);
      my $patterns = join '|', map { "\"$name $_\"" } @flags;
      if(($option->{complete} // '') eq 'format') {
        $out .= "    $patterns) COMPREPLY=( \$(compgen -W \"@{[ $FORMATS->() ]}\" -- \"\$cur\") ); return ;;\n";
      } elsif(($option->{complete} // '') eq 'file') {
        $out .= "    $patterns) COMPREPLY=( \$(compgen -f -- \"\$cur\") ); return ;;\n";
      } else {
        $out .= "    $patterns) COMPREPLY=(); return ;;\n";
      }
    }
  }
  $out .= "  esac\n";
  $out .= "  case \"\$cmd\" in\n";
  for my $name (@COMMAND_NAMES) {
    my $spec = $COMMANDS{$name};
    my @flags = map { _option_flags($_) } _options($spec);
    my $complete = $spec->{complete} // '';
    my $positional = $complete eq 'file' ? 'COMPREPLY=( $(compgen -f -- "$cur") )'
                   : $complete          ? "COMPREPLY=( \$(compgen -W \"@{[ _completion_words($complete) ]}\" -- \"\$cur\") )"
                   :                      'COMPREPLY=()';
    $out .= "    $name)\n";
    $out .= "      if [[ \"\$cur\" == -* ]]; then\n";
    $out .= "        COMPREPLY=( \$(compgen -W \"@flags\" -- \"\$cur\") )\n";
    $out .= "      else\n";
    $out .= "        $positional\n";
    $out .= "      fi ;;\n";
  }
  $out .= "  esac\n";
  $out .= "}\n";
  $out .= "complete -o filenames -o bashdefault -F _fdimg fdimg\n";
  return $out;
}

sub _zsh_quote ($text) { $text =~ s/([\[\]:'\\])/\\$1/gr }

sub _completions_zsh ($class) {
  my $out = "#compdef fdimg\n\n_fdimg() {\n";
  $out .= "  local -a commands\n  commands=(\n";
  $out .= "    '$_:@{[ _zsh_quote($COMMANDS{$_}->{summary}) ]}'\n" for @COMMAND_NAMES;
  $out .= "  )\n";
  $out .= "  if (( CURRENT == 2 )); then\n";
  $out .= "    _describe -t commands 'fdimg command' commands\n";
  $out .= "    _arguments '(- *)--help[show help]' '(- *)--version[show the version]'\n" ;
  $out .= "    return\n  fi\n";
  $out .= "  local cmd=\$words[2]\n";
  $out .= "  shift words\n  (( CURRENT-- ))\n";
  $out .= "  case \$cmd in\n";
  for my $name (@COMMAND_NAMES) {
    my $spec = $COMMANDS{$name};
    my @specs;
    for my $option (_options($spec)) {
      my $help = _zsh_quote($option->{help});
      my $action = '';
      if($option->{value}) {
        my $complete = $option->{complete} // '';
        $action = $complete eq 'format' ? ":format:(@{[ $FORMATS->() ]})"
                : $complete eq 'file'   ? ':file:_files'
                :                         ':value: ';
      }
      my $repeat = $option->{repeat} ? '*' : '';
      if($option->{negatable}) {
        push @specs, "'(--no-$option->{name})--$option->{name}\[$help\]'";
        push @specs, "'(--$option->{name})--no-$option->{name}\[$help\]'";
      } elsif($option->{short}) {
        my $excl = $repeat ? '*' : "(-$option->{short} --$option->{name})";
        push @specs, "'$excl'{-$option->{short},--$option->{name}}'\[$help\]$action'";
      } else {
        push @specs, "'$repeat--$option->{name}\[$help\]$action'";
      }
    }
    my $complete = $spec->{complete} // '';
    if($spec->{max_args}) {
      my $action = $complete eq 'file' ? '_files'
                 : $complete          ? "(@{[ _completion_words($complete) ]})"
                 :                      ' ';
      push @specs, "'*:argument:$action'";
    }
    $out .= "    $name)\n      _arguments \\\n";
    $out .= join " \\\n", map { "        $_" } @specs;
    $out .= "\n      ;;\n";
  }
  $out .= "  esac\n}\n\n_fdimg \"\$\@\"\n";
  return $out;
}

sub _fish_quote ($text) { "'" . ($text =~ s/(['\\])/\\$1/gr) . "'" }

sub _completions_fish ($class) {
  my $out = "# fish completion for fdimg\n";
  $out .= "complete -c fdimg -f\n";
  $out .= "complete -c fdimg -n __fish_use_subcommand -l help -s h -d 'show help'\n";
  $out .= "complete -c fdimg -n __fish_use_subcommand -l version -s V -d 'show the version'\n";
  for my $name (@COMMAND_NAMES) {
    my $spec = $COMMANDS{$name};
    $out .= "complete -c fdimg -n __fish_use_subcommand -a $name -d @{[ _fish_quote($spec->{summary}) ]}\n";
    my $cond = "'__fish_seen_subcommand_from $name'";
    for my $option (_options($spec)) {
      my @parts = ("complete -c fdimg -n $cond -l $option->{name}");
      push @parts, "-s $option->{short}" if $option->{short};
      if($option->{value}) {
        my $complete = $option->{complete} // '';
        push @parts, $complete eq 'format' ? "-x -a '@{[ $FORMATS->() ]}'"
                   : $complete eq 'file'   ? '-r -F'
                   :                         '-x';
      }
      push @parts, '-d', _fish_quote($option->{help});
      $out .= "@parts\n";
      $out .= "complete -c fdimg -n $cond -l no-$option->{name} -d @{[ _fish_quote($option->{help}) ]}\n" if $option->{negatable};
    }
    my $complete = $spec->{complete} // '';
    if($complete eq 'file') {
      $out .= "complete -c fdimg -n $cond -F\n";
    } elsif($complete) {
      $out .= "complete -c fdimg -n $cond -a '@{[ _completion_words($complete) ]}'\n";
    }
  }
  return $out;
}

=head2 version

 my $version = App::fdimg->version;

The distribution version.

=cut
