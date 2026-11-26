#!/bin/bash
# Prepare a loongarch64 (loong64) build environment on an x86_64 GitHub runner.
# Writes the resulting docker image name to /tmp/loong64-image.txt
set -euxo pipefail

IMAGE_FILE=/tmp/loong64-image.txt
rm -f "$IMAGE_FILE"

# ---------------------------------------------------------------- openEuler --
# Kylin V11 is openEuler-based; an openEuler 24.03 rootfs (glibc 2.38) is the
# closest public match for it.
for ver in 24.03-LTS-SP2 24.03-LTS-SP1 24.03-LTS; do
	for u in \
		"https://repo.openeuler.org/openEuler-${ver}/docker_img/loongarch64/openEuler-docker.loongarch64.tar.xz" \
		"https://repo.openeuler.org/openEuler-${ver}/docker_img/loongarch64/openEuler-docker-rootfs.loongarch64.tar.xz"; do
		echo "trying $u"
		if curl -fsSL --retry 2 --connect-timeout 20 -o /tmp/oe.tar.xz "$u"; then
			if docker load -i /tmp/oe.tar.xz > /tmp/oe-load.txt 2>&1; then
				cat /tmp/oe-load.txt
				img=$(awk '/^Loaded image:/{print $3}' /tmp/oe-load.txt | head -n 1)
				if [ -n "$img" ]; then
					echo "$img" > "$IMAGE_FILE"
					exit 0
				fi
			else
				cat /tmp/oe-load.txt || true
			fi
		fi
	done
done

# ------------------------------------------------------------------ Debian --
# Debian ports provides loong64; build a minimal rootfs and import it.
sudo apt-get update
sudo apt-get install -y --no-install-recommends debootstrap debian-ports-archive-keyring

ROOT=/tmp/loong64-rootfs
sudo rm -rf "$ROOT"
KEYRING=/usr/share/keyrings/debian-ports-archive-keyring.gpg

debootstrap_loong64() {
	sudo debootstrap --arch=loong64 --foreign --variant=minbase --components=main \
		"$@" sid "$ROOT" http://deb.debian.org/debian-ports
}

if ! debootstrap_loong64 --keyring="$KEYRING"; then
	sudo rm -rf "$ROOT"
	debootstrap_loong64 --no-check-gpg
fi

sudo tar -C "$ROOT" -c . | docker import --platform linux/loong64 - local/loong64-sid:latest

# Run debootstrap second stage inside the emulated container.
docker run --rm --platform linux/loong64 local/loong64-sid:latest \
	/debootstrap/debootstrap --second-stage

echo "local/loong64-sid:latest" > "$IMAGE_FILE"
