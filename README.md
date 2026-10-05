# mac-integrity

`mac-integrity` is a small, declarative file-integrity monitoring tool for macOS.

It lets you define important filesystem objects in a simple `manifest`, capture their trusted state, and later verify that they have not changed.

It can monitor regular files, directories, symbolic links, and paths that are expected not to exist. Depending on the object type, it verifies file contents, ownership, group, permissions, and symbolic-link targets.

The tool consists of two scripts:

- `update.zsh` captures the current filesystem state as the trusted baseline.
- `verify.zsh` compares the current filesystem against that baseline.

Git is optional, but recommended for reviewing baseline changes and maintaining a history of trusted states.

For details about the architecture, trust model, file formats, and design decisions, see [`DESIGN.md`](DESIGN.md).

## Usage

### 1. Define what to monitor

Edit `manifest` and add the filesystem objects you want to monitor:

```text
# Zsh system configuration

file /etc/zshrc
file /etc/zprofile
file /etc/zlogin
absent /etc/zshenv

# Other examples

directory /Library/Application Support/Example
symlink /usr/local/bin/example
```

The supported entry types are:

| Type | Expected state |
| --- | --- |
| `file` | Regular file. Contents, owner, group, and permissions are verified. |
| `directory` | Directory. Owner, group, and permissions are verified. |
| `symlink` | Symbolic link. Owner, group, and link target are verified. |
| `absent` | Nothing should exist at this path. |

Paths must be absolute. Spaces in paths are supported without quoting.

### 2. Create the trusted baseline

Once the system is in a state you trust, run:

```zsh
./update.zsh
```

This generates `baseline/`, containing copies of monitored files and their expected metadata.

> **Warning:** `baseline/` contains copies of monitored files and may therefore contain sensitive or machine-specific information. If you track the baseline with Git, use a **private repository** unless you have verified that all monitored files are safe to publish. Baseline contents also remain in Git history after later removal unless that history is explicitly rewritten.

Running `update.zsh` means that you are explicitly accepting the **current system state as trusted**. It does not determine whether the current state is safe.

If the repository is tracked with Git, review and commit the initial baseline:

```zsh
git add manifest baseline
git commit -m "Create integrity baseline"
```

### 3. Verify the system

Run:

```zsh
./verify.zsh
```

A successful verification looks like:

```text
[OK]    /etc/zshrc
[OK]    /etc/zprofile
[OK]    /etc/zlogin
[OK]    /etc/zshenv

Integrity verification successful.
```

If something has changed:

```text
[FAIL]  /etc/zshrc
        contents differ
        mode: expected 0444, actual 0644

Integrity verification failed: 1 violation(s).
```

`verify.zsh` is strictly read-only. It never modifies the baseline or the monitored filesystem.

### 4. Accept legitimate changes

If `verify.zsh` detects a change, investigate it first.

If the change is legitimate and should become the new trusted state:

```zsh
./update.zsh
```

When using Git, review exactly what changed:

```zsh
git diff -- baseline/
git status
```

Then commit the new baseline only after reviewing it:

```zsh
git add manifest baseline
git commit -m "Update integrity baseline"
```

The normal workflow is therefore:

```text
verify → investigate → update → review → commit
```

## Exit Codes

`verify.zsh` returns:

| Code | Meaning |
| ---: | --- |
| `0` | Integrity verification succeeded |
| `1` | One or more integrity violations were detected |
| `2` | Verification could not be completed reliably |

Exit code `2` is used for problems such as invalid or incomplete baseline data. An inability to verify is never treated as a successful verification.

## Requirements

- macOS
- Zsh
- Standard macOS command-line utilities

No additional dependencies are required.

Git is optional and is not required for baseline creation or verification.

## Security

`mac-integrity` detects changes relative to a baseline that **you previously chose to trust**. It is not an antivirus or malware scanner and does not determine whether file contents are malicious.

Be careful when monitoring files containing secrets: regular files are copied into `baseline/` and may therefore also enter Git history or be uploaded to a configured remote repository. A private repository is recommended when Git is used to maintain baseline history.

For the complete security model and implementation design, see [`DESIGN.md`](DESIGN.md).
