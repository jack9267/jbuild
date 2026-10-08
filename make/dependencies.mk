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
DEPLIB := $(DEPS)/Lib/$(PLATFORM)

# Root include tree plus the two explicit subdirs j-dependencies.cmake adds.
INCLUDES += -I$(DEPS)/include -I$(DEPS)/include/mongoose6 -I$(DEPS)/include/lua5.3

# SDL2 headers - the engine includes <SDL_scancode.h> etc. directly. sdl2-config
# finds the active install (source build in /usr/local, or the system package).
INCLUDES += $(shell sdl2-config --cflags 2>/dev/null || pkg-config --cflags sdl2 2>/dev/null)

# Raspberry Pi VideoCore (ARM) - only if present.
ifneq ($(wildcard /opt/vc/include/bcm_host.h),)
  INCLUDES += -I/opt/vc/include -I/opt/vc/include/interface/vcos/pthreads \
              -I/opt/vc/include/interface/vmcs_host/linux
  PI_LDFLAGS := -L/opt/vc/lib
  PI_LDLIBS  := -lopenmaxil -lbcm_host -lvcos -lvchiq_arm
endif

# Link fragments for a consumer that links the deps directly (galactic.mk wraps
# the static ones in its own link group together with Galactic_static).
DEP_LDFLAGS := -L$(DEPLIB) $(PI_LDFLAGS)
DEP_LDLIBS  := -lzlib_static -lbzip2_static -lpng_static -ltinyxml_static \
               -lssl -lcrypto -lSDL2 -ldl -lpthread $(PI_LDLIBS)
