# =============================================================================
#  jbuild/make/dependencies.mk - the Dependencies sibling tree
#
#  The %jdependencies_home% repo (headers + Lib/<platform> with the vendored
#  static libs: zlib, bzip2, png, tinyxml, lua, mongoose, ...). Appends its
#  headers to INCLUDES and exposes DEP_LDFLAGS / DEP_LDLIBS for linkers.
#
#  Include AFTER common.mk (needs PLATFORM) and before galactic.mk (which folds
#  DEP_LDFLAGS / PI_LDLIBS into the engine link group).
# =============================================================================

DEPS := $(jdependencies_home)
ifeq ($(strip $(DEPS)),)
  $(error jdependencies_home is not set - point it at the Dependencies sibling repo)
endif
# The config subfolder (Debug/Release, from common.mk's CONFIG_DIR) means a debug
# consumer links the debug deps and a release consumer the release ones - the deps
# are built per config, the same as the Windows Lib tree.
DEPLIB := $(DEPS)/Lib/$(PLATFORM)/$(CONFIG_DIR)

# Root include tree plus the two explicit subdirs j-dependencies.cmake adds.
INCLUDES += -I$(DEPS)/include -I$(DEPS)/include/mongoose6 -I$(DEPS)/include/lua5.4

# SDL2 headers - the engine includes <SDL_scancode.h> etc. directly. sdl2-config
# finds the active install (source build in /usr/local, or the system package).
# Not when cross-compiling for Android: those would be the build machine's headers. There the
# Dependencies include tree carries SDL's headers itself.
#
# FreeBSD has OpenSSL in its base system (/usr/include, /usr/lib) but curl and SDL2 are packages
# (ftp/curl, devel/sdl20) under /usr/local, which its compiler does not search by default - on FreeBSD
# itself, or in FREEBSD_SYSROOT with the packages unpacked over base.txz when cross-compiling.
ifeq ($(PLATFORM),freebsd)
FREEBSD_LOCAL := $(FREEBSD_SYSROOT)/usr/local
# -idirafter: searched after every -I, so no package's header there (zlib, png, lua...) takes the place of
# the Dependencies tree's or a repo's own. -D_THREAD_SAFE is what sdl2-config gives there.
INCLUDES += -idirafter $(FREEBSD_LOCAL)/include/SDL2 -idirafter $(FREEBSD_LOCAL)/include -D_THREAD_SAFE
else ifneq ($(PLATFORM),android)
INCLUDES += $(shell sdl2-config --cflags 2>/dev/null || pkg-config --cflags sdl2 2>/dev/null)
endif

# Raspberry Pi VideoCore (ARM) - only if present.
ifneq ($(wildcard /opt/vc/include/bcm_host.h),)
  INCLUDES += -I/opt/vc/include -I/opt/vc/include/interface/vcos/pthreads \
              -I/opt/vc/include/interface/vmcs_host/linux
  PI_LDFLAGS := -L/opt/vc/lib
  PI_LDLIBS  := -lopenmaxil -lbcm_host -lvcos -lvchiq_arm
endif

# TLS: on Linux, LibreSSL from the Dependencies build, static (ssl_static, crypto_static, as macOS has it),
# so a program runs on a machine without the libssl packages, and curl the same way (CURL_LDLIBS, which a
# consumer puts before TLS_LDLIBS).
# FreeBSD keeps its base system's OpenSSL, and Android the libraries it always had.
ifeq ($(HOST_OS),Linux)
  TLS_LDLIBS := -lssl_static -lcrypto_static
  CURL_LDLIBS := -lcurl_static
else
  TLS_LDLIBS := -lssl -lcrypto
  CURL_LDLIBS := -lcurl
endif

# Link fragments for a consumer that links the deps directly (galactic.mk wraps
# the static ones in its own link group together with Galactic_static).
DEP_LDFLAGS := -L$(DEPLIB) $(PI_LDFLAGS)
ifeq ($(PLATFORM),freebsd)
  # The packages' libraries, found again at run time where the package manager put them (its ldconfig
  # path has /usr/local/lib, but a cross-linked binary is checked against the sysroot's).
  DEP_LDFLAGS += -L$(FREEBSD_LOCAL)/lib -Wl,-rpath-link,$(FREEBSD_LOCAL)/lib
endif
DEP_LDLIBS  := -lzlib_static -lbzip2_static -lzstd_static -lpng_static -ljpeg_static -ltinyxml_static \
               $(TLS_LDLIBS) -lSDL2 -ldl -lpthread $(PI_LDLIBS)
