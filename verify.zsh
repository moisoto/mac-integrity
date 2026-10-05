#!/bin/zsh

setopt ERR_EXIT
setopt NO_UNSET
setopt PIPE_FAIL

readonly SCRIPT_DIR="${0:A:h}"
readonly MANIFEST="${SCRIPT_DIR}/manifest"
readonly BASELINE="${SCRIPT_DIR}/baseline"
readonly METADATA="${BASELINE}/metadata"

typeset -a ENTRIES
typeset -A SEEN_PATHS

typeset -A META_TYPE
typeset -A META_OWNER
typeset -A META_GROUP
typeset -A META_VALUE

typeset -i VIOLATIONS=0
typeset -i ERRORS=0

error() {
    print -u2 -- "[ERROR] $*"
}

die() {
    error "$@"
    exit 2
}

violation() {
    (( VIOLATIONS++ ))
}

verification_error() {
    (( ERRORS++ ))
}

# ---------------------------------------------------------------------------
# Basic baseline validation
# ---------------------------------------------------------------------------

[[ -f "$MANIFEST" ]] ||
    die "Manifest not found: $MANIFEST"

[[ -d "$BASELINE" && ! -L "$BASELINE" ]] ||
    die "Baseline directory not found or is not a directory: $BASELINE"

[[ -f "$METADATA" && ! -L "$METADATA" ]] ||
    die "Baseline metadata not found or is not a regular file: $METADATA"

# ---------------------------------------------------------------------------
# Manifest parsing
# ---------------------------------------------------------------------------

while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [[ -z "$trimmed" ]] && continue
    [[ "$trimmed" == \#* ]] && continue

    if [[ "$trimmed" != *[[:space:]]* ]]; then
        die "Malformed manifest entry: $line"
    fi

    type="${trimmed%%[[:space:]]*}"
    target_path="${trimmed#"$type"}"

    target_path="${target_path#"${target_path%%[![:space:]]*}"}"
    target_path="${target_path%"${target_path##*[![:space:]]}"}"

    case "$type" in
        file|directory|symlink|absent)
            ;;
        *)
            die "Unknown manifest type '$type': $line"
            ;;
    esac

    [[ -n "$target_path" ]] ||
        die "Missing path for '$type' entry"

    [[ "$target_path" == /* ]] ||
        die "Path must be absolute: $target_path"

    [[ "$target_path" != *$'\t'* ]] ||
        die "Path contains a tab: $target_path"

    [[ "$target_path" != *$'\n'* ]] ||
        die "Path contains a newline"

    if [[ "/$target_path/" == *"/../"* || "/$target_path/" == *"/./"* ]]; then
        die "Path contains '.' or '..' components: $target_path"
    fi

    if (( ${+SEEN_PATHS[$target_path]} )); then
        die "Duplicate manifest path: $target_path"
    fi

    SEEN_PATHS[$target_path]=1
    ENTRIES+=("${type}"$'\t'"${target_path}")
done < "$MANIFEST"

# ---------------------------------------------------------------------------
# Metadata parsing
#
# Format:
#
# type<TAB>path<TAB>owner<TAB>group<TAB>mode-or-target
#
# Paths and symlink targets containing tabs/newlines are unsupported.
# ---------------------------------------------------------------------------

typeset -A SEEN_METADATA

while IFS=$'\t' read -r meta_type meta_path meta_owner meta_group meta_value extra ||
      [[ -n "${meta_type:-}" ]]; do

    # Ignore blank lines and comments.
    [[ -z "${meta_type:-}" ]] && continue
    [[ "$meta_type" == \#* ]] && continue

    case "$meta_type" in
        file|directory|symlink)
            ;;
        *)
            die "Unknown metadata type '$meta_type'"
            ;;
    esac

    [[ -n "${meta_path:-}" ]] ||
        die "Metadata entry is missing path"

    [[ -n "${meta_owner:-}" ]] ||
        die "Metadata entry is missing owner: $meta_path"

    [[ -n "${meta_group:-}" ]] ||
        die "Metadata entry is missing group: $meta_path"

    [[ -n "${meta_value:-}" ]] ||
        die "Metadata entry is missing mode/target: $meta_path"

    # A sixth field means the TSV structure is malformed.
    [[ -z "${extra:-}" ]] ||
        die "Metadata entry contains too many fields: $meta_path"

    [[ "$meta_path" == /* ]] ||
        die "Metadata path must be absolute: $meta_path"

    if (( ${+SEEN_METADATA[$meta_path]} )); then
        die "Duplicate metadata path: $meta_path"
    fi

    case "$meta_type" in
        file|directory)
            [[ "$meta_value" == <-> ]] ||
                die "Invalid mode in metadata for $meta_path: $meta_value"

            [[ ${#meta_value} -eq 4 ]] ||
                die "Invalid mode in metadata for $meta_path: $meta_value"
            ;;

        symlink)
            [[ "$meta_value" != *$'\t'* && "$meta_value" != *$'\n'* ]] ||
                die "Invalid symlink target in metadata: $meta_path"
            ;;
    esac

    SEEN_METADATA[$meta_path]=1
    META_TYPE[$meta_path]="$meta_type"
    META_OWNER[$meta_path]="$meta_owner"
    META_GROUP[$meta_path]="$meta_group"
    META_VALUE[$meta_path]="$meta_value"

done < "$METADATA"

# ---------------------------------------------------------------------------
# Verify each manifest entry
# ---------------------------------------------------------------------------

for entry in "${ENTRIES[@]}"; do
    type="${entry%%$'\t'*}"
    target_path="${entry#*$'\t'}"

    # -----------------------------------------------------------------------
    # absent
    #
    # No metadata is expected for an absent entry.
    # -----------------------------------------------------------------------

    if [[ "$type" == "absent" ]]; then
        if (( ${+SEEN_METADATA[$target_path]} )); then
            print -- "[ERROR] $target_path"
            print -- "        Baseline contains metadata for a path marked absent."
            verification_error
            continue
        fi

        if [[ -e "$target_path" || -L "$target_path" ]]; then
            print -- "[FAIL]  $target_path"
            print -- "        expected: absent"

            if [[ -L "$target_path" ]]; then
                print -- "        actual:   symlink"
            elif [[ -f "$target_path" ]]; then
                print -- "        actual:   regular file"
            elif [[ -d "$target_path" ]]; then
                print -- "        actual:   directory"
            else
                print -- "        actual:   filesystem object"
            fi

            violation
        else
            printf '[OK]    %s\n' "$target_path"
        fi

        continue
    fi

    # -----------------------------------------------------------------------
    # All other types require metadata.
    # -----------------------------------------------------------------------

    if (( ! ${+SEEN_METADATA[$target_path]} )); then
        print -- "[ERROR] $target_path"
        print -- "        Baseline metadata is missing."
        verification_error
        continue
    fi

    if [[ "${META_TYPE[$target_path]}" != "$type" ]]; then
        print -- "[ERROR] $target_path"
        print -- "        Manifest type: ${type}"
        print -- "        Metadata type: ${META_TYPE[$target_path]}"
        verification_error
        continue
    fi

    expected_owner="${META_OWNER[$target_path]}"
    expected_group="${META_GROUP[$target_path]}"
    expected_value="${META_VALUE[$target_path]}"

    typeset -i item_failed=0

    case "$type" in
        # -------------------------------------------------------------------
        # Regular file
        # -------------------------------------------------------------------

        file)
            baseline_file="${BASELINE}${target_path}"

            if [[ ! -e "$baseline_file" || -L "$baseline_file" || ! -f "$baseline_file" ]]; then
                print -- "[ERROR] $target_path"
                print -- "        Baseline file is missing or is not a regular file:"
                print -- "        $baseline_file"
                verification_error
                continue
            fi

            if [[ -L "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: regular file"
                print -- "        actual type:   symlink"
                violation
                continue
            elif [[ ! -e "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: regular file"
                print -- "        actual:        missing"
                violation
                continue
            elif [[ ! -f "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: regular file"
                print -- "        actual type:   other filesystem object"
                violation
                continue
            elif [[ ! -r "$target_path" ]]; then
                print -- "[ERROR] $target_path"
                print -- "        File exists but cannot be read."
                verification_error
                continue
            fi

            actual_owner="$(stat -f '%Su' -- "$target_path")"
            actual_group="$(stat -f '%Sg' -- "$target_path")"
            actual_mode="$(stat -f '%Lp' -- "$target_path")"
            printf -v actual_mode '%04d' "$actual_mode"

            if ! cmp -s -- "$baseline_file" "$target_path"; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        contents differ"
            fi

            if [[ "$actual_owner" != "$expected_owner" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        owner: expected $expected_owner, actual $actual_owner"
            fi

            if [[ "$actual_group" != "$expected_group" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        group: expected $expected_group, actual $actual_group"
            fi

            if [[ "$actual_mode" != "$expected_value" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        mode: expected $expected_value, actual $actual_mode"
            fi

            if (( item_failed )); then
                violation
            else
                printf '[OK]    %s\n' "$target_path"
            fi
            ;;

        # -------------------------------------------------------------------
        # Directory
        # -------------------------------------------------------------------

        directory)
            if [[ -L "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: directory"
                print -- "        actual type:   symlink"
                violation
                continue
            elif [[ ! -e "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: directory"
                print -- "        actual:        missing"
                violation
                continue
            elif [[ ! -d "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: directory"
                print -- "        actual type:   other filesystem object"
                violation
                continue
            fi

            actual_owner="$(stat -f '%Su' -- "$target_path")"
            actual_group="$(stat -f '%Sg' -- "$target_path")"
            actual_mode="$(stat -f '%Lp' -- "$target_path")"
            printf -v actual_mode '%04d' "$actual_mode"

            if [[ "$actual_owner" != "$expected_owner" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        owner: expected $expected_owner, actual $actual_owner"
            fi

            if [[ "$actual_group" != "$expected_group" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        group: expected $expected_group, actual $actual_group"
            fi

            if [[ "$actual_mode" != "$expected_value" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        mode: expected $expected_value, actual $actual_mode"
            fi

            if (( item_failed )); then
                violation
            else
                printf '[OK]    %s\n' "$target_path"
            fi
            ;;

        # -------------------------------------------------------------------
        # Symbolic link
        # -------------------------------------------------------------------

        symlink)
            if [[ ! -L "$target_path" ]]; then
                print -- "[FAIL]  $target_path"
                print -- "        expected type: symlink"

                if [[ ! -e "$target_path" ]]; then
                    print -- "        actual:        missing"
                elif [[ -f "$target_path" ]]; then
                    print -- "        actual type:   regular file"
                elif [[ -d "$target_path" ]]; then
                    print -- "        actual type:   directory"
                else
                    print -- "        actual type:   other filesystem object"
                fi

                violation
                continue
            fi

            # macOS stat inspects the symlink itself by default.
            actual_owner="$(stat -f '%Su' -- "$target_path")"
            actual_group="$(stat -f '%Sg' -- "$target_path")"
            actual_target="$(readlink -- "$target_path")"

            if [[ "$actual_owner" != "$expected_owner" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        owner: expected $expected_owner, actual $actual_owner"
            fi

            if [[ "$actual_group" != "$expected_group" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        group: expected $expected_group, actual $actual_group"
            fi

            if [[ "$actual_target" != "$expected_value" ]]; then
                if (( ! item_failed )); then
                    print -- "[FAIL]  $target_path"
                    item_failed=1
                fi

                print -- "        target: expected $expected_value"
                print -- "        target: actual   $actual_target"
            fi

            if (( item_failed )); then
                violation
            else
                printf '[OK]    %s\n' "$target_path"
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect stale/unexpected metadata
#
# Every metadata entry must correspond to a non-absent manifest entry.
# ---------------------------------------------------------------------------

for meta_path in ${(k)SEEN_METADATA}; do
    if (( ! ${+SEEN_PATHS[$meta_path]} )); then
        print -- "[ERROR] $meta_path"
        print -- "        Metadata exists for a path not present in the manifest."
        verification_error
    fi
done

# ---------------------------------------------------------------------------
# Summary / exit status
# ---------------------------------------------------------------------------

print

if (( ERRORS > 0 )); then
    if (( VIOLATIONS > 0 )); then
        print -- "Verification incomplete: ${ERRORS} baseline error(s), ${VIOLATIONS} integrity violation(s)."
    else
        print -- "Verification incomplete: ${ERRORS} baseline error(s)."
    fi

    exit 2
fi

if (( VIOLATIONS > 0 )); then
    print -- "Integrity verification failed: ${VIOLATIONS} violation(s)."
    exit 1
fi

print -- "Integrity verification successful."
exit 0
