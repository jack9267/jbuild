# =============================================================================
#  jbuild/make/galactic.mk - linking Galactic (engine) and its dependency closure
#
#  Provides the engine-build defines, the headers, and the link group that both
#  Galactic's own in-tree tools and downstream consumers (e.g. a server app) use.
#
#  Downstream (links an INSTALLED Galactic): GALACTIC_HOME defaults to
#  %galactic_home%; its include/ is added to INCLUDES and its Lib/<platform> is
#  the link search path. Galactic's OWN Makefile overrides GALACTIC_LIBDIR to its
#  in-tree $(LIBDIR) so freshly built libs are linked instead.
#
#      GALACTIC_LIBDIR := $(LIBDIR)        # (Galactic's own Makefile only)
#      include $(JBUILD)/make/galactic.mk
#      TOOL_LDFLAGS := $(GALACTIC_LDFLAGS)
#      TOOL_LDLIBS  := $(GALACTIC_LDLIBS)
#      TOOL_DEPS    := $(Galactic_LIB)
#
#  Include AFTER common.mk and dependencies.mk (it folds in DEP_LDFLAGS/PI_LDLIBS).
# =============================================================================

GALACTIC_HOME ?= $(galactic_home)

# The engine's public headers: an installed tree's include/ + Shared/ for a
# downstream consumer, or the source tree's own include/ + Shared/ for Galactic's
# own in-tree build (GALACTIC_HOME unset). The module template adds each module's
# own include/<dir> on top; these are the top-level roots every source needs.
ifneq ($(strip $(GALACTIC_HOME)),)
  INCLUDES += -I$(GALACTIC_HOME)/include -I$(GALACTIC_HOME)/Shared
else
  INCLUDES += -Iinclude -IShared
endif

# Where the Galactic_static + friends .a files are found. Installed tree by
# default; Galactic's own Makefile points this at its in-tree $(LIBDIR). The
# Debug/Release subfolder (common.mk's CONFIG_DIR) keeps the two configs apart,
# matching the Windows Lib tree, so a debug build links the debug engine libs.
GALACTIC_LIBDIR ?= $(GALACTIC_HOME)/Lib/$(PLATFORM)/$(CONFIG_DIR)

# Global defines from src/CMakeLists.txt (minus -DGALACTIC_PLATFORM_WINDOWS),
# needed whenever engine headers are compiled against.
DEFINES_EXTRA += -DGALACTIC_OPENSSL=1 -DCURL_STATICLIB -DSDL2_STATIC -DRMLUI_STATIC_LIB

# The engine link group: Galactic_static and the static deps it calls into, plus the shared system
# libs. DEP_LDFLAGS / PI_LDLIBS come from dependencies.mk. The dependency statics (zlib/bzip2/png/
# tinyxml) come from the Dependencies build; ssl/crypto/SDL2 from wherever the caller's -L points.
GALACTIC_LDFLAGS := -L$(GALACTIC_LIBDIR) $(DEP_LDFLAGS)
ifeq ($(HOST_OS),Darwin)
  # ld64 resolves archives without --start-group; there is no libdl (dlopen lives in libSystem) and
  # pthread is in libSystem. A static SDL2 pulls in these system frameworks; an unused -framework /
  # -l is harmless, so listing them keeps both the headless tools and a windowed consumer linking.
  # SDL2 / ssl / crypto come from the Dependencies build too (static, so _static), making the macOS
  # build self-contained - no Homebrew/vcpkg. A static SDL2 pulls in these system frameworks; an
  # unused -framework / -l is harmless, so listing them keeps both the headless tools and a windowed
  # consumer linking.
  GALACTIC_LDLIBS := -lGalactic_static -lzlib_static -lbzip2_static -lpng_static -ltinyxml_static \
                     -lssl_static -lcrypto_static -lSDL2_static \
                     -framework Cocoa -framework IOKit -framework CoreVideo -framework CoreAudio \
                     -framework AudioToolbox -framework ForceFeedback -framework Carbon \
                     -framework Metal -framework GameController -framework CoreHaptics -liconv
else
  GALACTIC_LDLIBS := -Wl,--start-group \
                       -lGalactic_static -lzlib_static -lbzip2_static -lpng_static -ltinyxml_static \
                     -Wl,--end-group \
                     -lssl -lcrypto -lSDL2 -ldl -lpthread $(PI_LDLIBS)
endif
