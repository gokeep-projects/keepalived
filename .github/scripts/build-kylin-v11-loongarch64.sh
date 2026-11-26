#!/bin/bash
# Build keepalived for Kylin V11 / loongarch64 inside a loongarch64 container.
# Runs under qemu-user on GitHub Actions.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
	apt-get update -o Acquire::Retries=10
	apt-get install -y --no-install-recommends -o Acquire::Retries=10 \
		build-essential autoconf automake libtool pkg-config \
		file ca-certificates tar gzip \
		libssl-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
		libpopt-dev libmagic-dev libglib2.0-dev
	# Optional feature dependencies: install what the distro provides.
	for p in libnfnetlink-dev libipset-dev libmnl-dev libnftnl-dev \
		libpcre2-dev libdbus-1-dev libsnmp-dev libsystemd-dev; do
		apt-get install -y --no-install-recommends -o Acquire::Retries=10 "$p" \
			|| echo "WARNING: optional package $p not available"
	done
elif command -v dnf >/dev/null 2>&1; then
	dnf_install() {
		dnf install -y --setopt=install_weak_deps=False \
			--setopt=max_parallel_downloads=1 --setopt=retries=20 \
			--setopt=timeout=120 "$@"
	}
	retry_dnf() {
		local i
		for i in 1 2 3 4; do
			dnf_install "$@" && return 0
			echo "WARNING: dnf install failed (attempt $i), retrying: $*"
			dnf clean packages >/dev/null 2>&1 || true
			sleep 10
		done
		return 1
	}
	retry_dnf gcc make autoconf automake libtool pkgconf-pkg-config \
		openssl-devel libnl3-devel popt-devel file tar gzip which
	for p in libnfnetlink-devel ipset-devel libmnl-devel libnftnl-devel \
		libdbus-1-devel net-snmp-devel systemd-devel glib2-devel; do
		retry_dnf "$p" || echo "WARNING: optional package $p not available"
	done
else
	echo "ERROR: unsupported distribution" >&2
	exit 1
fi

cd /src

VERSION=$(sed -n 's/^AC_INIT(\[Keepalived\], \[\([^]]*\)\].*/\1/p' configure.ac)
echo "Building keepalived ${VERSION}"

./autogen.sh
./configure \
	--prefix=/usr \
	--sysconfdir=/etc \
	--localstatedir=/var \
	--runstatedir=/run

make -j4

rm -rf /src/out
mkdir -p /src/out
make install DESTDIR=/src/out/rootfs

OUT=/src/out
ROOT=${OUT}/rootfs
NAME="keepalived-${VERSION}-kylin-v11-loongarch64"

{
	echo "name: ${NAME}"
	echo "build date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "architecture: $(uname -m)"
	echo "build glibc: $(ldd --version 2>&1 | head -n 1)"
	echo "build os: $(cat /etc/os-release 2>/dev/null | tr '\n' ' ')"
	echo
	echo "keepalived --version:"
	"${ROOT}/usr/sbin/keepalived" --version 2>&1 || true
	echo
	echo "linked libraries:"
	ldd "${ROOT}/usr/sbin/keepalived" 2>&1 || true
	echo
	echo "GLIBC symbol versions required (lowest..highest):"
	objdump -T "${ROOT}/usr/sbin/keepalived" 2>/dev/null \
		| grep -o 'GLIBC_[0-9.]*' | sort -Vu | tr '\n' ' '
	echo
	echo "GLIBCXX/CXXABI symbol versions required:"
	objdump -T "${ROOT}/usr/sbin/keepalived" 2>/dev/null \
		| grep -oE '(GLIBCXX|CXXABI)_[0-9.]*' | sort -Vu | tr '\n' ' '
	echo
} > "${OUT}/BUILD-INFO.txt"

cp "${ROOT}/usr/sbin/keepalived" "${OUT}/keepalived"
tar -C "${ROOT}" -czf "${OUT}/${NAME}.tar.gz" .
sha256sum "${OUT}/${NAME}.tar.gz" "${OUT}/keepalived" > "${OUT}/SHA256SUMS"

chown -R "${HOST_UID:-1001}:${HOST_GID:-1001}" /src/out || true

echo "=== BUILD-INFO.txt ==="
cat "${OUT}/BUILD-INFO.txt"
