#!/usr/bin/env bash

set -euo pipefail

readonly DEPENDENCIES="git ssh curl pacman useradd chown sed"
readonly AUR_URL="ssh://aur@aur.archlinux.org/${AUR_REPO}.git"
readonly REQUIRED_ENV="AUR_SSH_KEY AUR_REPO VERSION RELEASE_FILENAME REPO_URL EMAIL GITHUB_WORKSPACE"

check_deps() {
	for dep in $DEPENDENCIES; do
		if ! command -v "$dep" &>/dev/null; then
			printf "[ERROR] Missing dependency: %s\n" "$dep" >&2
			exit 1
		fi
	done
}

log_info()  { printf "[INFO]  %s\n" "$1"; }
log_warn()  { printf "[WARN]  %s\n" "$1" >&2; }
log_error() { printf "[ERROR] %s\n" "$1" >&2; }

validate_env() {
	local missing=0

	for var in $REQUIRED_ENV; do
		if [[ -z "${!var:-}" ]]; then
			log_error "Required env var not set: $var"
			missing=1
		fi
	done

	[[ "$missing" -eq 0 ]] || exit 1
}

bootstrap_system() {
	log_info "Initializing pacman keyring..."
	pacman-key --init
	pacman-key --populate archlinux

	log_info "Installing required packages..."
	pacman -Sy --noconfirm archlinux-keyring openssh git pacman-contrib curl base-devel
}

setup_ssh() {
	mkdir -p /root/.ssh
	printf "%s\n" "$AUR_SSH_KEY" > /root/.ssh/id_ed25519
	chmod 600 /root/.ssh/id_ed25519
	ssh-keyscan aur.archlinux.org >> /root/.ssh/known_hosts
}

setup_git() {
	git config --global user.name "erffy"
	git config --global user.email "$EMAIL"
	git config --global --add safe.directory "*"
}

compute_pkgrel() {
	local -r old_ver="$1"
	local -r old_rel="$2"

	if [[ "$old_ver" == "$VERSION" ]]; then
		printf "%d" $(( old_rel + 1 ))
	else
		printf "1"
	fi
}

patch_pkgbuild() {
	local -r pkgrel="$1"

	sed -i "s|^pkgver=.*|pkgver=${VERSION}|" PKGBUILD
	sed -i "s|^pkgrel=.*|pkgrel=${pkgrel}|" PKGBUILD
	sed -i "s|BINARY_DOWNLOAD_URL|${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}|g" PKGBUILD
	sed -i "s|CONFIG_DOWNLOAD_URL|${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc|g" PKGBUILD
	sed -i "s|LICENSE_DOWNLOAD_URL|${REPO_URL}/raw/tag/${VERSION}/LICENSE|g" PKGBUILD
}

fetch_sources() {
	curl -fsSL -o zig-waybar-contrib.zip "${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}"
	curl -fsSL -o config.waybar.jsonc "${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc"
	curl -fsSL -o LICENSE "${REPO_URL}/raw/tag/${VERSION}/LICENSE"
}

cleanup_sources() {
	rm -f zig-waybar-contrib.zip config.waybar.jsonc LICENSE
}

generate_srcinfo() {
	useradd -m builduser 2>/dev/null || true
	chown -R builduser .

	su builduser -s /bin/bash -c "updpkgsums"
	su builduser -s /bin/bash -c "makepkg --printsrcinfo > .SRCINFO"
}

push_if_changed() {
	local -r pkgrel="$1"

	git add PKGBUILD .SRCINFO

	if git diff --quiet && git diff --cached --quiet; then
		log_info "No changes detected, skipping push."
		return 0
	fi

	git commit -m "release: update to ${VERSION}-${pkgrel}"
	git push origin master
}

main() {
	validate_env
	bootstrap_system
	check_deps

	log_info "Setting up SSH and git..."
	setup_ssh
	setup_git

	log_info "Cloning AUR repo..."
	git clone "$AUR_URL" aur-repo
	cd aur-repo

	local -r old_ver="$(grep "^pkgver=" PKGBUILD | cut -d= -f2 || printf "")"
	local -r old_rel="$(grep "^pkgrel=" PKGBUILD | cut -d= -f2 || printf "0")"
	local -r new_rel="$(compute_pkgrel "$old_ver" "$old_rel")"

	log_info "Updating PKGBUILD to ${VERSION}-${new_rel}..."
	cp "${GITHUB_WORKSPACE}/aur/${AUR_REPO}/PKGBUILD" PKGBUILD
	patch_pkgbuild "$new_rel"

	log_info "Fetching release sources for checksum generation..."
	fetch_sources

	log_info "Generating checksums and .SRCINFO..."
	generate_srcinfo
	cleanup_sources

	log_info "Committing and pushing..."
	push_if_changed "$new_rel"

	log_info "Done."
}

main