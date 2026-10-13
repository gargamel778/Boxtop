/*
 * 64-bit interface counters and process arguments.
 * Ported from btop src/osx/btop_collect.cpp (Net::collect, Proc::collect) — Copyright 2021 Aristocratos, Apache-2.0.
 */
#include "CSysInfo.h"

#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

int bt_net_counters(bt_ifstat *out, int max) {
    int mib[] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) return -1;
    char *buf = malloc(len);
    if (!buf) return -1;
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
        free(buf);
        return -1;
    }
    int n = 0;
    char *lim = buf + len;
    for (char *next = buf; next < lim && n < max;) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) break;
        next += ifm->ifm_msglen;
        if (ifm->ifm_type != RTM_IFINFO2) continue;
        struct if_msghdr2 *if2m = (struct if_msghdr2 *)ifm;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)(if2m + 1);
        size_t nlen = sdl->sdl_nlen < sizeof(out[n].name) - 1 ? sdl->sdl_nlen : sizeof(out[n].name) - 1;
        memset(out[n].name, 0, sizeof(out[n].name));
        memcpy(out[n].name, sdl->sdl_data, nlen);
        out[n].ibytes = if2m->ifm_data.ifi_ibytes;
        out[n].obytes = if2m->ifm_data.ifi_obytes;
        out[n].flags = (uint32_t)if2m->ifm_flags;
        out[n].baudrate = if2m->ifm_data.ifi_baudrate;
        n++;
    }
    free(buf);
    return n;
}

int bt_proc_args(pid_t pid, char *buf, int buflen) {
    static int argmax = 0;
    if (argmax == 0) {
        int mib[] = { CTL_KERN, KERN_ARGMAX };
        size_t size = sizeof(argmax);
        if (sysctl(mib, 2, &argmax, &size, NULL, 0) != 0 || argmax <= 0) argmax = 1 << 18;
    }
    if (!buf || buflen <= 1) return -1;

    char *procargs = malloc((size_t)argmax);
    if (!procargs) return -1;
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = (size_t)argmax;
    if (sysctl(mib, 3, procargs, &size, NULL, 0) != 0 || size <= sizeof(int)) {
        free(procargs);
        return -1;
    }

    // Layout: argc, exec path, NUL padding, argv[0..argc-1], envp...
    int argc = 0;
    memcpy(&argc, procargs, sizeof(argc));
    char *p = procargs + sizeof(argc);
    char *end = procargs + size;
    while (p < end && *p != '\0') p++;  // skip exec path
    while (p < end && *p == '\0') p++;  // skip padding

    int written = 0;
    while (argc-- > 0 && p < end && written < buflen - 1) {
        size_t alen = strnlen(p, (size_t)(end - p));
        if (written > 0 && written < buflen - 1) buf[written++] = ' ';
        size_t copy = alen;
        if (copy > (size_t)(buflen - 1 - written)) copy = (size_t)(buflen - 1 - written);
        memcpy(buf + written, p, copy);
        written += (int)copy;
        p += alen + 1;
    }
    buf[written] = '\0';
    free(procargs);
    return written;
}
