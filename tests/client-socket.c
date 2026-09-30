/* The official demo socket module also launches an interactive stdin
 * thread. The automated client only needs networking; keep this change
 * isolated to a test module, leaving the official client.so unchanged. */
#include <pthread.h>
#define pthread_create(thread, attr, start, arg) (0)
#include "../lualib-src/lua-clientsocket.c"
