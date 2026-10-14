#!/bin/sh
# BuildAll.bat's counterpart off Windows: the consuming repo's Makefile, Release and Debug, for every
# target this machine can build - macOS, plus iOS and its simulator where Xcode's SDKs are, or the
# native build elsewhere; Android too when ANDROID_NDK (or ANDROID_NDK_HOME) is set. A repo's
# BuildAll.sh is one line calling this from its root.
set -e

# The Makefiles are GNU make's; FreeBSD's own make is not.
if command -v gmake >/dev/null 2>&1; then MAKE=gmake; else MAKE=make; fi
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

build() {
	for config in release debug; do
		echo "== ${*:-native} $config"
		$MAKE -j"$JOBS" CONFIG=$config "$@"
	done
}

case "$(uname -s)" in
	Darwin)
		build TARGET=macos
		if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
			build TARGET=ios
			build TARGET=ios-sim
		else
			echo "== no iOS SDK (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer finds it) - iOS skipped"
		fi
		;;
	*)
		build
		;;
esac

if [ -n "${ANDROID_NDK:-$ANDROID_NDK_HOME}" ]; then
	build TARGET=android
else
	echo "== no ANDROID_NDK - Android skipped"
fi
