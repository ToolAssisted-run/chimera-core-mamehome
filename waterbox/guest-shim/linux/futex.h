/* chimera: asio (MAME's web server, never started in the sandbox) names these
 * for a futex-based mutex it does not use there; the guest's musl sysroot
 * carries no kernel headers. The values are the kernel's. */
#pragma once
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_PRIVATE_FLAG 128
#define FUTEX_WAIT_PRIVATE (FUTEX_WAIT | FUTEX_PRIVATE_FLAG)
#define FUTEX_WAKE_PRIVATE (FUTEX_WAKE | FUTEX_PRIVATE_FLAG)
