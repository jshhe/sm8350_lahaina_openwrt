#include <stdio.h>
#include <dlfcn.h>

int main(void) {
    const char *libs[] = {
        "/vendor/lib64/libqmi_cci.so",
        "/vendor/lib64/libqmiservices.so",
        "/vendor/lib64/libdiag.so",
        "/vendor/lib64/libqmi.so",
        NULL
    };
    for (int i = 0; libs[i]; i++) {
        void *h = dlopen(libs[i], RTLD_NOW);
        printf("%s -> %p (%s)\n", libs[i], h, h ? "ok" : dlerror());
    }
    return 0;
}
