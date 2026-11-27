# Disk-Diskette design

## 1. Purpose and scope

`Disk::Diskette` is a Perl library for creating and manipulating raw DOS FAT12 floppy images on modern Linux and macOS hosts. The accompanying `fdimg` command is a thin interface to the library. The primary use case is maintaining a directory of DOS software and generating an image suitable for copying directly to a Gotek/FlashFloppy USB stick, use in an emulator, or a software release pipeline (including GR-DOS).

Images are standalone, uncompressed sector dumps (`.img`), not multiplexed Gotek images, container formats, or partitioned hard disks. Operations require no root privileges, mounting, loop devices, or changes to global mtools configuration. Direct access to physical block devices is out of scope. Other filesystems, OEM code pages and nonstandard geometries are future possibilities, not initial requirements.

## 2. Development conventions

Follow [PERLSTYLE.md](PERLSTYLE.md), minted by the Author::Plicease profile for new Perl 5.42 distributions. This project explicitly chooses **Moo version 2 or later** instead of the default Class::Tiny, principally for read-only attributes. Prefer immutable geometry and metadata objects; mutation of image contents is explicit.

Use Perl 5.42, stable language features, `Path::Tiny` for filesystem work, and `Capture::Tiny` for command execution/output capture where appropriate. Use `Getopt::Long::Descriptive` (GLD) for CLI parsing with a lightweight internal subcommand dispatcher. This is a project-specific choice, not a general Perl style rule. Do not introduce App::Cmd or MooX::Options. The TOML 1.0 parser is `TOML::Tiny` (pure Perl, publicly maintained); its API stays private to `Disk::Diskette::Config`, which uses its typed-inflation hooks so that strings, booleans, integers, floats and datetimes can be distinguished for schema validation. Do not introduce unrelated dependencies merely because the style guide recommends them.

Use Dist::Zilla with `@Author::Plicease`. Declare runtime and test prerequisites separately, including Moo >= 2, and the Perl baseline. The mtools executables are external runtime requirements; explain installation in the user documentation. `fsck.fat`, emulators and physical hardware are optional independent test tools.

Repository: `uperl/Disk-Diskette` (proposed location); distribution: `Disk-Diskette`; library: `Disk::Diskette`; application module: `App::fdimg`; executable: `fdimg`. Keep `AGENTS.md` in the repository root, referencing `docs/PERLSTYLE.md` and `docs/DESIGN.md`.

## 3. Architecture

```text
bin/fdimg                 Perl scripts
    |                          |
App::fdimg                     |
    +--------> Disk::Diskette <-+
                   |
           format/config/manifest/image
                   |
           Backend::Mtools
                   |
             raw FAT12 image
```

The library never depends on App::fdimg. Every disk operation available through the CLI must be available programmatically without invoking fdimg or parsing its output. Keep the library silent by default; return structured results and throw helpful exceptions. CLI code owns argument parsing, presentation and exit status mapping.

Proposed module layout (internal boundaries may evolve):

| Module | Responsibility |
| --- | --- |
| `Disk::Diskette` | Public create/open entry points and orchestration |
| `Disk::Diskette::Image` | Open image metadata and content operations |
| `Disk::Diskette::Format` | Geometry registry, FAT layout and automatic selection |
| `Disk::Diskette::Config` | TOML loading, schema validation and precedence |
| `Disk::Diskette::Manifest` | Source traversal, normalization, exclusions and capacity planning |
| `Disk::Diskette::Backend::Mtools` | External FAT operations and backend diagnostics |
| `Disk::Diskette::Entry` | Immutable directory entry metadata returned by image methods |
| `Disk::Diskette::Error` | Exception class for expected failures (message plus detail lines) |
| `Disk::Diskette::Name` (internal) | DOS 8.3 short name and volume label rules |
| `Disk::Diskette::FAT12` (internal) | Read-only native FAT12 parser and structural checker |
| `App::fdimg` | CLI registry, parsing, dispatch, help and completions |

All writes go through mtools. Reading (inspection, verification after creation, `validate` and extraction) is done by the internal `Disk::Diskette::FAT12` parser, so no machine interpretation depends on mtools' human-readable output. Images are at most 2.88 MB and are read into memory.

Keep backend details private and avoid implementing a second backend until needed. Use mformat, mcopy, mdir, minfo, mmd, mdel, mrd, mlabel and mattrib as applicable. Centralize executable discovery and subprocess handling. Invoke commands with argument lists, never shell interpolation. Isolate mtools configuration/environment so user configuration does not change image semantics: subprocesses get a private empty `HOME` and `MTOOLSRC`, inherited `MTOOLS_*`, `LANG`/`LC_*` and `SOURCE_DATE_EPOCH` are removed, and `MTOOLS_SKIP_CHECK=1`, `MTOOLS_NO_VFAT=1`, `MTOOLS_LOWER_CASE=0`, `MTOOLS_NAME_NUMERIC_TAIL=1`, `LC_ALL=C` and `TZ=UTC` are set (environment settings take precedence over the system configuration file). Standard input is the null device so mtools never prompts. Handle spawn failure, signal termination, nonzero exit and unexpected results distinctly. Do not depend on localized output for machine interpretation; use a controlled locale and documented machine-friendly output or read the image metadata directly where necessary.

## 4. Formats and drive compatibility

All initial geometries use 512-byte sectors and FAT12. The registry is the single source of truth for geometry, FAT layout, selectors, CLI help and completions.

| Fixed selector | Cylinders | Heads | Sectors/track | Image bytes |
| --- | ---: | ---: | ---: | ---: |
| `160k` | 40 | 1 | 8 | 163840 |
| `180k` | 40 | 1 | 9 | 184320 |
| `320k` | 40 | 2 | 8 | 327680 |
| `360k` | 40 | 2 | 9 | 368640 |
| `720k` | 80 | 2 | 9 | 737280 |
| `1200k` | 80 | 2 | 15 | 1228800 |
| `1440k` | 80 | 2 | 18 | 1474560 |
| `2880k` | 80 | 2 | 36 | 2949120 |

Use format-appropriate media descriptor, BPB, sectors per cluster, reserved sectors, FAT copies and size, and root directory entry count. Verified: with explicit `-t/-h/-s/-c/-r/-m` parameters, mtools 4.0.49 `mformat` produces exactly the conventional DOS layout for every preset (one reserved sector, two FATs; FAT sectors 1, 2, 1, 2, 3, 7, 9, 9 and root entries 64, 64, 112, 112, 112, 224, 224, 240 respectively). Creation verifies the BPB of every image it writes. The early formats may require special handling for historical DOS versions without conventional BPBs; support for those versions is not implied merely by supporting their image sizes.

Automatic selectors choose the smallest compatible format that fits the complete source, not simply any geometry smaller than a byte limit:

| Selector | Candidates in order |
| --- | --- |
| `auto-360k` | 360k |
| `auto-720k` | 720k |
| `auto-1200k` | 360k, 1200k |
| `auto-1440k` (default) | 720k, 1440k |
| `auto-2880k` | 720k, 1440k, 2880k |

Historical 160k, 180k and 320k are explicit only. Never promote outside the selected drive family. Actual BIOS, controller, drive and media support can vary; these selectors describe conventional compatibility, not a hardware guarantee. For 1.2M drives, writing 360K media on real hardware can have interchange limitations. The library only creates image files.

Re-evaluate on every creation, allowing a smaller image when content shrinks. Promote only for capacity constraints (including root directory exhaustion), not malformed source, invalid names or backend failures. Existing images never silently resize or change geometry on mutation. `format` on the resulting image reports the actual fixed format.

## 5. Configuration and defaults

Read `.fdimg.toml` at the root of a source directory. Do not search parent or nested directories. This file is host-side metadata and never copied to the image.

```toml
format = "auto-1440k"
label = "UTILITIES"
follow_symlinks = true
exclude = ["README.md", "*.bak"]
```

Precedence is per key: explicit CLI/API arguments > configuration > built-in/derived defaults. Do not let GLD's implicit defaults overwrite configuration. An explicit false is distinct from omission. Explicit exclusion lists replace configured lists, rather than append; multiple CLI `--exclude` options form one list. The API can supply an empty list to clear configured exclusions.

| Setting | Default |
| --- | --- |
| format | `auto-1440k` |
| label | uppercase source directory basename; no label if empty creation |
| follow_symlinks | true |
| exclude | empty list, in addition to implicit hidden-entry exclusion |
| output path | source directory path with `.img` appended, alongside source |
| force | false; explicit invocation only, not TOML |

Initial TOML keys are `format`, `label`, `follow_symlinks`, `exclude`. Reject unknown keys, wrong types, invalid values and malformed TOML with filename and contextual diagnostics. TOML has no null; propose `label = ""` to request no label (API uses `undef`). Explicit label values are normalized to uppercase and validated. Validate effective settings after precedence; malformed config and schema errors remain errors even when overrides are supplied.

`--config PATH` / API `config` selects an explicit config file; `--no-config` / API `config => undef` disables discovery. These are mutually exclusive CLI options. An explicit config file must exist and be readable. Resolve future path-valued configuration settings relative to the config file; exclusion patterns always refer to source-relative paths. An alternate config inside the source is excluded from copying. Config loading and merging are reusable library functions, not CLI-only code.

Normalize trailing separators and resolve `.` sensibly when deriving basename and output. For an input directory without a usable basename (such as filesystem root), require explicit label/output as applicable. Reject source/output aliasing and destinations inside the source tree for bulk creation (proposed safety rule; avoids self-inclusion). No output path is implied for empty creation.

## 6. Source tree and FAT12 semantics

### 6.1 Exclusions

Ignore entries whose names start with `.` at every level, including hidden directories and all descendants. The root `.fdimg.toml` is read only as configuration; nested copies are simply ignored. Do not implicitly read `.gitignore`. Explicit exclusions are applied before name validation, symlink resolution, collision detection and capacity planning. Excluded directories are not traversed.

Use shell-style glob patterns, not regexes, on original source-relative paths with `/` separators. Implemented semantics: a pattern without `/` matches a basename at any depth; a pattern with `/` matches the whole source-relative path, and a leading `/` is permitted to anchor a pattern to the source root (`/README.md`); `*` and `?` do not cross `/`; character classes (`[abc]`, `[a-z]`, negated with `!` or `^`) are supported; a backslash makes the next character literal; matching is case-sensitive on the host name. `**`, a trailing `/`, empty patterns and unterminated classes are rejected. `**` recursive path matching may be added later. Quote CLI patterns to prevent host shell expansion.

### 6.2 Short names

Accept upper, lower and mixed case; normalize to uppercase DOS 8.3. No VFAT long-name entries, generated aliases, truncation, replacement characters or silent sanitization. Validate each directory component: nonempty base of 1–8 characters, optional extension of 1–3 characters, at most one separating dot. Reject invalid ASCII characters, spaces, control characters, trailing dots, path separators and reserved DOS device names (including extensions on CON, PRN, AUX, NUL, COM1–COM9, LPT1–LPT9). Restrict initial encoding to the DOS-compatible ASCII subset. Permitted characters are `A`–`Z`, `0`–`9` and `` ! # $ % & ( ) - @ ^ _ ` { } ~ ``. The apostrophe is legal in DOS but rejected because mtools 4.0.49 turns it into a long-name entry (as it does `+ , ; = [ ]`, which DOS also forbids in short names). `CLOCK$` is also treated as a reserved device name. Do not use locale-dependent Unicode case folding.

Detect collisions per destination directory after normalization, including file/file, directory/directory, file/directory and conflicts with existing entries. Report both source paths and the normalized destination. Different directories may contain the same name. For example `readme.txt` and `README.TXT` in one directory are an error, not overwrite candidates.

### 6.3 Symlinks and file types

Regular files are copied, regular directories traversed. By default, follow symbolic links resolving to regular files, including relative/absolute links, chains and targets outside the source tree. Validate the link name, not the target basename. Copy target contents into independent FAT files; no shared clusters or link representation. Hard-linked regular files are also copied independently. Count each copy separately for capacity planning. This supports DOS executables whose behavior depends on their invocation name.

Reject directory symlinks, dangling links, cycles, special files and links to special files with helpful diagnostics. `--no-follow-symlinks` / `follow_symlinks => 0` rejects all non-excluded symlinks rather than skipping them. `--follow-symlinks` explicitly restores default behavior over configuration. Implement policy in the library, not by relying on mcopy traversal. Document that external link targets may include data outside the source tree.

### 6.4 Labels, metadata and capacity

FAT volume labels permit up to 11 characters and have different character rules from 8.3 names; the implementation allows the short-name character set plus embedded (not leading or trailing) spaces, and no dot. Uppercase and validate labels; no silent truncation or sanitization. Invalid derived labels are errors with suggestions to set `--label`, edit TOML or use `--no-label`. Explicit unlabeled overrides config and derived defaults. Empty images default to unlabeled. Count any root directory volume-label entry in capacity planning.

Preserve source modification timestamps by default subject to documented FAT range and two-second granularity. For symlinks use the target file timestamp. Do not promise POSIX permissions, ownership or link preservation. Support explicit DOS attributes where needed (milestone 3). Defaults as implemented: files receive the archive attribute only (mtools' default); FAT timestamps are written and read as UTC; times are truncated to the two-second granularity; modification times before 1980-01-01T00:00:00Z or after 2107-12-31T23:59:58Z are clamped to that range (mtools would otherwise wrap them). Each file's time is passed to `mcopy` via a per-invocation `SOURCE_DATE_EPOCH`, which gives the library full control of the stored value.

Capacity planning must include per-file cluster rounding, directories (including dot entries and directory growth), root entry limits, volume label and format-specific reserved/FAT/root overhead. Zero-byte files still consume directory entries. A capacity failure reports which constraint failed, and for automatic selectors reports why each candidate did not fit. Never silently omit an entry or split across disks.

## 7. Creation workflow and safety

1. Resolve source, output and configuration; reject unsuitable source/output types.
2. Build a normalized manifest in deterministic traversal order, applying exclusions and validating file types, readable inputs, names and collisions.
3. Derive and validate label; select a compatible format using actual allocation requirements.
4. Create a temporary image in the destination directory, with the exact expected length and valid FAT12 layout.
5. Populate it using mtools with explicit destination short names; ensure no long-name entries are created. Avoid accidental host shell or mtools wildcard interpretation.
6. Verify the image length, geometry, filesystem structure, expected names and file inventory; detect backend truncation, renaming or omission. Verify data as appropriate; independent validators belong in integration tests.
7. Publish only after success. Without force, publish with `link()`, which fails if the destination appeared after the preflight check (on filesystems without hard links, reserve the name with `O_CREAT|O_EXCL` and rename over the reservation). With force, `rename()` replaces atomically. Preserve existing image on any earlier failure and clean up temporary files.

Directories are created (parents first, in manifest order) before files are copied, giving a deterministic directory and allocation order. Verification compares the complete image inventory with the manifest, re-reads every source file to compare contents, and fails if a source file's size or modification time changed during the build.

Reject destination symlinks and nonregular destination objects; never follow an output symlink to overwrite another file. Apply analogous transactional semantics to existing-image mutations via a working copy. Define concurrency guarantees explicitly; concurrent writers are not a supported workflow unless locking is added. Avoid trusting a stale preflight: backend errors or source changes during copying must not produce a silently incomplete image.

Diagnostics should provide the operation, offending paths, constraint and resolution where useful. CLI example:

```text
fdimg: DOS filename collision: /README.TXT
  files/README.TXT and files/readme.txt map to the same name
```

## 8. Public Perl API

The public interface is object-based and independent of CLI parsing. Proposed initial contract:

```perl
use v5.42;
use warnings;
use Disk::Diskette;

my $disk = Disk::Diskette->create(source => './utilities');
say $disk->format; # actual selected fixed format
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

`create` returns a `Disk::Diskette::Image` only after successful publication. Omit `source` for an empty image; require `path` in that case. Config discovery occurs for source-based creation. Omit `label` to derive it; explicit `undef` means unlabeled. Other optional fields follow section 5. Empty automatic creation chooses the first compatible candidate. `open` validates supported geometry and filesystem and returns an image object without modifying it.

Proposed image methods (final signatures should be documented in POD):

| Method | Contract |
| --- | --- |
| `path`, `format`, `label` | Image path, actual fixed selector, label or undef |
| `geometry` | Read-only format/geometry object |
| `size_bytes`, `free_bytes` | Raw image size and free allocatable data bytes |
| `entries($directory)` | Structured directory entry objects; root by default |
| `extract_to($host_directory)` | Extract image contents safely |
| `validate` | Validate layout and filesystem; return structured result or throw on invalidity |
| `add_file($host_file, $destination)` | Add a file, destination defaults to root and normalized basename |
| `add_directory($host_directory, $destination)` | Copy directory contents into destination; default root |
| `mkdir($destination)` | Create a DOS directory |
| `remove($destination, %options)` | Remove a file or directory; require explicit recursive permission for nonempty directories |

Use `/` for internal image paths, independent of host path separators; resolve relative image paths from root. Reject traversal above root, device syntax and ambiguous components. Extraction must not escape the destination, follow pre-existing host symlinks or silently overwrite host files. Explicit overwrite controls should never bypass source collision detection. Add operations use the same naming, symlink and capacity rules as creation; no implicit geometry promotion. A failed mutation preserves the original image. Return structured metadata (name, type, size, timestamps and DOS attributes as available), not parsed human-readable CLI output. Keep internal backend/parser classes private unless explicitly documented as public.

Config API should expose reusable load/resolve operations; a format registry API should expose supported geometries and candidate lists. Define stable error/result types only where useful; initial exceptions must be descriptive and not print directly. Exact low-level method signatures and exception classes may be refined before the first public release.

## 9. CLI contract

`bin/fdimg` contains essentially:

```perl
#!/usr/bin/env perl
use v5.42;
use warnings;
use App::fdimg;

exit App::fdimg->main(@ARGV);
```

`main` accepts explicit arguments, returns an exit code, never exits the process, never leaves global `@ARGV` modified, and is safe for repeated sequential invocations. Localize `@ARGV` around GLD parsing. Catch parser failures and library exceptions at the CLI boundary. Use a central command registry for dispatch/help/completions. Normal output goes to STDOUT, diagnostics to STDERR. Proposed exit codes: 0 success/help/version, 1 operation failure, 2 CLI usage error. No stack traces for expected user errors.

### 9.1 Create

```sh
fdimg create utilities/
fdimg create utilities/ release/disk1.img
fdimg create --format auto-1200k --force utilities/
fdimg create --label UTILITIES --exclude '*.bak' utilities/
fdimg create --no-label --no-follow-symlinks utilities/
fdimg create --empty --format 360k disk.img
```

Syntax: `fdimg create [options] SOURCE [IMAGE]` or `fdimg create --empty [options] IMAGE`.

| Option | Meaning |
| --- | --- |
| `--format`, `-f` | Fixed or automatic format selector |
| `--label`, `-l` | Explicit label |
| `--no-label` | Explicitly unlabeled; mutually exclusive with --label |
| `--follow-symlinks` / `--no-follow-symlinks` | Override symlink policy |
| `--exclude PATTERN` | Repeatable explicit exclusion list |
| `--config PATH` / `--no-config` | Configuration selection/discovery control |
| `--force` | Permit atomic replacement of existing image |
| `--empty` | No source tree; require explicit image path |
| `--help`, `-h` | Command help |

Reject meaningless source-only options for empty creation. Report actual selected format and destination on success, e.g. `Created utilities.img (720K FAT12)`. No success message on failure.

### 9.2 Other commands

| Command syntax | Purpose |
| --- | --- |
| `fdimg info IMAGE` | Format, geometry, filesystem, volume label, raw size and available capacity |
| `fdimg ls IMAGE [DIR]` | List contents; root default; consider recursive option |
| `fdimg extract IMAGE DEST` | Extract to host directory; no implicit overwrite |
| `fdimg formats` | List fixed formats and automatic selectors/candidates |
| `fdimg validate IMAGE` | Check image integrity |
| `fdimg add IMAGE SOURCE [DEST]` | Add host file or directory contents |
| `fdimg rm IMAGE PATH` | Remove entry; explicit recursive option for nonempty directory |
| `fdimg mkdir IMAGE PATH` | Create image directory |
| `fdimg completions SHELL` | Generate Bash, Zsh or Fish completions |
| `fdimg help [COMMAND]` | Global or command-specific help |

Support `fdimg`, `fdimg --help`, `fdimg --version`, `fdimg help create`, and `fdimg create --help`. No arguments displays help. Shell completions should use the same command and format registry. Final mutation/extraction option spellings may be refined before those commands ship; document all overwrite and recursive behavior.

## 10. Reproducibility and bootable images

Use deterministic manifest ordering and allocation order where supported. Preserve file modification times normally. Support `SOURCE_DATE_EPOCH` in reproducible mode, including deterministic FAT timestamps and volume serial numbers where possible. Implemented: the API option `source_date_epoch` (defaulting to the environment variable; explicit `undef` disables it) enables reproducible mode. File timestamps are clamped to the epoch, directory entries and the volume label use it, and the volume serial number is its low 32 bits (passed explicitly with `mformat -N`, because mtools derives the serial from the wall clock). Values that are not non-negative integers, or that fall outside the FAT timestamp range, are errors. Repeated builds with the same epoch are tested to be byte-for-byte identical with a single mtools version; the boot sector OEM name contains the mtools version (for example `MTOO4049`), so images are not identical across mtools versions. Do not claim byte-for-byte reproducibility until independently tested across repeated builds and supported mtools versions. Document remaining backend limitations.

Initial creation makes a formatted data disk, not necessarily a bootable DOS disk. Plan early follow-up support for custom boot code preserving the generated BPB, and optionally complete boot sector replacement only with validated geometry/layout compatibility. Later support DOS-specific system disk installation and required system-file ordering/placement (including GR-DOS). Merely copying system files does not guarantee bootability. Keep these operations distinct from ordinary file copying. Future multi-disk packing is useful but explicitly outside the initial scope.

## 11. Testing

Use the standard test preamble from PERLSTYLE.md:

```perl
use v5.42;
use Test2::V0 -no_srand => 1;
```

At least one `.t` file per module: `t/foo_bar_baz.t` for `Foo::Bar::Baz`; when split, `t/foo_bar_baz__topic.t`. Proposed initial files:

```text
t/app_fdimg.t
t/app_fdimg__smoke.t               executable smoke test
t/disk_diskette.t
t/disk_diskette__auto.t            automatic selection and capacity boundaries
t/disk_diskette__formats.t         every fixed geometry
t/disk_diskette__reproducible.t
t/disk_diskette__safety.t
t/disk_diskette_backend_mtools.t
t/disk_diskette_config.t
t/disk_diskette_entry.t
t/disk_diskette_error.t
t/disk_diskette_fat12.t
t/disk_diskette_format.t
t/disk_diskette_image.t
t/disk_diskette_manifest.t
t/disk_diskette_name.t
```

Shared helpers live in `t/lib/Test/Diskette.pm`. Tests that need mtools skip with a reason when it is missing, unless `FDIMG_REQUIRE_MTOOLS=1` is set, in which case they bail out; CI sets it. The Linux (cip) workflow installs `mtools` and `dosfstools` via `maint/cip-before-install`; the macOS workflow installs them with Homebrew and runs `prove -lr t`.

Test CLI directly with `Capture::Tiny` around `App::fdimg->main(@args)` and check return status, STDOUT, STDERR, repeated invocation and unchanged caller `@ARGV`. Include an executable smoke test. Keep ordinary `prove -l` development possible; skip optional external integration tests with clear reasons when unavailable, but ensure CI actually installs mtools and exercises the integration suite on Linux and macOS.

Coverage requirements:

- Every fixed geometry: image length, BPB/FAT parameters, empty and populated images, independent filesystem validation and round-trip extraction.
- Automatic selectors: boundary sizes, root entry exhaustion, directory cluster allocation, growth/shrinkage and no cross-drive promotion.
- Config precedence: defaults, malformed TOML, unknown keys, explicit false, unlabeled override, exclusion replacement, explicit config and no-config.
- Source names: 8.3 boundary cases, legal punctuation, invalid ASCII/non-ASCII, case collisions, file-directory collisions, no VFAT entries, hidden and explicit exclusions at multiple levels.
- Symlinks: regular targets, chains, external targets, distinct copied names, disabled policy, directory links, dangling/circular links and special targets.
- Label derivation, invalid basename, explicit no-label and path defaulting.
- Safety: disk full, unreadable source, missing mtools, subprocess failure, existing destination, failed forced replacement, temporary cleanup, invalid image, safe extraction and mutation rollback.
- Reproducible mode: repeated build equality when supported; otherwise document discrepancies.

Use mtools for interoperability checks and optional `fsck.fat` or another independent reader for filesystem consistency. Validate representative images in DOSBox-X/86Box and on actual machines (`phaistos` NuXT with Gotek/FlashFloppy and `miles` IBM PS/2), including 360K, 720K and 1.44M where hardware permits. Treat 2.88M hardware reliability separately from image validity.

## 12. Implementation milestones

1. **Core creation:** registry, configuration, manifest, strict validation, automatic selection, transactional mtools creation, public API and create/formats/help CLI.
2. **Read and inspect:** info, ls, extract, validate, completions, complete CLI/API documentation and independent compatibility testing. Milestones 1–2 constitute the intended initial usable release. **Status:** milestones 1 and 2 are implemented except testing on emulators and physical hardware.
3. **Mutation:** add, rm, mkdir, transactional updates and DOS attributes as needed.
4. **Boot support:** boot code/sector operations and later DOS system installation; investigate GR-DOS integration.
5. **Further enhancements:** multi-image packing, additional encodings/geometries or native backends only when justified.

Reproducible build support should be developed alongside creation and verified before advertising a reproducibility guarantee.

## 13. Implementation decisions still to verify

The overall architecture and user-facing defaults are settled. Resolved during the initial implementation (see the sections above): TOML parser selection, FAT12 layouts produced by mtools for every preset, accepted DOS punctuation, timestamp handling, backend verification (native reader), exclusion matcher details and reproducibility controls. Still open: exact mutation API signatures and options (milestone 3); boot-capable images for DOS versions without conventional BPBs (160K/320K); emulator and physical hardware compatibility testing, which has not yet been performed. Images have been checked with mtools and `fsck.fat` only.
