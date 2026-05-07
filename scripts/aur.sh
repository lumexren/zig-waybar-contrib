#!/usr/bin/env bash

set -euo pipefail

pacman -Sy --noconfirm git openssh pacman-contrib

mkdir -p /root/.ssh
echo "$AUR_SSH_KEY" > /root/.ssh/id_ed25519
ssh-keyscan aur.archlinux.org >> /root/.ssh/known_hosts

git config --global user.name "erffy"
git config --global user.email "$EMAIL"

cd aur/$AUR_REPO

BINARY_URL="${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}"
CONFIG_URL="${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc"
LICENSE_URL="${REPO_URL}/raw/tag/${VERSION}/LICENSE"

old_ver="$(grep "^pkgver=" PKGBUILD | cut -d= -f2 || printf "")"
old_rel="$(grep "^pkgrel=" PKGBUILD | cut -d= -f2 || printf "0")"
if [[ "$old_ver" == "$VERSION" ]]; then
	new_rel=$(( old_rel + 1 ))
else
	new_rel="1"
fi

sed -i "s|^pkgver=.*|pkgver=${VERSION}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=$new_rel|" PKGBUILD
sed -i "s|BINARY_DOWNLOAD_URL|${BINARY_URL}|" PKGBUILD
sed -i "s|CONFIG_DOWNLOAD_URL|${CONFIG_URL}|" PKGBUILD
sed -i "s|LICENSE_DOWNLOAD_URL|${LICENSE_URL}|" PKGBUILD

curl -fsSL -o zig-waybar-contrib.zip "${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}"
curl -fsSL -o config.waybar.jsonc "${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc"
curl -fsSL -o LICENSE "${REPO_URL}/raw/tag/${VERSION}/LICENSE"

chage -E -1 nobody
chown -R nobody .

su nobody -s /bin/bash -c "updpkgsums"
su nobody -s /bin/bash -c "makepkg --printsrcinfo > .SRCINFO"

rm zig-waybar-contrib.zip config.waybar.jsonc LICENSE

cd ../..
git clone ssh://aur@aur.archlinux.org/${AUR_REPO}.git aur-repo

cp aur/$AUR_REPO/{PKGBUILD,.SRCINFO} aur-repo

cd aur-repo
git add PKGBUILD .SRCINFO

if git diff --cached --quiet; then
  echo "No changes detected, skipping push."
	exit 0
fi

git commit -m "release: update to ${VERSION}-${new_rel}"
git push origin master