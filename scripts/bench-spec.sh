#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/bench-spec.sh [--commit] [--] [benchmark arguments...]

Run `zig build bench` and archive its complete output with the exact SPEC.md and
source provenance under benchmarks/<UTC-run-id>-<head12>/. Arguments after --
are passed to the benchmark build command. --commit commits only the new archive.
EOF
}
fail() { printf 'bench-spec: %s\n' "$*" >&2; exit 2; }

commit=0
args=()
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --commit) ((commit == 0)) || fail 'duplicate --commit'; commit=1; shift ;;
    --) shift; args+=("$@"); break ;;
    -*) fail "unknown helper option: $1 (use -- before benchmark arguments)" ;;
    *) args+=("$@"); break ;;
  esac
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || fail 'script is not inside a Git repository'
cd "$root"
[[ -r SPEC.md ]] || fail 'SPEC.md is missing or unreadable'
for tool in zig git sha256sum sort awk date mktemp cp mv grep tee mkdir rm stat; do command -v "$tool" >/dev/null || fail "$tool is required"; done
mkdir -p zig-out
if command -v flock >/dev/null; then
  exec 9>"$root/zig-out/.bench-spec.lock"
  flock -n 9 || fail 'another bench-spec run is active'
fi
if [[ -z ${TMPDIR:-} ]]; then mkdir -p zig-out/bench-spec-tmp; export TMPDIR="$root/zig-out/bench-spec-tmp"; fi

head=$(git rev-parse HEAD)
head12=${head:0:12}
run_id=$(date -u +%Y%m%dT%H%M%S.%NZ)
archive="benchmarks/${run_id}-${head12}"
[[ ! -e "$archive" ]] || fail "snapshot already exists: $archive"
stage=$(mktemp -d "$root/zig-out/bench-spec-stage.XXXXXXXX")
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
spec_hash=$(sha256sum SPEC.md | awk '{print $1}')
cp -- SPEC.md "$stage/SPEC.md"
[[ $(sha256sum "$stage/SPEC.md" | awk '{print $1}') == "$spec_hash" ]] || fail 'could not preserve exact SPEC.md copy'

# Produce a stable, inspectable manifest; git-listing failures are fatal.
make_manifest() {
  local destination=$1 p entry subhead index_oid worktree_status
  local -a paths=()
  git ls-files --cached --others --exclude-standard -z > "$stage/paths.list" || return 1
  while IFS= read -r -d '' p; do
    case "$p" in src/*|lib/*|vendor/*|scripts/*|build.zig|build.zig.zon|SPEC.md|DESIGN.md|AGENTS.md) paths+=("$p");; esac
  done < "$stage/paths.list"
  : > "$destination"
  while IFS= read -r -d '' p; do
    case "$p" in src/*|lib/*|vendor/*|scripts/*|build.zig|build.zig.zon|SPEC.md|DESIGN.md|AGENTS.md) ;; *) continue;; esac
    entry=$(git ls-files --stage -- "$p") || return 1
    if [[ "$entry" == *$'\t'* ]]; then
      index_oid=${entry%% *}; index_oid=${entry#* }; index_oid=${index_oid%% *}
      if [[ $entry == 160000\ * ]]; then
        [[ -d "$p" ]] || { printf 'MISSING-GITLINK %q %s\n' "$p" "$index_oid" >> "$destination"; continue; }
        subhead=$(git -C "$p" rev-parse HEAD 2>/dev/null) || { printf 'UNREADABLE-GITLINK %q\n' "$p" >> "$destination"; continue; }
        [[ "$subhead" == "$index_oid" ]] || fail "gitlink $p HEAD differs from index; refusing unsupported submodule state"
        worktree_status=$(git -C "$p" status --porcelain --untracked-files=all) || return 1
        [[ -z "$worktree_status" ]] || fail "gitlink $p has a dirty worktree; refusing unsupported submodule state"
        printf 'GITLINK %q %s\n' "$p" "$subhead" >> "$destination"
      fi
    fi
    if [[ -f "$p" || -L "$p" ]]; then
      printf 'FILE %q ' "$p" >> "$destination"
      sha256sum "$p" | awk '{print $1}' >> "$destination" || return 1
    elif [[ -d "$p" ]]; then printf 'DIR %q\n' "$p" >> "$destination"
    else printf 'MISSING %q\n' "$p" >> "$destination"
    fi
  done < <(printf '%s\0' "${paths[@]}" | sort -zu)
}
make_manifest "$stage/manifest.before" || fail 'could not create source manifest'
source_before=$(sha256sum "$stage/manifest.before" | awk '{print $1}')

cmd=(zig build bench)
if ((${#args[@]})); then cmd+=(-- "${args[@]}"); fi
printf 'Running:'; printf ' %q' "${cmd[@]}"; printf '\n'
report="$stage/report.txt"
set +e
"${cmd[@]}" 2>&1 | tee "$report"
pipeline=("${PIPESTATUS[@]}")
set -e
((pipeline[0] == 0)) || fail "benchmark failed (exit ${pipeline[0]}); no snapshot published"
((pipeline[1] == 0)) || fail 'tee could not capture the complete report; no snapshot published'
grep -Eq '^saved bench/[^[:space:]]+ and last_bench$' "$report" || fail 'benchmark completion marker missing (help or incomplete run); no snapshot published'

make_manifest "$stage/manifest.after" || fail 'could not verify source manifest after benchmark'
source_after=$(sha256sum "$stage/manifest.after" | awk '{print $1}')
[[ $(git rev-parse HEAD) == "$head" ]] || fail 'HEAD changed during benchmark; refusing snapshot'
spec_after=$(sha256sum SPEC.md | awk '{print $1}')
[[ "$spec_after" == "$spec_hash" ]] || fail 'SPEC.md changed during benchmark; refusing snapshot'
[[ "$source_after" == "$source_before" ]] || fail 'source/input fingerprint changed during benchmark; refusing snapshot'
[[ $(sha256sum "$stage/SPEC.md" | awk '{print $1}') == "$spec_hash" ]] || fail 'archived SPEC copy failed digest verification'

out="$stage/archive"
mkdir -p "$out"
cp -- "$report" "$out/report.txt"
cp -- "$stage/SPEC.md" "$out/SPEC.md"
cp -- "$stage/manifest.before" "$out/source-manifest.txt"
if ((${#args[@]} == 0)); then mode=default-settings; elif printf '%s\n' "${args[@]}" | grep -Fxq -- '--quick'; then mode=quick-flag; else mode=custom-settings; fi
{
  printf 'run_utc=%s\nhead=%s\nhead_dirty=%s\nspec_sha256=%s\nsource_fingerprint=%s\nbenchmark_mode=%s\n' "$run_id" "$head" "$(if [[ -n $(git status --porcelain) ]]; then echo true; else echo false; fi)" "$spec_hash" "$source_before" "$mode"
  printf 'command=%q' "${cmd[0]}"; printf ' %q' "${cmd[@]:1}"; printf '\n'
} > "$out/metadata.txt"
mkdir -p benchmarks
[[ ! -e "$archive" ]] || fail "snapshot already exists: $archive"
[[ $(stat -c %d "$out") == $(stat -c %d benchmarks) ]] || fail 'staging and archive must share a filesystem for atomic publication'
mv -T -- "$out" "$archive"
trap - EXIT
rm -rf -- "$stage"
printf 'Snapshot: %s\n' "$archive"
if ((commit)); then
  git add -- "$archive"
  git commit --only -m "Add benchmark snapshot ${run_id}" -- "$archive"
  printf 'Committed snapshot only.\n'
else
  printf 'Not committed; archive is available for review.\n'
fi
