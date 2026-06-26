// Launcher for the "MacM2 IDE.app" bundle.
//
// The IDE binary resolves its toolchain with paths RELATIVE to the working
// directory — `./target/debug/newm2-driver`, `--library library`, the sidebar's
// `library/pimmod` / `library/pimdef`, and help topics under `docs/m2-guide/`.
// When launched from Finder the working directory is `/`, so those would all
// miss. This launcher chdir()s into the bundle's self-contained tool root
// (Contents/Resources/newm2-root, which mirrors that layout) and then exec()s
// the real IDE Mach-O, so every relative path resolves inside the bundle with no
// changes to the IDE itself.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>

int main(int argc, char **argv) {
    char buf[PATH_MAX];
    uint32_t sz = sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) {
        fprintf(stderr, "launcher: executable path too long\n");
        return 70;
    }
    char real[PATH_MAX];
    if (!realpath(buf, real)) {           // resolve symlinks / `..`
        perror("launcher: realpath");
        return 71;
    }

    // real == <App>/Contents/MacOS/<launcher>
    char macos[PATH_MAX];
    snprintf(macos, sizeof(macos), "%s", dirname(real));   // <App>/Contents/MacOS

    char root[PATH_MAX], ide[PATH_MAX];
    snprintf(root, sizeof(root), "%s/../Resources/newm2-root", macos);
    snprintf(ide,  sizeof(ide),  "%s/macide", macos);

    if (chdir(root) != 0) {               // the tool root: relative paths resolve here
        perror("launcher: chdir");
        return 72;
    }

    execv(ide, argv);                     // become the IDE (inherits our argv/env)
    perror("launcher: execv");
    return 127;
}
