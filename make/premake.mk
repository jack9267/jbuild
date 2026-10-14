# =============================================================================
#  jbuild/make/premake.mk - a repo's Makefile when premake5.lua says what it builds
#
#  premake5.lua is the one list of libraries, sources, include dirs and defines - Windows generates
#  its solution from it - and `premake5 --os=<target> jbuildmake` writes the part of it for one
#  target as .jbuild/make/<target>.mk: a deplib per static library, and the `headers` target
#  (headers_project). Nothing generated is committed. A repo's whole Makefile is then
#
#      JBUILD ?= jbuild
#      include $(JBUILD)/make/premake.mk
#
#  Targets (make help): make / make debug / make release / make libs / make headers / make clean.
#  Output: Lib/<platform>/<Debug|Release>/lib<name>_static.a, and include/.
# =============================================================================

include $(JBUILD)/make/common.mk

# Third-party code: warnings off (not ours), -fPIC for PIE consumers, C++17 for the C++ libraries,
# -MMD -MP for header dependency tracking. common.mk's engine-tuned CXXFLAGS does not apply here, so
# CFLAGS/CXXFLAGS are defined outright; a repo may set either again after this include.
ifeq ($(CONFIG),debug)
  OPT := -g -O0
else
  OPT := -O2
endif
# SANITIZE: optional -fsanitize=... folded into every compile (empty by default). Used to build under
# AddressSanitizer for debugging a consumer's heap bug; harmless/empty for normal builds.
SANITIZE  ?=
BASEFLAGS := -fPIC -pthread -w -MMD -MP $(OPT) $(APPLE_FLAGS) $(SANITIZE)
# GCC 14+ promoted these C diagnostics to errors by default; vendored C (old zlib etc. missing a
# feature-test macro for POSIX calls) needs them back to warnings. Harmless on older GCC, where they
# are warnings already.
C_PERMISSIVE := -Wno-error=implicit-function-declaration -Wno-error=implicit-int \
                -Wno-error=int-conversion -Wno-error=incompatible-pointer-types
CFLAGS    := $(BASEFLAGS) $(C_PERMISSIVE)
# -Dregister= strips the `register` keyword that old C++ (RakNet) still uses - removed in C++17,
# which clang rejects as a hard error (GCC only warned). Harmless everywhere else.
CXXFLAGS  := -std=c++17 -Dregister= $(BASEFLAGS)

# ---- object pattern rules (compiler chosen by extension) -------------------
# The object keeps the source extension (foo.c.o / foo.m.o) so a .c and a .m - or .cpp and .mm - of
# the same stem never collide. .m is Objective-C (CC), .mm is Objective-C++ (CXX); both are Apple.
$(OBJROOT)/%.c.o: %.c
	@mkdir -p $(dir $@)
	$(ECHO) '$(_C_CXX)[CC]$(_C_OFF) %s\n' '$<'
	$(Q)$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(OBJROOT)/%.cpp.o: %.cpp
	@mkdir -p $(dir $@)
	$(ECHO) '$(_C_CXX)[CXX]$(_C_OFF) %s\n' '$<'
	$(Q)$(CXX) $(CXXFLAGS) $(CPPFLAGS) -c $< -o $@

$(OBJROOT)/%.m.o: %.m
	@mkdir -p $(dir $@)
	$(ECHO) '$(_C_CXX)[OBJC]$(_C_OFF) %s\n' '$<'
	$(Q)$(CC) $(CFLAGS) -fobjc-arc $(CPPFLAGS) -c $< -o $@

$(OBJROOT)/%.mm.o: %.mm
	@mkdir -p $(dir $@)
	$(ECHO) '$(_C_CXX)[OBJCXX]$(_C_OFF) %s\n' '$<'
	$(Q)$(CXX) $(CXXFLAGS) $(CPPFLAGS) -c $< -o $@

# ---- static-library template -----------------------------------------------
# $(call deplib,<name>,<sources>,<include flags>,<defines>) - what the fragment calls for each library.
# Each source builds via the rules above; the library's own include flags and defines are applied to
# its objects through a target-specific CPPFLAGS.
define deplib
$(1)_OBJS := $$(patsubst %,$$(OBJROOT)/%.o,$(2))
$(1)_LIB  := $$(LIBDIR)/lib$(1)_static.a
ALL_OBJS += $$($(1)_OBJS)
LIB_TARGETS += $$($(1)_LIB)
$$($(1)_OBJS): CPPFLAGS += $(3) $(4)
$$($(1)_LIB): $$($(1)_OBJS)
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_AR)[AR]$(_C_OFF) %s\n' '$$(@F)'
	$(Q)$$(AR) rcs $$@ $$^
endef

# ---- the fragment ----------------------------------------------------------
# Written whenever it is missing or older than the premake scripts (make rebuilds an included makefile,
# then starts again with it), fetching the pinned premake first if it has to (premake.sh). Linux and
# FreeBSD build the same set.
ifeq ($(PLATFORM),macos)
  MAKE_FRAGMENT := macosx
else ifneq (,$(filter ios ios-sim,$(PLATFORM)))
  MAKE_FRAGMENT := ios
else ifeq ($(PLATFORM),android)
  MAKE_FRAGMENT := android
else
  MAKE_FRAGMENT := linux
endif
MAKE_FRAGMENT_FILE := .jbuild/make/$(MAKE_FRAGMENT).mk
-include $(MAKE_FRAGMENT_FILE)

$(MAKE_FRAGMENT_FILE): premake5.lua $(wildcard $(JBUILD)/premake/*.lua)
	$(ECHO) '$(_C_LINK)[PREMAKE]$(_C_OFF) %s\n' '$@'
	$(Q)PREMAKE=$$(sh $(JBUILD)/make/premake.sh) && "$$PREMAKE" --file=premake5.lua --os=$(MAKE_FRAGMENT) jbuildmake > /dev/null
	@touch $@   # premake leaves an unchanged file as it was, which would leave it out of date for ever

# ---- top-level targets -----------------------------------------------------
.DEFAULT_GOAL := all
.PHONY: all libs debug release clean help

all: libs headers
libs: $(LIB_TARGETS)

debug:
	@$(MAKE) --no-print-directory CONFIG=debug all
release:
	@$(MAKE) --no-print-directory CONFIG=release all

# Removes this platform's intermediate objects, both config output trees and the assembled include/.
# Leaves any Windows Lib\<plat>\<toolset>\ tree alone.
clean:
	rm -rf .jbuild/make/$(PLATFORM) include
	rm -rf Lib/$(PLATFORM)/Debug Lib/$(PLATFORM)/Release

help:
	@echo '$(notdir $(CURDIR)) - the static libraries premake5.lua names for this target.'
	@echo
	@echo 'Targets:'
	@echo '  make            release build: static libs + the assembled include/ tree'
	@echo '  make debug      debug build (-g -O0)'
	@echo '  make release    release build (-O2)'
	@echo '  make libs       the libraries alone; make headers, include/ alone'
	@echo '  make clean      remove this platform build artifacts (both configs) + include/'
	@echo
	@echo 'Output (per config, matching the Windows Lib tree):'
	@echo '  static libs -> Lib/<platform>/<Debug|Release>/lib<name>_static.a'
	@echo '  headers     -> include/'
	@echo
	@echo 'This run: PLATFORM=$(PLATFORM)  CONFIG=$(CONFIG)  ->  $(LIBDIR)'

-include $(ALL_OBJS:.o=.d)
