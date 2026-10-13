/*
 * CSysInfo — low-level macOS system access for Boxtop.
 *
 * Portions ported from btop (https://github.com/aristocratos/btop),
 * Copyright 2021 Aristocratos, licensed under the Apache License 2.0.
 * See LICENSE and NOTICE in the project root.
 */
#ifndef CSYSINFO_H
#define CSYSINFO_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Thermal sensors via IOHIDEventSystem (Apple Silicon)
// Port of btop src/osx/sensors.cpp. Returns raw sensor readings; the
// grouping into package / core temperatures happens in Swift.

typedef struct {
    char name[64];
    double celsius;
} bt_hid_sensor;

/// Fills `out` with up to `max` temperature sensors. Returns the count.
int bt_hid_temperatures(bt_hid_sensor *out, int max);

// MARK: - System Management Controller (Intel + Apple Silicon)
// Port of btop src/osx/smc.cpp, extended to decode flt/fpe2/integer types.

bool bt_smc_open(void);
void bt_smc_close(void);
/// Reads and decodes a 4-character SMC key. Returns false if missing.
bool bt_smc_read(const char *key, double *value);

// MARK: - Apple Silicon GPU via IOReport
// Port of btop Gpu::AppleSilicon (src/osx/btop_collect.cpp). libIOReport is
// loaded with dlopen so the binary still runs where it is unavailable.

typedef struct {
    double utilization;   // 0-100 %
    double freq_mhz;      // average active frequency
    double power_w;       // GPU energy / time
    bool has_utilization;
    bool has_freq;
    bool has_power;
} bt_gpu_sample;

bool bt_gpu_ioreport_init(void);
bool bt_gpu_ioreport_sample(bt_gpu_sample *out);

// MARK: - Network interface counters (64-bit) via NET_RT_IFLIST2

typedef struct {
    char name[32];
    uint64_t ibytes;
    uint64_t obytes;
    uint32_t flags;
    uint64_t baudrate;
} bt_ifstat;

/// Fills `out` with up to `max` interfaces. Returns the count, or -1 on error.
int bt_net_counters(bt_ifstat *out, int max);

// MARK: - Process arguments via KERN_PROCARGS2

/// Writes the space-joined argv of `pid` into `buf`. Returns bytes written
/// (excluding NUL), or -1 when the arguments are not readable.
int bt_proc_args(pid_t pid, char *buf, int buflen);

#ifdef __cplusplus
}
#endif

#endif /* CSYSINFO_H */
