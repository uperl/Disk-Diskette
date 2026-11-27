package Test::Diskette;

use v5.42;
use warnings;
use Test2::API qw( context );
use Path::Tiny ();
use File::Spec ();
use Capture::Tiny ();
use Exporter 'import';
use Disk::Diskette::Backend::Mtools;

our @EXPORT = qw( tmpdir require_mtools make_tree fsck_ok mdir_paths have_program error_like );

# Skip the current test file unless mtools is available.  In CI set
# FDIMG_REQUIRE_MTOOLS=1 so that missing mtools is a failure, not a skip.
sub require_mtools () {
  return if Disk::Diskette::Backend::Mtools->new->available;
  my $ctx = context();
  if($ENV{FDIMG_REQUIRE_MTOOLS}) {
    $ctx->bail('mtools is required (FDIMG_REQUIRE_MTOOLS is set) but was not found in PATH');
  }
  $ctx->plan(0, SKIP => 'mtools (mformat, mcopy, mmd) not found in PATH');
  $ctx->release;
  return;
}

# a fresh directory path inside a temporary directory kept until exit
my @KEEP;
sub tmpdir ($name = q{tmp}) {
  my $tmp = Path::Tiny->tempdir;
  push @KEEP, $tmp;
  my $dir = $tmp->child($name);
  $dir->mkpath;
  return $dir;
}

sub have_program ($name) {
  for my $dir (File::Spec->path, '/sbin', '/usr/sbin') {
    my $exe = File::Spec->catfile($dir, $name);
    return $exe if -f $exe && -x $exe;
  }
  return undef;
}

# make_tree($dir, 'a.txt' => 'content', 'sub/' => undef, 'sub/b.txt' => \1000)
# a scalar ref gives a size of filler bytes.
sub make_tree ($dir, @spec) {
  $dir = Path::Tiny::path($dir);
  $dir->mkpath;
  while(my($name, $content) = splice @spec, 0, 2) {
    my $path = $dir->child($name);
    if($name =~ m{/\z}) {
      $path->mkpath;
    } else {
      $path->parent->mkpath;
      $content = 'x' x $$content if ref $content eq 'SCALAR';
      $path->spew_raw($content // '');
    }
  }
  return $dir;
}

# independent filesystem check with dosfstools, when available
sub fsck_ok ($image, $name = "fsck.fat accepts $image") {
  my $ctx = context();
  my $fsck = have_program('fsck.fat');
  unless($fsck) {
    $ctx->skip($name, 'fsck.fat not available');
    $ctx->release;
    return 1;
  }
  my($out, $err, $exit) = Capture::Tiny::capture(sub { system $fsck, '-n', "$image"; $? });
  my $ok = $exit == 0;
  $ctx->ok($ok, $name, $ok ? () : ["exit $exit", $out, $err]);
  $ctx->release;
  return $ok;
}

# bare recursive listing using mtools itself (interoperability check)
sub mdir_paths ($image) {
  my $mdir = have_program('mdir') or return undef;
  local $ENV{MTOOLS_SKIP_CHECK} = 1;
  local $ENV{MTOOLSRC} = File::Spec->devnull;
  my($out) = Capture::Tiny::capture(sub { system $mdir, '-i', "$image", '-/', '-b', '::' });
  [ sort map { s{\A::}{}r =~ s{/\z}{}r } grep { length } split /\n/, $out ];
}

sub error_like :prototype(&$;$) ($code, $pattern, $name = "throws $pattern") {
  my $ctx = context();
  my $ok = eval { $code->(); 1 };
  my $e = $@;
  if($ok) {
    $ctx->ok(0, $name, ['no exception thrown']);
  } elsif(!(ref $e && $e isa Disk::Diskette::Error)) {
    $ctx->ok(0, $name, ["not a Disk::Diskette::Error: $e"]);
  } else {
    my $string = "$e";
    $ctx->ok(scalar($string =~ $pattern), $name, $string =~ $pattern ? () : ["got: $string"]);
  }
  $ctx->release;
  return $e;
}
