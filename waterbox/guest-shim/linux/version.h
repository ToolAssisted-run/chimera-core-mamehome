/* chimera: asio (MAME's web server, emu/http.cpp) asks the kernel headers'
 * version to decide which Linux interfaces it may use. The guest's musl
 * sysroot carries no kernel headers, and the server is never started in the
 * sandbox: any recent version will do for the declarations it compiles. */
#pragma once
#define LINUX_VERSION_CODE 0x050a00
#define KERNEL_VERSION(a, b, c) (((a) << 16) + ((b) << 8) + (c))
