# mac-integrity — Design and Architecture

## 1. Overview

`mac-integrity` is a small, declarative file-integrity monitoring utility designed specifically for macOS.

Its purpose is to answer a narrowly defined question:

> Does the current state of a selected set of filesystem objects match a state that was previously and explicitly accepted as trusted?

The project intentionally separates three concepts:

1. **Policy** — what filesystem objects should be monitored.
2. **Trusted state** — what those objects are expected to look like.
3. **Verification** — whether the current system matches that trusted state.

These concepts map directly to the repository:

```text id="hn4x9r"
mac-integrity/
├── manifest
├── update.zsh
├── verify.zsh
└── baseline/
    ├── metadata
    ├── etc/
    │   ├── zshrc
    │   ├── zprofile
    │   └── zlogin
    └── ...
```

The responsibilities are:

```text id="3yvrfq"
manifest
    Defines what should be monitored.

update.zsh
    Captures the current filesystem state as trusted.

baseline/
    Stores the trusted state.

verify.zsh
    Compares the current filesystem against the trusted state.
```

Git is intentionally outside the integrity engine itself.

The repository is designed to work particularly well with Git, because version control provides useful history, review, and rollback capabilities, but neither baseline creation nor verification fundamentally depends on Git.

The resulting design can be summarized as:

> Git-friendly, not Git-dependent.

---

# 2. Motivation

macOS contains a number of system-wide configuration locations where relatively small filesystem changes can have significant effects.

Shell startup files are a useful example.

Zsh may read system-wide configuration files under `/etc`, including files such as:

```text id="4n89xa"
/etc/zshenv
/etc/zprofile
/etc/zshrc
/etc/zlogin
```

Some of these files may rarely change on a particular machine. Some may normally not exist at all.

The unexpected creation or modification of such a file can therefore be significant.

For example, a policy might state:

```text id="ph0xw4"
file /etc/zshrc
file /etc/zprofile
file /etc/zlogin
absent /etc/zshenv
```

This expresses two different kinds of trusted state:

```text id="q0dsz3"
/etc/zshrc       should exist and remain unchanged
/etc/zprofile    should exist and remain unchanged
/etc/zlogin      should exist and remain unchanged
/etc/zshenv      should not exist
```

The same mechanism can be used for other security-sensitive or operationally important files and directories.

The project is not intended to automatically determine which paths are important. That decision belongs to the user and is expressed explicitly through the manifest.

---

# 3. Design Goals

The project is deliberately small.

The primary design goals are:

## 3.1 Explicitness

The monitored filesystem state must be clearly declared.

There should be no hidden directory scanning or implicit discovery of additional files.

If a filesystem object is monitored, it should be possible to determine why by reading the manifest.

## 3.2 Determinism

Given:

- the same manifest, and
- the same filesystem state,

running `update.zsh` should produce the same logical baseline.

Generated timestamps or other volatile information are intentionally avoided.

This is especially important when Git is used because regenerating an unchanged baseline should ideally produce no meaningful diff.

## 3.3 Read-only verification

`verify.zsh` must be strictly observational.

Verification must never:

- modify the manifest,
- modify the baseline,
- modify monitored filesystem objects,
- repair files,
- accept changes,
- invoke `update.zsh`,
- modify Git state.

This is a fundamental project invariant.

Verification answers a question. It does not take corrective action.

## 3.4 Explicit trust changes

The trusted state must only change through an explicit action.

Running:

```zsh id="fh9xg5"
./update.zsh
```

means:

> Capture the current system state and accept it as the new trusted baseline.

The update operation does not attempt to determine whether the current state is safe.

Trust is a user decision.

## 3.5 Fail closed

If a monitored object cannot be verified reliably, it must not be silently treated as valid.

For example:

- missing metadata,
- malformed metadata,
- an unreadable monitored file,
- missing baseline contents,
- inconsistent manifest and baseline information,

must result in a verification error.

The guiding rule is:

> Unable to verify is not equivalent to verified.

## 3.6 Minimal privilege

Neither script automatically invokes `sudo`.

The scripts operate using the privileges of the invoking user.

If those privileges are insufficient to capture or verify a filesystem object, the operation fails rather than automatically escalating privileges.

## 3.7 Small, auditable implementation

The scripts should remain understandable enough that their behavior can be audited directly.

This favors:

- simple text formats,
- standard macOS utilities,
- straightforward shell code,
- minimal dependencies,
- deliberately limited feature scope.

Complexity should only be introduced when it provides a meaningful integrity benefit.

---

# 4. Non-Goals

`mac-integrity` is not intended to be:

- an antivirus,
- an endpoint detection platform,
- a malware scanner,
- a filesystem repair utility,
- a configuration-management system,
- a backup system,
- a secrets manager,
- a general-purpose cross-platform integrity framework.

It does not determine whether file contents are malicious.

It determines whether filesystem state has changed relative to a previously trusted baseline.

The distinction is important.

A malicious file that is deliberately captured into the baseline becomes trusted from the perspective of `mac-integrity`.

---

# 5. Trust Model

The central trust operation is baseline creation.

The workflow is conceptually:

```text id="2jj9fr"
Current system
      │
      │ user decides state is trusted
      ▼
  update.zsh
      │
      ▼
   baseline
```

Later:

```text id="7lfh6n"
Current system ──────┐
                     │
                     ▼
                  verify.zsh
                     ▲
                     │
Trusted baseline ────┘
```

Verification compares the two states.

If they differ, `verify.zsh` reports the difference.

It does not decide whether the difference is legitimate.

The expected operational workflow after the initial baseline is:

```text id="w6yxgc"
System changes
      │
      ▼
   verify
      │
      ▼
Differences?
   │       │
   no      yes
   │       │
   ▼       ▼
 done   investigate
           │
           ▼
      legitimate?
       │       │
       no      yes
       │       │
       ▼       ▼
    respond   update
                 │
                 ▼
              review
                 │
                 ▼
              commit
```

This separation is intentional.

`verify.zsh` discovers drift.

The user determines whether that drift is acceptable.

`update.zsh` records the user's decision to accept the current state.

---

# 6. Policy: The Manifest

The manifest is the authoritative declaration of what should be monitored.

It is user-authored.

The baseline, by contrast, is generated.

This distinction is important:

```text id="03oqtf"
manifest     = desired monitoring policy
baseline/    = generated trusted state
```

The v1 manifest grammar is deliberately simple.

Each meaningful line has the form:

```text id="72uh3h"
TYPE ABSOLUTE_PATH
```

Blank lines are ignored.

Lines whose trimmed form begins with `#` are comments.

For example:

```text id="6qff4p"
# ========================================
# Zsh
# ========================================

file /etc/zshrc
file /etc/zprofile
file /etc/zlogin
absent /etc/zshenv

# ========================================
# Example application
# ========================================

file /Library/Preferences/example.conf
directory /Library/Application Support/Example
symlink /usr/local/bin/example
```

The first whitespace-separated token is the entry type.

Everything after the first separator is the path.

Consequently:

```text id="i1lixg"
directory /Library/Application Support/Example
```

means:

```text id="0ib2vz"
type = directory
path = /Library/Application Support/Example
```

Spaces inside paths therefore require no quoting.

---

# 7. Manifest Path Rules

Manifest paths must be absolute.

For example:

```text id="tx78cp"
file /etc/zshrc
```

is valid.

A relative path such as:

```text id="wjau8k"
file etc/zshrc
```

is invalid.

## 7.1 Tabs and newlines

Tabs and newlines are deliberately unsupported inside paths.

This restriction exists primarily because generated metadata uses tabs as field delimiters.

Rejecting tabs gives the metadata format an important invariant:

```text id="13mqz4"
TAB = field separator
SPACE = ordinary path character
```

No quoting or escaping layer is therefore required.

## 7.2 `.` and `..`

Explicit `.` and `..` path components are rejected.

For example:

```text id="d8jfc0"
file /etc/../etc/zshrc
file /etc/./zshrc
```

are invalid.

The implementation does not silently normalize them.

This keeps path identity straightforward and prevents multiple textual representations of the same intended path.

## 7.3 Duplicate paths

A path may only appear once in the manifest.

For example:

```text id="ymlzyu"
file /etc/zshrc
file /etc/zshrc
```

is invalid.

So is attempting to assign different rules to the same path:

```text id="ry9ojq"
file /etc/example
absent /etc/example
```

Each monitored path has exactly one policy.

---

# 8. Manifest Entry Types

v1 defines four entry types:

```text id="ehw44x"
file
directory
symlink
absent
```

Each type has deliberately specific semantics.

---

# 9. `file`

Example:

```text id="n7q15w"
file /etc/zshrc
```

The path is expected to:

- exist,
- be a regular file,
- not be a symbolic link.

The trusted state consists of:

```text id="5jilj8"
type
contents
owner
group
mode
```

Verification therefore checks all five properties.

A symlink pointing to the expected file does not satisfy a `file` rule.

For example, replacing:

```text id="et72i4"
/etc/zshrc
```

with a symbolic link whose target contains byte-for-byte identical contents is still an integrity violation because the filesystem object type has changed.

This is intentional.

---

# 10. `directory`

Example:

```text id="74wx5s"
directory /Library/Application Support/Example
```

The path is expected to:

- exist,
- be a directory,
- not be a symbolic link.

The trusted state consists of:

```text id="ek0fqx"
type
owner
group
mode
```

Directory contents are not recursively monitored in v1.

This distinction is important.

Declaring:

```text id="p5gbhx"
directory /Library/Application Support/Example
```

means:

> Monitor the directory object itself.

It does **not** mean:

> Monitor everything underneath this directory.

Individual files beneath the directory must be explicitly added to the manifest if their contents should also be monitored.

This behavior avoids hidden expansion of the monitoring scope.

---

# 11. `symlink`

Example:

```text id="5x3i2q"
symlink /usr/local/bin/example
```

The path is expected to be a symbolic link.

The link is inspected as a filesystem object in its own right.

The trusted state consists of:

```text id="f6is2e"
type
owner
group
target
```

The target is recorded using `readlink`.

The target is preserved exactly.

For example:

```text id="d80n6a"
../lib/example
```

remains:

```text id="56wm6g"
../lib/example
```

It is not resolved into an absolute path.

This means changing:

```text id="3i49k6"
../lib/example
```

to:

```text id="53x9ok"
/usr/local/lib/example
```

is detected even if both ultimately resolve to the same filesystem object.

The target itself is not implicitly monitored.

If the target also requires integrity verification, it must have its own manifest entry.

Broken symbolic links are valid symbolic links from the perspective of the `symlink` type.

---

# 12. `absent`

Example:

```text id="nb3t98"
absent /etc/zshenv
```

The expected state is that no filesystem object exists at the path.

This includes:

- regular files,
- directories,
- symbolic links,
- broken symbolic links,
- other filesystem objects.

The implementation therefore cannot rely exclusively on `-e`, because a broken symbolic link may cause `-e` to report false.

The expected test is conceptually:

```zsh id="xzhw75"
[[ -e "$target_path" || -L "$target_path" ]]
```

An `absent` rule requires no generated metadata.

The manifest itself completely describes the expected state:

```text id="ud6hm8"
expected = nothing exists
```

---

# 13. The Baseline

`baseline/` contains generated trusted state.

It should be conceptually possible to delete the entire directory and regenerate it with `update.zsh`.

This is why metadata is stored inside:

```text id="lmkbz7"
baseline/metadata
```

rather than alongside the manifest.

The directory therefore forms one conceptual unit:

```text id="5jpy7g"
baseline/
    trusted contents
    trusted metadata
```

This provides a clean distinction between:

```text id="6gn6f7"
manifest
    user-authored policy

baseline/
    generated trusted state
```

---

# 14. Baseline File Storage

Regular file contents are stored beneath `baseline/` using their absolute filesystem path relative to the baseline root.

For example:

```text id="xwp7tr"
/etc/zshrc
```

is represented as:

```text id="0mpy7j"
baseline/etc/zshrc
```

Similarly:

```text id="k68iue"
/Library/Preferences/example.conf
```

becomes:

```text id="kwr7g7"
baseline/Library/Preferences/example.conf
```

This layout makes baseline contents easy to inspect directly and produces meaningful Git paths.

Directories themselves are not recursively copied.

Symbolic links are represented through metadata rather than by creating equivalent links inside the baseline.

Absent entries require no baseline filesystem object.

---

# 15. Metadata Format

Generated metadata is stored in:

```text id="k8ojve"
baseline/metadata
```

The format is tab-separated values.

Example:

```text id="i0dpbd"
# Generated by mac-integrity update.zsh.
# Do not edit manually.
# Format: tab-separated values (TSV)
#
# type	path	owner	group	mode-or-target
file	/etc/zshrc	root	wheel	0444
file	/etc/zprofile	root	wheel	0444
directory	/Library/Application Support/Apple	root	wheel	0755
symlink	/etc	root	wheel	private/etc
```

The general structure is:

```text id="aqhm85"
type<TAB>path<TAB>owner<TAB>group<TAB>value
```

For files and directories:

```text id="b24r81"
type
path
owner
group
mode
```

For symbolic links:

```text id="d76azq"
type
path
owner
group
target
```

The fifth field therefore has type-dependent semantics.

---

# 16. Why TSV?

TSV was selected because it provides a small and deterministic machine-readable format without requiring a quoting or escaping system.

Because tabs are prohibited inside manifest paths and symlink targets, a tab always has exactly one meaning:

> field separator

Spaces remain ordinary characters.

Therefore:

```text id="03x7hm"
directory	/Library/Application Support/Apple	root	wheel	0755
```

is unambiguously parsed as:

```text id="xkjc9a"
type  = directory
path  = /Library/Application Support/Apple
owner = root
group = wheel
mode  = 0755
```

There is no need for:

- quoted strings,
- quote escaping,
- backslash escaping,
- shell evaluation,
- JSON parsing,
- YAML parsing,
- an INI parser.

This supports the project's goal of keeping the trusted-state format easy to audit and parse.

---

# 17. Mandatory Metadata

Metadata fields are not optional in v1.

For a regular file or directory, verification requires:

```text id="8m4tvp"
owner
group
mode
```

For a symbolic link, verification requires:

```text id="b3a9hd"
owner
group
target
```

If required metadata is missing, verification does not silently skip that property.

Instead, verification fails with an error.

This follows the fail-closed principle:

> A partially described trusted state is not a valid trusted state.

---

# 18. Why Ownership Is Monitored

Permissions alone do not fully describe the security characteristics of a filesystem object.

For example, a file could retain mode:

```text id="rr9y6u"
0644
```

while changing ownership from:

```text id="e2tv3d"
root:wheel
```

to another user.

That ownership change may significantly alter who can modify the file even though its permission bits appear unchanged.

For this reason, v1 always tracks:

```text id="s3p55k"
owner
group
mode
```

as a unit.

There is no v1 configuration option to selectively disable these checks.

---

# 19. `update.zsh`

`update.zsh` generates trusted state.

Its semantics are:

> Capture the current state described by the manifest and make that state the new baseline.

It does not determine whether that state should be trusted.

That distinction is intentionally outside the script.

---

# 20. Update Validation

Before modifying baseline data, `update.zsh` parses and validates the complete manifest.

It also validates that the current filesystem satisfies the structural requirements of each rule.

For example:

```text id="7y16tp"
file
```

must currently refer to a regular readable file.

```text id="6x4k8s"
directory
```

must refer to an actual directory.

```text id="t2ud57"
symlink
```

must refer to a symbolic link.

```text id="d69h0m"
absent
```

must not exist.

An `absent` path that currently exists is not something `update.zsh` is permitted to accept automatically.

Doing so would contradict the policy expressed by the manifest.

The user must first resolve either the filesystem state or the manifest.

---

# 21. Baseline Generation

The new baseline is built separately from the existing baseline.

Conceptually:

```text id="dxr7cy"
manifest
   │
   ▼
validate
   │
   ▼
current filesystem
   │
   ▼
temporary baseline
   │
   ▼
complete?
 │     │
 no    yes
 │      │
 ▼      ▼
abort   replace baseline
```

The existing baseline is not incrementally edited.

This has several useful consequences.

## 21.1 Failed capture does not produce a partial baseline

If capture fails halfway through, the temporary baseline can be discarded.

The existing trusted state remains available.

## 21.2 Removed manifest entries disappear

Suppose the old manifest contains:

```text id="rqfsau"
file /etc/example
```

and the entry is later removed.

Rebuilding the baseline from scratch means:

```text id="rqtbkb"
baseline/etc/example
```

also disappears.

There is no need to implement separate stale-file cleanup logic during ordinary baseline generation.

## 21.3 Baseline exactly follows policy

The generated baseline represents the current manifest rather than the accumulated history of previous manifests.

---

# 22. Baseline Replacement

The temporary baseline is created next to the real baseline directory.

This keeps final renames within the same filesystem and allows the implementation to use filesystem rename operations rather than copying an already-generated baseline into place.

The intended replacement sequence is conceptually:

```text id="7z8ckp"
baseline/
    │
    ▼
temporary old baseline

new temporary baseline
    │
    ▼
baseline/
```

If installation of the new baseline fails, the previous baseline should be restored whenever possible.

The replacement mechanism should continue to be treated as security-sensitive implementation code because losing or partially replacing trusted state would undermine later verification.

---

# 23. No Automatic Privilege Escalation

`update.zsh` does not invoke `sudo`.

For example, a monitored file may be:

```text id="cxnjai"
root:wheel
```

while the baseline copy is owned by the normal user running `mac-integrity`.

This is acceptable.

The authoritative expected ownership is stored explicitly in:

```text id="moxakz"
baseline/metadata
```

The baseline copy exists primarily to preserve trusted file contents.

Its own filesystem ownership is not intended to reproduce the ownership of the monitored object.

---

# 24. `verify.zsh`

`verify.zsh` compares the current filesystem state against:

```text id="55ow7h"
manifest + baseline
```

The manifest determines which paths should be examined.

The baseline provides the expected trusted state for entries requiring stored state.

Verification is strictly read-only.

This is one of the strongest invariants in the project.

---

# 25. File Verification

For a `file` entry, verification checks:

```text id="aw3esg"
expected object type
        +
trusted contents
        +
trusted owner
        +
trusted group
        +
trusted mode
```

Contents are compared directly against the baseline copy.

The implementation uses a byte comparison rather than interpreting the file's format.

This means `mac-integrity` is equally capable of monitoring:

- text files,
- configuration files,
- scripts,
- binary files,

provided they can be read.

No semantic normalization is performed.

Even a content change that is semantically irrelevant to another program remains a content change from the perspective of integrity verification.

---

# 26. Directory Verification

For a `directory` entry, verification checks:

```text id="nnljb1"
expected object type
        +
trusted owner
        +
trusted group
        +
trusted mode
```

The directory's contents are not examined.

This is intentional rather than an implementation limitation accidentally exposed as behavior.

Recursive directory monitoring may be considered separately in a future version.

---

# 27. Symlink Verification

For a `symlink` entry, verification checks the link itself.

It verifies:

```text id="llzy2f"
object is a symlink
owner
group
exact target
```

The link is not followed when determining its ownership.

The target string is compared exactly.

Therefore these can intentionally be considered different:

```text id="4x23ak"
../lib/example
```

and:

```text id="gv0ydc"
/usr/local/lib/example
```

even if both resolve to the same object.

---

# 28. Absence Verification

For an `absent` entry, verification confirms that no object exists at the path.

The check explicitly accounts for broken symbolic links.

If anything exists at the path, the rule fails.

There is no corresponding metadata entry.

If metadata unexpectedly exists for a path declared `absent`, the baseline is inconsistent and verification reports an error.

---

# 29. Integrity Violations vs. Verification Errors

`verify.zsh` distinguishes two fundamentally different failure categories.

## 29.1 Integrity violation

An integrity violation means:

> The trusted state is sufficiently defined, verification was possible, and the current system does not match it.

Examples include:

```text id="p1z3i3"
file contents changed
owner changed
group changed
mode changed
expected file disappeared
file became a symlink
symlink target changed
an absent path appeared
```

These produce exit status:

```text id="m8ufx2"
1
```

## 29.2 Verification error

A verification error means:

> The program cannot reliably determine whether the current system matches the trusted state.

Examples include:

```text id="g04tse"
manifest is invalid
metadata is malformed
metadata is missing
baseline file is missing
manifest and metadata disagree
monitored file cannot be read
unexpected metadata exists
```

These produce exit status:

```text id="r73ud7"
2
```

This distinction is important for automation.

An integrity violation means:

> Something changed.

A verification error means:

> The integrity result cannot be trusted.

---

# 30. Exit Status Contract

`verify.zsh` defines the following public exit-status contract:

```text id="yqk1km"
0    verified successfully
1    integrity violation detected
2    verification could not be completed reliably
```

This contract is intended to remain stable.

It allows callers to distinguish:

```text id="frs0rk"
safe according to baseline
changed according to baseline
unknown / unable to verify
```

The third state is deliberately separate from both success and detected drift.

---

# 31. Reporting Multiple Differences

Verification attempts to report useful information rather than stopping at the first ordinary integrity violation.

For example, one file may simultaneously have:

```text id="azcq18"
different contents
different owner
different mode
```

The output can report all three:

```text id="e4dnug"
[FAIL]  /etc/zshrc
        contents differ
        owner: expected root, actual example
        mode: expected 0444, actual 0644
```

However, this represents one affected manifest object.

The summary therefore counts it as one integrity violation rather than three.

This makes violation counts correspond to filesystem objects requiring investigation.

---

# 32. Baseline Consistency Checks

Verification does not blindly assume that baseline data is valid.

The metadata is itself validated before being trusted.

Checks include:

- known metadata types,
- required fields,
- valid paths,
- duplicate metadata paths,
- valid mode representation,
- agreement between manifest type and metadata type,
- presence of required baseline file contents,
- absence of metadata for `absent` rules,
- detection of metadata entries with no corresponding manifest rule.

A malformed baseline results in verification error status rather than an integrity violation.

The distinction matters because a damaged baseline cannot reliably describe expected state.

---

# 33. Git Integration Philosophy

Git is deliberately not part of the integrity algorithm.

The core relationship is:

```text id="5xkxij"
manifest + baseline + filesystem
              │
              ▼
          verification
```

not:

```text id="yqplbx"
Git repository + filesystem
              │
              ▼
          verification
```

This means the project can operate:

- from a Git clone,
- from an extracted archive,
- from an arbitrary directory,
- without Git installed.

Nevertheless, Git complements the design extremely well.

---

# 34. Git as a Trust-History Layer

When the repository is version-controlled, Git provides:

- history of baseline changes,
- review before accepting changes,
- rollback,
- visibility into added and deleted baseline files,
- synchronization with another machine or remote repository.

A typical trusted-state transition becomes:

```text id="65ovr9"
filesystem change
       │
       ▼
    verify
       │
       ▼
 investigate
       │
       ▼
     update
       │
       ▼
    git diff
       │
       ▼
     review
       │
       ▼
   git commit
```

This gives `update.zsh` and Git distinct roles:

```text id="36ux9p"
update.zsh
    Generates proposed trusted state.

git diff
    Shows how proposed trusted state differs.

git commit
    Records deliberate acceptance of that state.
```

The scripts do not automatically commit or push baseline changes.

---

# 35. Why Git Is Not Invoked Automatically

Automatically committing baseline changes would blur an important trust boundary.

A baseline update should remain inspectable before becoming part of long-term trusted history.

Therefore the intended sequence is:

```zsh id="1kjznw"
./update.zsh
git diff -- baseline/
git status
```

followed by an explicit commit only after review.

`update.zsh` may provide a helpful suggestion to run Git commands when it detects that it resides inside a Git work tree, but Git is not required for successful baseline generation.

---

# 36. Deterministic Baselines and Git

Generated timestamps are deliberately excluded from metadata.

For example, metadata does not contain:

```text id="aix3ny"
baseline-generated-at=2026-10-05T12:34:56
```

Such information would cause every baseline regeneration to produce a change even when the trusted filesystem state remained identical.

The desired property is:

```text id="4wvwyx"
unchanged manifest
        +
unchanged filesystem
        +
update.zsh
        =
no meaningful Git diff
```

This makes Git changes correspond more closely to actual trusted-state changes.

---

# 37. Repository Location Independence

The scripts derive repository paths from their own location rather than from the caller's current working directory.

Conceptually:

```zsh id="pbmq76"
SCRIPT_DIR="${0:A:h}"
```

This means the utility can be invoked from another directory without changing its behavior.

For example:

```text id="fl9a9b"
/Users/example/tools/mac-integrity/verify.zsh
```

should use:

```text id="5ynm3j"
/Users/example/tools/mac-integrity/manifest
/Users/example/tools/mac-integrity/baseline/
```

regardless of the shell's current directory.

---

# 38. macOS-Specific Behavior

v1 is intentionally macOS-specific.

The implementation relies on macOS/BSD utility behavior, particularly `stat`.

For example, macOS `stat` can retrieve symbolic ownership information using formats such as:

```zsh id="j93jkw"
stat -f '%Su' "$target_path"
stat -f '%Sg' "$target_path"
stat -f '%Lp' "$target_path"
```

For symbolic links, macOS `stat` examines the link itself by default.

Using:

```text id="6q54n4"
-L
```

would instead follow the link.

This behavior is intentionally accounted for when verifying symlink ownership.

The project does not currently attempt to abstract these differences for GNU/Linux or other operating systems.

---

# 39. Shell Implementation Considerations

The implementation uses Zsh.

Some names have special meanings in Zsh and must therefore be avoided for ordinary scalar variables.

One particularly important example is:

```text id="d6kj8u"
path
```

In Zsh, `$path` is a special array tied to `$PATH`.

Assigning:

```zsh id="3e1v40"
path="/etc/zshrc"
```

can therefore overwrite the shell's command search path and cause unrelated commands to become unavailable.

The scripts consequently use:

```text id="smdb4c"
target_path
```

for filesystem paths.

This is an implementation detail, but it is important for future maintenance because accidentally introducing special Zsh variable names can produce surprising and security-relevant behavior.

---

# 40. Baseline Confidentiality

Baseline file copies contain the complete contents of monitored regular files.

Therefore adding:

```text id="f1m82v"
file /some/secret/file
```

also causes those contents to exist beneath:

```text id="f33dx4"
baseline/
```

If Git is used, those contents may also enter Git history.

If a remote repository is configured, they may be uploaded there.

For this reason, users must consider the confidentiality of monitored files.

A private Git repository provides access control, but should not automatically be treated as a secrets vault.

Files containing items such as:

- private keys,
- passwords,
- authentication tokens,
- API credentials,
- confidential application configuration,

require additional consideration before being added to the manifest.

---

# 41. Security Limitations

`mac-integrity` provides change detection relative to stored trusted state.

It does not establish an independent root of trust.

An attacker with sufficient access may potentially modify:

```text id="mqtmrz"
monitored files
manifest
baseline
scripts
Git repository
```

If all relevant trusted state is stored exclusively on the same compromised machine, local verification alone cannot prove that the baseline itself was not altered.

Git can improve recoverability and auditability, particularly when history also exists on a remote system, but this is not equivalent to cryptographically protected remote attestation.

The project should therefore be understood as a practical local integrity-monitoring tool rather than a complete defense against an attacker with unrestricted control of the machine.

---

# 42. Deliberately Limited v1 Scope

v1 intentionally supports only four policy types:

```text id="n4at3g"
file
directory
symlink
absent
```

The trusted properties are:

```text id="1gfw30"
file:
    contents
    owner
    group
    mode
    type

directory:
    owner
    group
    mode
    type

symlink:
    owner
    group
    target
    type

absent:
    nonexistence
```

The design deliberately does not attempt to capture every macOS filesystem property.

---

# 43. Features Outside v1

Possible future capabilities include:

- recursive directory monitoring,
- extended attribute verification,
- ACL verification,
- BSD file flag verification,
- code-signing verification,
- configurable hashing,
- reporting modes intended for automation,
- richer baseline authentication,
- additional filesystem object types.

These should not be added merely because they are possible.

Each feature should be evaluated against the project's original goals:

```text id="ggd5dz"
Does it improve meaningful integrity detection?

Can its semantics be clearly defined?

Can failure be handled safely?

Does it preserve understandable trusted state?

Does it keep verification auditable?
```

A smaller integrity model that can be understood completely is preferable to a feature-rich model whose trust semantics are unclear.

---

# 44. Recursive Monitoring

Directory recursion is deliberately excluded from v1.

If introduced later, its semantics require careful design.

Questions include:

- Are newly created files automatically considered violations?
- Are deleted files violations?
- Are symlinks followed?
- Are mount points crossed?
- How are excluded paths represented?
- How are permissions stored for every child?
- What happens with transient files?
- How are very large directory trees handled?
- Does manifest expansion occur during update or verification?

Until those questions have explicit answers, `directory` continues to mean only:

> Monitor this directory object itself.

---

# 45. Extended Attributes and ACLs

macOS supports security-relevant filesystem information beyond traditional Unix ownership and permission bits.

Examples include:

- extended attributes,
- access control lists,
- BSD flags.

These may eventually be useful integrity properties.

They are excluded from v1 to keep the trusted-state representation and verification rules simple.

Their absence should therefore be understood as a known scope boundary rather than an assumption that these properties can never affect security.

---

# 46. Baseline Authentication

The current design assumes that `baseline/` is the trusted reference supplied to `verify.zsh`.

A future version could potentially add mechanisms for authenticating baseline state independently, such as cryptographic signatures or externally stored hashes.

Such a feature would materially change the trust model and should therefore be designed explicitly rather than added as a small implementation detail.

---

# 47. Project Invariants

The following rules summarize the most important design invariants.

### Manifest

```text id="8b6bxu"
The manifest is user-authored policy.

Every monitored path is explicit.

Every path is absolute.

A path has exactly one rule.
```

### Baseline

```text id="t2ddjz"
The baseline is generated trusted state.

baseline/metadata belongs to the baseline.

Required metadata is never optional.

An unchanged system should produce an unchanged logical baseline.
```

### Update

```text id="k6v7x4"
update.zsh means "trust the current state."

It does not decide whether that state is safe.

It never silently changes manifest policy.

It does not automatically escalate privileges.

It builds a complete replacement baseline rather than incrementally
accepting individual changes.
```

### Verification

```text id="6qeqdr"
verify.zsh is read-only.

It never accepts changes.

It never repairs files.

It never modifies trusted state.

Unable to verify is an error, not success.
```

### Git

```text id="sgv32a"
Git is optional.

Git history is not part of the core verification algorithm.

Commits and pushes are always explicit user actions.
```

---

# 48. Design Philosophy

The project intentionally avoids trying to make trust automatic.

There are three distinct questions:

```text id="49ek4n"
What should I monitor?

What state do I trust?

Does the machine still match that state?
```

`mac-integrity` assigns each question to a separate mechanism:

```text id="2fnm8s"
manifest
    What should I monitor?

update.zsh
    What state do I trust?

verify.zsh
    Does the machine still match that state?
```

Git can then provide a fourth layer:

```text id="4tzk2d"
Git
    How has my trusted state changed over time?
```

Keeping those responsibilities separate is the central architectural idea behind the project.

The project favors explicit policy, deterministic state, strict verification, minimal privilege, and human review over automatic remediation or automatic trust decisions.

The intended result is not a comprehensive endpoint-security system.

It is a small tool whose answer to a narrow question can be understood and trusted:

> These are the filesystem objects I chose to monitor. This is the state I explicitly accepted. Does my Mac still match it?
