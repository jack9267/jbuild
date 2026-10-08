/* iOS build shim.
 *
 * iOS marks system() unavailable. A couple of scripting standard-library modules call it - Lua's
 * os.execute (loslib.c) and Squirrel's system lib (sqstdsystem.cpp) - and neither is usable on iOS
 * anyway. Pull in the real <stdlib.h> FIRST so its own declaration of system() is processed
 * unmangled, then redirect any later system() *call* to a stub that reports "no shell available".
 * Those functions then fail gracefully instead of referencing the unavailable symbol; nothing else
 * is touched. Force-included only for the libraries that need it (see a Makefile's IOS_NOSYS).
 */
#include <stdlib.h>

static inline int ios_no_system(const char *cmd) { (void)cmd; return -1; }
#define system ios_no_system
