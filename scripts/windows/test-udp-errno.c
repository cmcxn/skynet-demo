/* Regression: Winsock would-block must be translated for Skynet's UDP loop. */
#include "compat.h"
#include <stdio.h>
#include <errno.h>

int main(void) {
    WSADATA startup;
    if (WSAStartup(MAKEWORD(2, 2), &startup) != 0) return 1;
    SOCKET fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd == INVALID_SOCKET) return 1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) return 1;
    u_long nonblocking = 1;
    if (ioctlsocket(fd, FIONBIO, &nonblocking) != 0) return 1;
    char buffer[16];
    int length = sizeof(address);
    errno = 0;
    int received = recvfrom(fd, buffer, sizeof(buffer), 0, (struct sockaddr *)&address, &length);
    int error = errno;
    closesocket(fd);
    WSACleanup();
    if (received != -1 || error != EAGAIN) {
        fprintf(stderr, "FAIL: UDP would-block result=%d errno=%d expected=%d\n", received, error, EAGAIN);
        return 1;
    }
    puts("PASS: Windows UDP would-block maps to EAGAIN");
    return 0;
}
