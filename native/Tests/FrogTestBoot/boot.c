// Swift has no code that runs when a bundle loads, so this C constructor starts
// FrogTestSupport's on-screen guard before XCTest runs the first test.
extern void frog_test_boot(void) __attribute__((weak));

__attribute__((constructor)) static void frog_test_boot_on_load(void) {
    if (frog_test_boot) frog_test_boot();
}
