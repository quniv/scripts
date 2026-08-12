#!/usr/bin/env bash
#
# Clone (or update) every repository in a GitHub organization.
#
# Usage: ./clone-org.sh <org> [options]

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: clone-org.sh <org> [options]

Clone every repository of a GitHub organization. Repositories that are already
present in the destination directory are updated with `git pull` instead.

Arguments:
  <org>                     GitHub organization (or user) name.

Options:
  -d, --dir <path>          Destination directory (default: ./<org>).
  -j, --jobs <n>            Parallel clones (default: 8).
  -p, --protocol <ssh|https>  Clone protocol (default: ssh).
  -v, --visibility <v>      Only public, private or internal repos (default: all).
  -l, --limit <n>           Max repositories to fetch (default: 1000).
      --include-archived    Include archived repositories (skipped by default).
      --include-forks       Include forks (skipped by default).
      --depth <n>           Create shallow clones with the given depth.
      --dry-run             List what would happen without touching the disk.
  -h, --help                Show this help.

Examples:
  ./clone-org.sh my-org
  ./clone-org.sh my-org --dir ~/src/my-org --jobs 16 --protocol https
  ./clone-org.sh my-org --visibility private --include-archived
EOF
}

ORG=""
DEST=""
JOBS=8
PROTOCOL="ssh"
VISIBILITY=""
LIMIT=1000
INCLUDE_ARCHIVED=false
INCLUDE_FORKS=false
DEPTH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)         DEST="${2:?--dir requires a value}"; shift 2 ;;
        -j|--jobs)        JOBS="${2:?--jobs requires a value}"; shift 2 ;;
        -p|--protocol)    PROTOCOL="${2:?--protocol requires a value}"; shift 2 ;;
        -v|--visibility)  VISIBILITY="${2:?--visibility requires a value}"; shift 2 ;;
        -l|--limit)       LIMIT="${2:?--limit requires a value}"; shift 2 ;;
        --include-archived) INCLUDE_ARCHIVED=true; shift ;;
        --include-forks)    INCLUDE_FORKS=true; shift ;;
        --depth)          DEPTH="${2:?--depth requires a value}"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        -*)               echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -n "$ORG" ]]; then
                echo "Unexpected argument: $1" >&2
                exit 2
            fi
            ORG="$1"; shift ;;
    esac
done

if [[ -z "$ORG" ]]; then
    echo "Error: organization name is required." >&2
    usage >&2
    exit 2
fi

case "$PROTOCOL" in
    ssh|https) ;;
    *) echo "Error: --protocol must be 'ssh' or 'https', got '$PROTOCOL'." >&2; exit 2 ;;
esac

if [[ -n "$VISIBILITY" && ! "$VISIBILITY" =~ ^(public|private|internal)$ ]]; then
    echo "Error: --visibility must be public, private or internal." >&2
    exit 2
fi

for cmd in gh git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: not logged in to GitHub. Run 'gh auth login' first." >&2
    exit 1
fi

DEST="${DEST:-./$ORG}"

list_args=("$ORG" --limit "$LIMIT" --json "name,sshUrl,url,isArchived,isFork")
[[ -n "$VISIBILITY" ]] && list_args+=(--visibility "$VISIBILITY")
[[ "$INCLUDE_ARCHIVED" == false ]] && list_args+=(--no-archived)
[[ "$INCLUDE_FORKS" == false ]] && list_args+=(--source)

echo "Fetching repository list for '$ORG'..."
repos_json="$(gh repo list "${list_args[@]}")"

url_field="sshUrl"
[[ "$PROTOCOL" == "https" ]] && url_field="url"

# Tab-separated "name<TAB>clone-url" lines, one per repository.
mapfile -t repos < <(jq -r --arg f "$url_field" '.[] | "\(.name)\t\(.[$f])"' <<<"$repos_json")

count="${#repos[@]}"
if [[ "$count" -eq 0 ]]; then
    echo "No repositories found for '$ORG' with the given filters."
    exit 0
fi

echo "Found $count repositor$([[ $count -eq 1 ]] && echo y || echo ies). Destination: $DEST"

if [[ "$DRY_RUN" == true ]]; then
    printf '%s\n' "${repos[@]}" | while IFS=$'\t' read -r name url; do
        if [[ -d "$DEST/$name/.git" ]]; then
            echo "  [update] $name"
        else
            echo "  [clone ] $name <- $url"
        fi
    done
    exit 0
fi

mkdir -p "$DEST"

# Runs in a subshell per repository via xargs; keep it self-contained.
process_repo() {
    local name="${1%%$'\t'*}"
    local url="${1#*$'\t'}"
    local target="$DEST/$name"

    if [[ -d "$target/.git" ]]; then
        if git -C "$target" pull --ff-only --quiet 2>/dev/null; then
            echo "updated  $name"
        else
            echo "skipped  $name (local changes or diverged branch)" >&2
        fi
        return 0
    fi

    local clone_args=(clone --quiet)
    [[ -n "$DEPTH" ]] && clone_args+=(--depth "$DEPTH")
    clone_args+=("$url" "$target")

    if git "${clone_args[@]}"; then
        echo "cloned   $name"
    else
        echo "FAILED   $name" >&2
        return 1
    fi
}
export -f process_repo
export DEST DEPTH
export GIT_TERMINAL_PROMPT=0

failures=0
printf '%s\n' "${repos[@]}" \
    | xargs -P "$JOBS" -I {} bash -c 'process_repo "$@"' _ {} \
    || failures=1

if [[ "$failures" -ne 0 ]]; then
    echo "Done, but some repositories failed. See errors above." >&2
    exit 1
fi

echo "Done. All $count repositories are in $DEST"
