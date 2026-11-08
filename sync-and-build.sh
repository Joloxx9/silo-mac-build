#!/usr/bin/env bash
# Pull upstream Silo into the Spark branches and start every build.
#
# Silo stays Silo, Spark is Spark: every fork's `main` mirrors upstream Silo
# untouched (fast-forwarded here), and Spark's own changes live on `spark`.
#
#   ./sync-and-build.sh              merge upstream, push, build everything
#   ./sync-and-build.sh --check      only report what is new and whether it merges cleanly
#   ./sync-and-build.sh --no-build   merge and push, start no builds
#   ./sync-and-build.sh --build-only start the builds from what is already pushed
#   ./sync-and-build.sh --only server,apple,android   limit to some repos
#
# A repo whose merge conflicts is left untouched (the merge is aborted) and
# reported at the end; resolve it by hand, push, and run with --build-only.
#
# Spark branches:
#   server   Joloxx9/silo-server  spark -> fork-image.yml (runs on push) -> ghcr.io/joloxx9/silo-server:latest
#   apple    Joloxx9/silo-apple   spark -> silo-mac-build: mac-app.yml + sideload-ipa.yml
#   android  Joloxx9/silo-android spark -> spark-apk.yml (runs on push)
# Plugin forks with a `spark` branch only get their `main` mirror refreshed.
set -euo pipefail

OWNER=Joloxx9
GIT_NAME=Joloxx9
GIT_EMAIL=joloxx9@gmail.com
WORK=${WORK:-$HOME/work}
SERVER_DIR=${SERVER_DIR:-$HOME/silo-server}
BRANCH=spark
# Forks whose `main` mirrors upstream: repo name -> upstream owner/repo.
MIRRORS=(
  "silo-server Silo-Server/silo-server"
  "silo-apple Silo-Server/silo-apple"
  "silo-android Silo-Server/silo-android"
  "silo-plugin-sdk Silo-Server/silo-plugin-sdk"
  "silo-plugin-watchprovider-mdblist Silo-Server/silo-plugin-watchprovider-mdblist"
  "silo-plugin-mediux Pukabyte/silo-plugin-mediux"
  "silo-plugin-metadata-aura Artic0din/silo-plugin-metadata-aura"
)
APPLE_DIR=${APPLE_DIR:-$WORK/silo-apple-mac}
CATALOG_DIR=${CATALOG_DIR:-$WORK/spark-plugins/silo-plugins-src}
ANDROID_DIR=${ANDROID_DIR:-$WORK/silo-android}

mode=full
only=server,apple,android
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --no-build) mode=nobuild ;;
    --build-only) mode=buildonly ;;
    --only) only=$2; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

want() { [[ ",$only," == *",$1,"* ]]; }
g() { git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" "$@"; }

failed=()
summary=()
pushed=()

# sync <key> <dir> <repo> <branch>
sync() {
  local key=$1 dir=$2 repo=$3 branch=$4
  if [ ! -d "$dir/.git" ]; then
    git clone -q "https://github.com/$OWNER/$repo.git" "$dir"
  fi
  cd "$dir"
  git remote get-url upstream >/dev/null 2>&1 \
    || git remote add upstream "https://github.com/Silo-Server/$repo.git"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    failed+=("$key: $dir has uncommitted changes, skipped")
    return
  fi
  git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git fetch -q upstream "+refs/heads/main:refs/remotes/upstream/main"
  local new
  new=$(git rev-list --count "origin/$branch..upstream/main")
  if [ "$new" = 0 ]; then
    summary+=("$key: already has upstream main")
    return
  fi
  if [ "$mode" = check ]; then
    local tmp; tmp=$(mktemp)
    if git merge-tree --write-tree --name-only "origin/$branch" upstream/main >"$tmp" 2>&1; then
      summary+=("$key: $new new upstream commits, merges cleanly")
    else
      summary+=("$key: $new new upstream commits, CONFLICTS in: $(tail -n +2 "$tmp" | sed '/^$/,$d' | tr '\n' ' ')")
    fi
    rm -f "$tmp"
    return
  fi
  if git show-ref -q --verify "refs/heads/$branch"; then
    git checkout -q "$branch"
    git merge -q --ff-only "origin/$branch"
  else
    git checkout -q -b "$branch" "origin/$branch"
  fi
  if ! g merge -q --no-edit upstream/main -m "Merge upstream/main into $branch"; then
    local files
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git merge --abort
    failed+=("$key: merge conflicts in: $files")
    return
  fi
  git push -q origin "$branch"
  pushed+=("$key")
  summary+=("$key: merged $new upstream commits and pushed $branch")
}

# Fast-forward each fork's `main` to upstream. A mirror that diverged is
# reported, never merged into: Spark's changes belong on spark.
mirror_mains() {
  local entry repo up branch out
  for entry in "${MIRRORS[@]}"; do
    read -r repo up <<<"$entry"
    branch=$(gh api "repos/$up" -q .default_branch)
    if [ "$mode" = check ]; then
      out=$(gh api "repos/$up/compare/$branch...$OWNER:main" -q '"ahead \(.ahead_by), behind \(.behind_by)"' 2>&1) || true
      summary+=("mirror $repo main vs $up: $out")
      continue
    fi
    out=$(gh api "repos/$up/compare/$branch...$OWNER:main" -q .ahead_by 2>/dev/null || echo "?")
    if [ "$out" != 0 ]; then
      failed+=("mirror $repo: main has $out commits upstream lacks; move them to spark, then reset main")
      continue
    fi
    gh api -X PATCH "repos/$OWNER/$repo/git/refs/heads/main" \
      -f sha="$(gh api "repos/$up/branches/$branch" -q .commit.sha)" >/dev/null \
      && summary+=("mirror $repo: main = $up $branch") \
      || failed+=("mirror $repo: could not fast-forward main")
  done
}

build_server() {
  # A push to spark already started the build.
  if [[ " ${pushed[*]:-} " == *" server "* ]]; then
    summary+=("server: build started by the push")
    return
  fi
  gh workflow run fork-image.yml -R "$OWNER/silo-server" --ref "$BRANCH"
  summary+=("server: started fork-image.yml")
}
build_apple() {
  gh workflow run mac-app.yml -R "$OWNER/silo-mac-build" \
    -f repository="$OWNER/silo-apple" -f ref="$BRANCH"
  gh workflow run sideload-ipa.yml -R "$OWNER/silo-mac-build" \
    -f repository="$OWNER/silo-apple" -f ref="$BRANCH" -f platform=both
  summary+=("apple: started macOS and iOS/tvOS builds")
}
build_android() {
  # A push to spark already started the build.
  if [[ " ${pushed[*]:-} " == *" android "* ]]; then
    summary+=("android: build started by the push")
    return
  fi
  gh workflow run spark-apk.yml -R "$OWNER/silo-android" --ref "$BRANCH"
  summary+=("android: started spark-apk.yml")
}

# The Spark plugin catalog is a copy, not a GitHub fork (Silo-Server does not
# allow forking it), so its main mirror and spark merge run through git.
sync_catalog() {
  local dir=$CATALOG_DIR
  if [ ! -d "$dir/.git" ]; then
    git clone -q -b spark "https://github.com/$OWNER/spark-plugins.git" "$dir"
    git -C "$dir" remote add upstream https://github.com/Silo-Server/silo-plugins.git
  fi
  cd "$dir"
  git fetch -q origin && git fetch -q upstream main
  local new
  new=$(git rev-list --count origin/main..upstream/main)
  if [ "$new" = 0 ]; then
    summary+=("catalog: already has Silo's catalog")
    return
  fi
  if [ "$mode" = check ]; then
    summary+=("catalog: $new new Silo catalog commits")
    return
  fi
  git push -q origin upstream/main:refs/heads/main
  git checkout -q spark && git merge -q --ff-only origin/spark
  if ! g merge -q --no-edit upstream/main -m "Merge Silo's catalog into spark"; then
    git merge --abort
    failed+=("catalog: merge conflicts; merge Silo-Server/silo-plugins into spark by hand")
    return
  fi
  git push -q origin spark
  summary+=("catalog: merged $new Silo catalog commits into spark")
}

if [ "$mode" != buildonly ]; then
  mirror_mains
  sync_catalog
  want server && sync server "$SERVER_DIR" silo-server "$BRANCH"
  want apple && sync apple "$APPLE_DIR" silo-apple "$BRANCH"
  want android && sync android "$ANDROID_DIR" silo-android "$BRANCH"
fi

if [ "$mode" = full ] || [ "$mode" = buildonly ]; then
  for key in server apple android; do
    want "$key" || continue
    # Do not build a repo whose merge failed; its branch is unchanged.
    if printf '%s\n' "${failed[@]:-}" | grep -q "^$key:"; then continue; fi
    "build_$key"
  done
fi

printf '%s\n' "${summary[@]:-}"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'FAILED %s\n' "${failed[@]}"
  exit 1
fi
