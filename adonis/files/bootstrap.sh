#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# ==========================================================================
# Adonis bootstrap: the only boot logic baked into this (public) image.
#
# Everything site-specific (sshd policy, admin keys, WireGuard, Apache,
# Zabbix, docs...) lives in the private app repo under addon/, versioned by
# the same per-host git tag as the app itself. This script only:
#   1. migrates the pre-4.1.18 persist_home location (must run before
#      anything creates /data/persist_home, or the migration never fires)
#   2. makes sure this host has its own read-only deploy key for the app repo
#   3. fetches the configured tag and extracts its addon/ into /data/bootstrap
#   4. falls back to the last addon/ that booted successfully, with the app
#      pinned to that same commit, if the tag can't be fetched, its scripts
#      don't parse, or they failed to finish booting N starts in a row
#      (option rollback_after_failed_starts, default 3)
#   5. hands over to addon/run.sh
#
# Logging: every line this script prints starts with ">>>", so anything
# unprefixed is a command's own output.
# bashio runs us with errexit + pipefail: every command that may fail is
# wrapped in `if`, never run bare and checked via $? afterwards.
# ==========================================================================

echo ">>> =========================================================================="
echo ">>>   ADONIS BOOTSTRAP: image ${BUILD_VERSION:-unknown}"
echo ">>> =========================================================================="

GITHUB_TAG=$(bashio::config 'github_tag')
APP_REPO=$(bashio::config 'app_repo')
persist_home=/data/persist_home
bootstrap_dir=/data/bootstrap
webrootdocker=/var/www/html

fatal() {
	echo ">>> =========================================================================="
	local line
	for line in "$@"; do echo ">>> FATAL: $line"; done
	echo ">>> =========================================================================="
	exit 1
}

is_unset() { [ -z "$1" ] || [ "$1" = "null" ]; }

is_unset "$GITHUB_TAG" && fatal "github_tag is not set in this add-on's configuration." \
	"Set it to this host's release tag in the app repo."
is_unset "$APP_REPO" && fatal "app_repo is not set in this add-on's configuration." \
	"Set it to the app repo's SSH URL, git@github.com:<owner>/<repo>.git"

# owner/repo, only used to print the deploy-key settings URL below
repo_path=$(printf '%s' "$APP_REPO" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/)##; s#\.git$##')

# ====================== 1. PERSIST_HOME MIGRATION ======================
# Hosts that booted before 4.1.18 kept persist_home in /config. Move it
# instead of starting fresh, or every per-host key (WireGuard, deploy,
# docker-hop, SSH host key) would look lost. Must stay ahead of step 2,
# which creates $persist_home and would make this condition false forever.
old_persist_home=/config/_adonis_persist_home
if [ -d "$old_persist_home" ] && [ ! -e "$persist_home" ]; then
	echo ">>> migrating persist_home from $old_persist_home to $persist_home"
	mkdir -p "$(dirname "$persist_home")"
	mv "$old_persist_home" "$persist_home"
	# A restarted (not recreated) container still has last boot's symlinks
	# in /root pointing at the old path; drop them so they get relinked.
	for link in /root/.claude /root/.vscode-server /root/.local /root/.claude.json; do
		if [ -L "$link" ]; then rm -f "$link"; fi
	done
fi
mkdir -p "$persist_home" "$bootstrap_dir"

# ====================== 2. PER-HOST DEPLOY KEY ======================
# Unique per host, never in git: one leaked host can't read the app repo
# on behalf of any other. Labelled with github_tag because $(hostname) is
# the same on every host running this add-on.
key_dir="$persist_home/ssh_deploy_key"
key="$key_dir/id_ed25519"
mkdir -p "$key_dir"
chmod 700 "$key_dir"
if [ ! -f "$key" ]; then
	echo ">>> no deploy key for this host yet, generating one"
	ssh-keygen -t ed25519 -N "" -C "adonis-${GITHUB_TAG}" -f "$key" >/dev/null
fi
install -d -m 700 /root/.ssh
install -m 600 "$key" /root/.ssh/id_ed25519
install -m 644 "$key.pub" /root/.ssh/id_ed25519.pub

print_deploy_key_help() {
	echo ">>> Register this host's key as a READ-ONLY deploy key at:"
	echo ">>>   https://github.com/${repo_path}/settings/keys"
	echo ">>> $(cat "$key.pub")"
}
echo ">>> this host's deploy key: $(cat "$key.pub")"

# ====================== 3. FETCH TAG, EXTRACT addon/ ======================
# Fetched straight into the app's own repo so addon/scripts/090_init_repo.sh
# can check it out without a second network round trip. Only the object
# store changes here; the working tree is left to 090_init_repo.sh.
mkdir -p "$webrootdocker"
cd "$webrootdocker"
if [ ! -d .git ]; then git init -q; fi
if ! git remote set-url origin "$APP_REPO" 2>/dev/null; then
	git remote add origin "$APP_REPO"
fi

mode=online
fetch_log=$(mktemp)
# "+": per-host tags are moved on purpose, and a plain refspec refuses to
# update a tag that already exists locally ("would clobber existing tag").
if ! git fetch origin "+refs/tags/${GITHUB_TAG}:refs/tags/${GITHUB_TAG}" 2>&1 | tee "$fetch_log"; then
	mode=cached
	echo ">>> WARNING: fetching tag '$GITHUB_TAG' failed"
	if grep -qi 'permission denied\|publickey' "$fetch_log"; then
		echo ">>> this looks like an SSH auth failure:"
		print_deploy_key_help
	fi
fi
rm -f "$fetch_log"

# Extracts addon/ at $1 into $bootstrap_dir/addon-$1 unless it's already
# there. Refuses scripts that don't even parse, so a typo on a tag falls
# back to last-good instead of killing the boot.
extract_addon() {
	local commit="$1" dest="$bootstrap_dir/addon-$1" staging="$bootstrap_dir/.staging" f
	if [ -f "$dest/run.sh" ]; then return 0; fi
	rm -rf "$staging"
	mkdir -p "$staging"
	if ! git archive "$commit" addon | tar -x -C "$staging" --strip-components=1; then
		echo ">>> WARNING: commit $commit has no addon/ directory"
		rm -rf "$staging"
		return 1
	fi
	while IFS= read -r f; do
		if ! bash -n "$f"; then
			echo ">>> WARNING: ${f#"$staging"/} at $commit has syntax errors, not using it"
			rm -rf "$staging"
			return 1
		fi
	done < <(find "$staging" -name '*.sh')
	if [ ! -f "$staging/run.sh" ]; then
		echo ">>> WARNING: addon/run.sh missing at $commit"
		rm -rf "$staging"
		return 1
	fi
	printf '%s %s\n' "$GITHUB_TAG" "$commit" > "$staging/.adonis-source"
	mv "$staging" "$dest"
}

commit=""
addon_dir=""
if commit=$(git rev-parse -q --verify "refs/tags/${GITHUB_TAG}^{commit}"); then
	if extract_addon "$commit"; then
		addon_dir="$bootstrap_dir/addon-$commit"
	fi
else
	commit=""
fi

# last-good holds the path of the addon dir whose run.sh last made it all
# the way to supervisord (written by run.sh itself). Plain file, not a
# symlink, so it can't dangle half-way.
last_good=$(cat "$bootstrap_dir/last-good" 2>/dev/null || true)

# Switches to last-good: its scripts AND its app commit (addon/ and the app
# come from the same commit), so a fallback never deploys anything new.
use_last_good() {
	addon_dir="$last_good"
	commit=$(cut -d' ' -f2 "$last_good/.adonis-source")
	mode=fallback
	echo ">>> =========================================================================="
	echo ">>> WARNING: $1"
	echo ">>> Falling back to the last scripts that booted successfully, with the app"
	echo ">>> pinned to the same commit: $(cat "$last_good/.adonis-source")"
	echo ">>> =========================================================================="
}
have_last_good() { [ -n "$last_good" ] && [ -f "$last_good/run.sh" ]; }

if [ -z "$addon_dir" ]; then
	if have_last_good; then
		use_last_good "no usable addon/ for tag '$GITHUB_TAG'"
	else
		print_deploy_key_help
		fatal "no usable addon/ for tag '$GITHUB_TAG' and no last-good copy cached yet." \
			"Check that the tag exists, that it contains addon/run.sh, and the deploy key above."
	fi
fi

# Failed-start rollback. "<commit> <n>" in failed-starts = starts of that
# commit's scripts that never reached supervisord (run.sh deletes the file
# once it does). After max_failed of them, use last-good instead, and keep
# using it until the tag moves to another commit or the file is deleted.
max_failed=$(bashio::config 'rollback_after_failed_starts')
case "$max_failed" in ''|null|*[!0-9]*) max_failed=3 ;; esac
failed_file="$bootstrap_dir/failed-starts"
if [ "$mode" != fallback ] && [ "$addon_dir" != "$last_good" ]; then
	prev_commit="" prev_count=0
	if [ -f "$failed_file" ]; then read -r prev_commit prev_count < "$failed_file" || true; fi
	case "$prev_count" in ''|*[!0-9]*) prev_count=0 ;; esac
	if [ "$prev_commit" != "$commit" ]; then prev_count=0; fi
	if [ "$max_failed" -gt 0 ] && [ "$prev_count" -ge "$max_failed" ] && have_last_good; then
		use_last_good "scripts at ${commit:0:12} failed to finish booting $prev_count times in a row. To retry them, move the tag or delete $failed_file, then restart."
	else
		printf '%s %s\n' "$commit" "$((prev_count + 1))" > "$failed_file"
	fi
fi

# The fallback commit has to be in the local repo for 090_init_repo.sh to
# check it out; a recreated container may not have it yet.
if [ "$mode" = fallback ] && ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
	if ! git fetch origin "$commit"; then
		echo ">>> WARNING: couldn't fetch last-good commit $commit either"
	fi
fi

# Keep only what's in use and the last-good fallback.
printf '%s\n' "$addon_dir" > "$bootstrap_dir/current"
for d in "$bootstrap_dir"/addon-*; do
	if [ "$d" != "$addon_dir" ] && [ "$d" != "$last_good" ]; then rm -rf "$d"; fi
done

# ====================== 4. HAND OVER ======================
# ADONIS_BOOTSTRAP_API is the contract between this image and addon/run.sh;
# bump it (and check for it there) if what's exported here ever changes.
export ADONIS_BOOTSTRAP_API=1
export ADONIS_BOOTSTRAP_DIR="$bootstrap_dir"
export ADONIS_ADDON_DIR="$addon_dir"
export ADONIS_BOOTSTRAP_MODE="$mode"
export ADONIS_APP_COMMIT="$commit"
export persist_home webrootdocker
echo ">>> handing over to $addon_dir/run.sh (mode=$mode, app ${commit:0:12}, t=${SECONDS}s)"
# Plain bashio, NOT with-contenv: with-contenv empties the environment and
# reloads only the container's own variables, which would drop every export
# above (seen on alameda's first boot: run.sh got bootstrap API 'none').
# This script already runs under with-contenv, so those variables are here.
exec bashio "$addon_dir/run.sh"
