#!/bin/sh
# Prints the path of the pinned premake5 for this machine, fetching it into jbuild/tools/premake/ (not
# committed) the first time. The version is pinned, not "latest": premake 5 is a beta whose releases
# have renamed and removed what jbuild's Lua calls, so a change of version is made here, on purpose.
#
# premake publishes macOS and Linux x86_64 builds, checked against the SHA-256 below; anywhere else
# (FreeBSD, Linux on ARM) it is built from the release's source, as premake documents.
set -e

VERSION=5.0.0-beta8
SHA_MACOSX=fa73a46f093fa6f17494a3d063421aa6cae3ea825a61c62dd59fc2f07a256d03
SHA_MACOSX_X64=84b5fa5a432dcebdc3dd12e8677d10e38e5b32a3fe06d83ae68967e4f5e2db8a
SHA_LINUX=63edd3e7461eebdd45b500a3c7e8ad4e7a67d68f230010f9a97cbb71b4ec59c8

JBUILD_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$JBUILD_ROOT/tools/premake/$VERSION"
BIN="$DIR/premake5"

if [ -x "$BIN" ]; then
	echo "$BIN"
	exit 0
fi

download() {
	if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
	elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
	elif command -v fetch >/dev/null 2>&1; then fetch -q -o "$2" "$1"
	else echo "premake.sh: no curl, wget or fetch to download premake with" >&2; exit 1
	fi
}

sha256() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else sha256 -q "$1"
	fi
}

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64)  ASSET=macosx;     SHA=$SHA_MACOSX ;;
	Darwin-x86_64) ASSET=macosx-x64; SHA=$SHA_MACOSX_X64 ;;
	Linux-x86_64)  ASSET=linux;      SHA=$SHA_LINUX ;;
	*)             ASSET= ;;
esac

mkdir -p "$DIR"
WORK=$(mktemp -d "$DIR/fetch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [ -n "$ASSET" ]; then
	echo "premake.sh: fetching premake $VERSION ($ASSET)" >&2
	download "https://github.com/premake/premake-core/releases/download/v$VERSION/premake-$VERSION-$ASSET.tar.gz" "$WORK/premake.tar.gz"
	GOT=$(sha256 "$WORK/premake.tar.gz")
	if [ "$GOT" != "$SHA" ]; then
		echo "premake.sh: premake-$VERSION-$ASSET.tar.gz has SHA-256 $GOT, expected $SHA" >&2
		exit 1
	fi
	tar -xzf "$WORK/premake.tar.gz" -C "$WORK"
	mv "$WORK/premake5" "$BIN"
else
	# No published build for this machine. GitHub's tag archive is not byte-stable, so there is no
	# checksum to hold it to; it is what premake's own instructions build from.
	case "$(uname -s)" in
		FreeBSD|OpenBSD|NetBSD) PLATFORM=bsd ;;
		Darwin)                 PLATFORM=osx ;;
		*)                      PLATFORM=linux ;;
	esac
	if command -v gmake >/dev/null 2>&1; then GMAKE=gmake; else GMAKE=make; fi
	echo "premake.sh: building premake $VERSION from source ($PLATFORM) - once, it takes a while" >&2
	download "https://github.com/premake/premake-core/archive/refs/tags/v$VERSION.tar.gz" "$WORK/src.tar.gz"
	tar -xzf "$WORK/src.tar.gz" -C "$WORK"
	(cd "$WORK/premake-core-$VERSION" && $GMAKE -f Bootstrap.mak "$PLATFORM" >&2)
	mv "$WORK/premake-core-$VERSION/bin/release/premake5" "$BIN"
fi

chmod +x "$BIN"
echo "$BIN"
