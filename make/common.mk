# =============================================================================
#  jbuild/make/common.mk - generic Unix/Linux build machinery
#
#  The project-agnostic half of Galactic's hand-written Makefile: toolchain,
#  debug/release config, platform (bitness) detection, the common compile flags,
#  and the reusable module / tool / split_debug / finalize templates. A consuming
#  Makefile includes this, then the dependency / engine .mk files it needs, then
#  declares only what it builds:
#
#      JBUILD ?= jbuild
#      include $(JBUILD)/make/common.mk
#      include $(JBUILD)/make/dependencies.mk
#      include $(JBUILD)/make/galactic.mk
#
#      $(eval $(call module,Engine,Galactic,-DENGINE_BUILDING=1))
#      $(eval $(call tool,hbfmodel))
#      $(eval $(call finalize))
#
#  Conventions (Galactic's, kept): module sources live under $(SRCROOT)/<dir>
#  with headers under $(INCROOT)/<dir>; tool sources under $(SRCROOT)/Tools/<name>.
#  Override SRCROOT / INCROOT before the first $(call ...) for a different layout.
#
#  Output layout:
#    - static libraries -> Lib/<platform>/<Debug|Release>/lib<Name>_static.a (no _d suffix;
#      the config, not the name, separates the two - matching the Windows Lib tree)
#    - tools            -> $(BINDIR)/<name>[_d]          (_d = debug)
#      each tool stripped with its debug info split to <name>[_d].debug beside it
#      (the Linux PDB equivalent), unless SYMBOLS=keep.
# =============================================================================

# ---- config ----------------------------------------------------------------
CONFIG  ?= release
SYMBOLS ?= split

CC      ?= cc
CXX     ?= c++
AR      ?= ar
OBJCOPY ?= objcopy
STRIP   ?= strip

# Source/header roots (override before the first $(call module,...)).
SRCROOT ?= src
INCROOT ?= include

# ---- platform / target -----------------------------------------------------
# On Apple, TARGET picks macOS / iOS device / iOS simulator and drives the SDK
# sysroot, min-OS flag and architectures; universal output comes from passing
# several -arch in one clang call (the objects, and so the .a, are fat - no lipo
# step). Elsewhere, PLATFORM is the bitness (aarch64 and x86_64 both map to x64).
#   make TARGET=macos           universal arm64 + x86_64 (default on macOS)
#   make TARGET=ios             arm64 device
#   make TARGET=ios-sim         arm64 + x86_64 simulator
#   APPLE_ARCHS="arm64" ...      override the architecture list
HOST_OS := $(shell uname -s)
TARGET  ?= native

ifeq ($(HOST_OS),Darwin)
  ifeq ($(TARGET),ios)
    PLATFORM     := ios
    APPLE_SDK    := iphoneos
    APPLE_ARCHS  ?= arm64
    APPLE_MINVER := -miphoneos-version-min=15.0
  else ifeq ($(TARGET),ios-sim)
    PLATFORM     := ios-sim
    APPLE_SDK    := iphonesimulator
    APPLE_ARCHS  ?= arm64 x86_64
    APPLE_MINVER := -mios-simulator-version-min=15.0
  else
    PLATFORM     := macos
    APPLE_SDK    := macosx
    APPLE_ARCHS  ?= arm64 x86_64
    APPLE_MINVER := -mmacosx-version-min=13.0
  endif
  # DEVELOPER_DIR (set by the caller to point at Xcode) reaches the iOS SDKs that
  # the Command Line Tools alone do not carry.
  APPLE_SYSROOT := $(shell xcrun --sdk $(APPLE_SDK) --show-sdk-path 2>/dev/null)
  APPLE_FLAGS   := $(addprefix -arch ,$(APPLE_ARCHS)) -isysroot $(APPLE_SYSROOT) $(APPLE_MINVER)
else
  LONG_BIT := $(shell getconf LONG_BIT 2>/dev/null)
  ifeq ($(LONG_BIT),32)
    PLATFORM := x86
  else
    PLATFORM := x64
  endif
  APPLE_FLAGS :=
endif

# ---- output layout ---------------------------------------------------------
# CONFIG_DIR is the capitalised Debug/Release leaf, matching the Windows Lib tree
# (Lib\<arch>\<toolset>_static\<Debug|Release>) and SpiderMonkey's own Lib layout, so
# debug and release outputs never overwrite each other and a consumer links its
# own config's libraries (see dependencies.mk / galactic.mk).
ifeq ($(CONFIG),debug)
  CONFIG_DIR := Debug
else
  CONFIG_DIR := Release
endif

LIBDIR  ?= Lib/$(PLATFORM)/$(CONFIG_DIR)
BINDIR  ?= Bin/$(PLATFORM)
OBJROOT ?= .jbuild/make/$(PLATFORM)/$(CONFIG)

ifeq ($(CONFIG),debug)
  DBG_POSTFIX := _d
else
  DBG_POSTFIX :=
endif

# ---- flags -----------------------------------------------------------------
# C++17, no GNU extensions. -fPIC so the static libs link into a PIE executable
# / shared object (the modern Debian default). -MMD -MP emit header dependency
# files so edits trigger the right rebuilds.
CXXFLAGS_COMMON := -std=c++17 -fPIC -pthread -Wno-deprecated-declarations -MMD -MP
# Modern libstdc++ (GCC 13+/Trixie) dropped transitive <cstdint>, so headers using
# uint64_t without including it fail; force-include it. Harmless on older toolchains.
CXXFLAGS_COMMON += -include cstdint
# Apple SDK/arch flags (empty off Apple) - the sysroot, min-OS and -arch list.
CXXFLAGS_COMMON += $(APPLE_FLAGS)

ifeq ($(CONFIG),debug)
  CXXFLAGS_CONFIG := -g -O0
  DEFINES_CONFIG  := -DDEBUG=1
else
  CXXFLAGS_CONFIG := -O2 -g1 -fvisibility=hidden -fdata-sections -ffunction-sections
  DEFINES_CONFIG  :=
endif

# Hooks the dependency / engine .mk files and the project append to. INCLUDES,
# DEFINES_* and CXXFLAGS_EXTRA may all be set AFTER this include - CXXFLAGS is
# deferred (=) so it still picks them up.
INCLUDES       ?=
DEFINES_COMMON ?=
DEFINES_EXTRA  ?=
CXXFLAGS_EXTRA ?=
# Extra linker flags for the tool template (e.g. -L for an SDL2/openssl provided outside the
# dependency tree - vcpkg or Homebrew on macOS). Empty by default.
LDFLAGS_EXTRA  ?=
# Source files the module template must skip (repo-relative paths), for sources that exist but are
# dead on this platform - e.g. the engine's FileMgr.mm / StringManager.mm, dead on Apple. Empty by
# default; set before the first $(call module,...).
EXCLUDE_SRCS   ?=

CXXFLAGS = $(CXXFLAGS_COMMON) $(CXXFLAGS_CONFIG) $(DEFINES_COMMON) $(DEFINES_CONFIG) \
           $(DEFINES_EXTRA) $(CXXFLAGS_EXTRA) $(INCLUDES)

# Link inputs the tool template consumes; filled in by galactic.mk (or the project).
TOOL_LDFLAGS ?=
TOOL_LDLIBS  ?=
TOOL_DEPS    ?=

# Accumulators the templates append to and finalize reads.
ALL_OBJS     :=
LIB_TARGETS  :=
TOOL_TARGETS :=

# ---- pretty output ---------------------------------------------------------
# Concise, colorized per-file output like CMake's Makefile generator: a short green [CXX]/[OBJCXX],
# cyan [AR], blue [LINK] tag per step instead of the full command line. VERBOSE=1 shows the full
# commands instead (for debugging); defining NO_COLOR drops the ANSI codes (for CI logs / dumb terminals).
#   $(ECHO) is `printf` normally and `true` (a no-op that swallows its args) under VERBOSE, so the same
#   recipe line both prints the tag and vanishes when the raw command is shown instead; $(Q) silences
#   the command (`@`) normally and shows it under VERBOSE.
VERBOSE ?= 0
ifeq ($(VERBOSE),1)
  Q    :=
  ECHO := @true
else
  Q    := @
  ECHO := @printf
endif
ifeq ($(origin NO_COLOR),undefined)
  _C_CXX  := \033[0;32m
  _C_AR   := \033[0;36m
  _C_LINK := \033[1;34m
  _C_OFF  := \033[0m
else
  _C_CXX  :=
  _C_AR   :=
  _C_LINK :=
  _C_OFF  :=
endif

# ---- split_debug -----------------------------------------------------------
# Split debug info out of a freshly-linked binary into a <binary>.debug sidecar
# (the Linux PDB equivalent): --only-keep-debug saves it, strip leans the binary,
# --add-gnu-debuglink stamps it so gdb/addr2line find it. SYMBOLS=keep skips this.
ifeq ($(HOST_OS),Darwin)
# macOS keeps DWARF in the .o files; dsymutil collects it into a <binary>.dSYM bundle beside the binary
# - the .pdb / .debug-sidecar equivalent, and what lldb/atos look for. SYMBOLS=keep leaves it in the
# objects only (no .dSYM produced).
ifeq ($(SYMBOLS),split)
define split_debug
	dsymutil $(1)
endef
else
define split_debug
endef
endif
else ifeq ($(SYMBOLS),split)
define split_debug
	$(OBJCOPY) --only-keep-debug $(1) $(1).debug
	$(STRIP) --strip-debug --strip-unneeded $(1)
	$(OBJCOPY) --add-gnu-debuglink=$(1).debug $(1)
endef
else
define split_debug
endef
endif

# Source extensions a module compiles: C++ everywhere, plus Obj-C++ (.mm) on Apple, where parts of
# the engine (Context.mm, AppleSettings.mm, ...) are Objective-C++. clang compiles .mm as Obj-C++.
ifeq ($(HOST_OS),Darwin)
  MODULE_FIND := \( -name '*.cpp' -o -name '*.mm' \)
else
  MODULE_FIND := -name '*.cpp'
endif

# ---- static library template -----------------------------------------------
# $(call module,<dir under SRCROOT>,<lib base name>,<extra compile flags>)
# Every lib defines ENGINE_STATIC=1 and adds its own $(INCROOT)/<dir> and
# $(SRCROOT)/<dir> (the latter holds pch.h - a normal header off MSVC).
define module
$(2)_SRCS := $$(filter-out $$(EXCLUDE_SRCS),$$(shell find $$(SRCROOT)/$(1) $(MODULE_FIND)))
# Keep the source extension in the object name (Context.cpp.o / Context.mm.o) so a .cpp and a .mm of
# the same stem - e.g. the engine's Context.cpp + Context.mm - do not collide to one Context.o.
$(2)_OBJS := $$(patsubst $$(SRCROOT)/%,$$(OBJROOT)/%.o,$$($(2)_SRCS))
$(2)_LIB  := $$(LIBDIR)/lib$(2)_static.a
ALL_OBJS += $$($(2)_OBJS)
LIB_TARGETS += $$($(2)_LIB)

$$(OBJROOT)/$(1)/%.cpp.o: $$(SRCROOT)/$(1)/%.cpp
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_CXX)[CXX]$(_C_OFF) %s\n' '$$<'
	$(Q)$$(CXX) $$(CXXFLAGS) -DENGINE_STATIC=1 $(3) -I$$(INCROOT)/$(1) -I$$(SRCROOT)/$(1) -c $$< -o $$@

$$(OBJROOT)/$(1)/%.mm.o: $$(SRCROOT)/$(1)/%.mm
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_CXX)[OBJCXX]$(_C_OFF) %s\n' '$$<'
	$(Q)$$(CXX) $$(CXXFLAGS) -DENGINE_STATIC=1 $(3) -I$$(INCROOT)/$(1) -I$$(SRCROOT)/$(1) -c $$< -o $$@

$$($(2)_LIB): $$($(2)_OBJS)
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_AR)[AR]$(_C_OFF) %s\n' '$$(@F)'
	$(Q)$$(AR) rcs $$@ $$^
endef

# ---- tool template ---------------------------------------------------------
# $(call tool,<name under SRCROOT/Tools>)
# Links $(TOOL_LDFLAGS)/$(TOOL_LDLIBS) (from galactic.mk) and depends on
# $(TOOL_DEPS) (e.g. the in-tree Galactic lib), then splits its debug info.
define tool
$(1)_SRCS := $$(shell find $$(SRCROOT)/Tools/$(1) -name '*.cpp')
$(1)_OBJS := $$(patsubst $$(SRCROOT)/Tools/$(1)/%.cpp,$$(OBJROOT)/Tools/$(1)/%.o,$$($(1)_SRCS))
$(1)_BIN  := $$(BINDIR)/$(1)$$(DBG_POSTFIX)
ALL_OBJS += $$($(1)_OBJS)
TOOL_TARGETS += $$($(1)_BIN)

$$(OBJROOT)/Tools/$(1)/%.o: $$(SRCROOT)/Tools/$(1)/%.cpp
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_CXX)[CXX]$(_C_OFF) %s\n' '$$<'
	$(Q)$$(CXX) $$(CXXFLAGS) -DENGINE_STATIC=1 -I$$(SRCROOT)/Tools/$(1) -c $$< -o $$@

$$($(1)_BIN): $$($(1)_OBJS) $$(TOOL_DEPS)
	@mkdir -p $$(dir $$@)
	$(ECHO) '$(_C_LINK)[LINK]$(_C_OFF) %s\n' '$$(@F)'
	$(Q)$$(CXX) $$(CXXFLAGS_CONFIG) $(APPLE_FLAGS) $$($(1)_OBJS) $$(TOOL_LDFLAGS) $$(TOOL_LDLIBS) $$(LDFLAGS_EXTRA) -o $$@
	$$(call split_debug,$$@)
endef

# ---- top-level targets -----------------------------------------------------
# $(call finalize) - call once, AFTER every $(call module,...)/$(call tool,...),
# so LIB_TARGETS/TOOL_TARGETS/ALL_OBJS are complete.
define finalize
.DEFAULT_GOAL := all
.PHONY: all libs tools debug release clean help

all: libs tools
libs: $$(LIB_TARGETS)
tools: $$(TOOL_TARGETS)

debug:
	@$$(MAKE) --no-print-directory CONFIG=debug all
release:
	@$$(MAKE) --no-print-directory CONFIG=release all

# Remove only this platform's Unix outputs (both config trees) - never a Windows
# Lib/<plat>/<toolset>/ tree, so only the Debug/Release leaves are taken.
clean:
	rm -rf .jbuild/make/$$(PLATFORM)
	rm -rf Lib/$$(PLATFORM)/Debug Lib/$$(PLATFORM)/Release
	rm -rf $$(BINDIR)

help:
	@echo 'Targets: make [all] | debug | release | clean | help'
	@echo 'Output : static libs -> Lib/<platform>/<Debug|Release>/lib<name>_static.a'
	@echo '         tools       -> $$(BINDIR)/<name>[_d]'
	@echo 'This run: PLATFORM=$$(PLATFORM)  CONFIG=$$(CONFIG)  ->  $$(LIBDIR)'

-include $$(ALL_OBJS:.o=.d)
endef
