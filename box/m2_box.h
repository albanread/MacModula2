/* m2_box.h -- Modula-2 for the BOX: the compiler and runtime as a static
 * library (libm2-box.a) for /init.  MacModula2's box/ (design/BOX_PORT.md);
 * rosgd's modules/modula2 is its one user.
 *
 * The library knows nothing of RISC OS: it is given hooks.  One run at a
 * time; m2_box_end_run after each (or m2_box_recover after a fault). */
#ifndef M2_BOX_H
#define M2_BOX_H
#include <stddef.h>
#include <stdint.h>

struct m2_box_hooks {
    /* bytes for the VDU (Latin-1, "\n" a new line) */
    void (*write)(const char *p, size_t n);
    /* a line of input without its terminator: its length, or -1 at the
     * end of the input */
    long (*read)(char *buf, size_t max);
    /* SWI number (the X form) with r[0..9] in and out; *flags gets N Z C V
     * as bits 3-0.  An error: its number in *errnum and its block's RISC OS
     * address returned; else 0 */
    uint32_t (*swi)(uint32_t number, uint32_t r[10], uint32_t *flags, uint32_t *errnum);
    /* a SWI's number from its name: 0 if it is known, else -1 */
    int (*swi_number)(const char *name, uint32_t *number);
    /* a RISC OS file's bytes, malloc'd (*n its length), or NULL */
    char *(*file_load)(const char *name, size_t *n);
    /* 0 nothing, 1 a file, 2 a directory */
    int (*file_kind)(const char *name);
    /* grows the run's dynamic area by n bytes: the old end (a RISC OS
     * address), or 0.  The area is the module's to remove after the run */
    size_t (*arena_grow)(size_t n);
};

void m2_box_set_hooks(const struct m2_box_hooks *h);
/* the standard library's directory (a Linux path); NULL: /usr/lib/modula2 */
void m2_box_set_library(const char *dir);

#define M2_COMPILE_ONLY 1u
#define M2_TIMES        2u
#define M2_DEBUG        4u   /* the JIT's sections and entry points written */
#define M2_OPT(n)       ((uint32_t)((n) + 1) << 4)
/* Compiles and runs the program module `name` (a RISC OS name), argv[1..]
 * its arguments: its exit code (HALT's), or -1 it did not compile (errors
 * written), -3 it could not be started, -5 it stopped with an exception
 * (written) */
int m2_box_run(const char *name, int argc, const char *const *argv, uint32_t flags);
/* Escape: the program ends (as HALT) at its next output, input or SWI */
void m2_box_stop(void);
/* after a fault jumped out of m2_box_run */
void m2_box_recover(void);
/* after every run */
void m2_box_end_run(void);
#endif
