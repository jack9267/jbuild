# =============================================================================
#  jbuild/make/spidermonkey.mk - the SpiderMonkey SDK for the JS backend
#
#  Exposes SPIDERMONKEY_INCLUDE for the JSScripting module's extra compile flags:
#
#      $(eval $(call module,JSScripting,JSScripting,$(SPIDERMONKEY_INCLUDE)))
#
#  Build without JS (no SDK needed) by passing JS=0. Non-XP Unix builds use esr60
#  (see cmake/j-spidermonkey.cmake); override with SPIDERMONKEY_VERSION.
#
#  Include AFTER common.mk.
# =============================================================================

JS                   ?= 1
SPIDERMONKEY_VERSION ?= 60

ifeq ($(JS),1)
  ifeq ($(strip $(jspidermonkey_home)),)
    $(error JSScripting is enabled but jspidermonkey_home is not set - set it, or build with 'make JS=0')
  endif
  SPIDERMONKEY        := $(jspidermonkey_home)/esr$(SPIDERMONKEY_VERSION)
  SPIDERMONKEY_INCLUDE := -I$(SPIDERMONKEY)/include
  # mozjs public headers need the platform macro (XP_WIN on Windows; XP_UNIX + XP_DARWIN on Apple).
  # esr140's mozilla/UniquePtrExtensions.h hard-#errors "Unsupported OS?" without it (esr128 did not);
  # XP_DARWIN implies XP_UNIX for mozilla, but set both explicitly. Harmless for older ESRs.
  ifeq ($(HOST_OS),Darwin)
    SPIDERMONKEY_INCLUDE += -DXP_UNIX -DXP_DARWIN
  else
    SPIDERMONKEY_INCLUDE += -DXP_UNIX
  endif
  # Link side, for a consumer that links the JS backend (SMBuild.sh's Unix SDK: lib<name>_static.a under
  # Lib/<platform>/<Config>). CONFIG (debug/release) selects the SDK's Debug/Release subdir. The engine's
  # own in-tree build only compiles JSScripting against the headers, so it needs INCLUDE but not these.
  ifeq ($(CONFIG),debug)
    SPIDERMONKEY_LIBCFG := Debug
  else
    SPIDERMONKEY_LIBCFG := Release
  endif
  SPIDERMONKEY_LDFLAGS := -L$(SPIDERMONKEY)/Lib/$(PLATFORM)/$(SPIDERMONKEY_LIBCFG)
  # Shared vs static. SHARED (default) links the one complete dylib/.so and is strongly preferred:
  # linking the ~764 MB static archive takes MINUTES per link (same pain as the Windows static build),
  # whereas the shared lib links in a blink. The shared lib also already folds in jsrust/ICU/encoding_rs
  # and resolves zlib at its own load time, so the static set's Rust helpers and the bundled-zlib
  # duplicate-symbol clash both disappear. Static is kept for a self-contained build (SPIDERMONKEY_SHARED=0).
  SPIDERMONKEY_SHARED ?= 1
  SPIDERMONKEY_SHAREDLIB := $(firstword $(wildcard \
      $(SPIDERMONKEY)/Lib/$(PLATFORM)/$(SPIDERMONKEY_LIBCFG)/libmozjs-$(SPIDERMONKEY_VERSION).dylib \
      $(SPIDERMONKEY)/Lib/$(PLATFORM)/$(SPIDERMONKEY_LIBCFG)/libmozjs-$(SPIDERMONKEY_VERSION).so))
  ifeq ($(SPIDERMONKEY_SHARED),1)
    SPIDERMONKEY_LDLIBS := -lmozjs-$(SPIDERMONKEY_VERSION)
    # Find the dylib/.so at runtime: beside the exe first (consumers deploy it there), then the SDK dir.
    ifeq ($(HOST_OS),Darwin)
      SPIDERMONKEY_LDFLAGS += -Wl,-rpath,@loader_path -Wl,-rpath,$(SPIDERMONKEY)/Lib/$(PLATFORM)/$(SPIDERMONKEY_LIBCFG)
    else
      SPIDERMONKEY_LDFLAGS += -Wl,-rpath,'$$ORIGIN' -Wl,-rpath,$(SPIDERMONKEY)/Lib/$(PLATFORM)/$(SPIDERMONKEY_LIBCFG)
    endif
  else
    # Static: js_static plus the Rust + helper statics it calls into (jsrust = ICU4X/encoding_rs/bidi,
    # pure_virtual/wrappers). ld64 resolves the cycles without a group; a GNU-ld consumer groups them.
    SPIDERMONKEY_LDLIBS := -lmozjs-$(SPIDERMONKEY_VERSION)_static -ljsrust_static \
                           -lpure_virtual_static -lwrappers_static
  endif
else
  SPIDERMONKEY_INCLUDE :=
  SPIDERMONKEY_LDFLAGS :=
  SPIDERMONKEY_LDLIBS  :=
  SPIDERMONKEY_SHAREDLIB :=
endif
