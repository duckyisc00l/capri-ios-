// Runs as soon as the app's code is loaded, before Swift starts.
// If this line never shows up in capri-log.txt, the crash happened while
// iOS (or LiveContainer) was still loading the app's libraries.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

__attribute__((constructor))
static void capri_startup_log(void) {
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/Documents/capri-log.txt", home);
    FILE *f = fopen(path, "a");
    if (!f) return;
    time_t t = time(NULL);
    char when[64];
    strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(f, "\n===== %s  app code loaded (libraries OK) =====\n", when);
    fclose(f);
}
