/*
 * System Management Controller access (Intel and Apple Silicon).
 * Ported from btop src/osx/smc.cpp / smc.hpp — Copyright 2021 Aristocratos, Apache-2.0.
 * Extended with decoding for flt / fpXY / spXY / integer key types and a key-info cache.
 */
#include "CSysInfo.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static io_connect_t g_conn = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// Small cache of key -> keyInfo so each read is a single kernel call.
#define KEYINFO_CACHE 128
static struct { UInt32 key; SMCKeyData_keyInfo_t info; bool missing; } g_cache[KEYINFO_CACHE];
static int g_cache_count = 0;

static UInt32 key_to_u32(const char *key) {
    return ((UInt32)(unsigned char)key[0] << 24) | ((UInt32)(unsigned char)key[1] << 16) |
           ((UInt32)(unsigned char)key[2] << 8) | (UInt32)(unsigned char)key[3];
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t out_size = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &out_size);
}

bool bt_smc_open(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) {
        pthread_mutex_unlock(&g_lock);
        return true;
    }
    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator);
    if (result != kIOReturnSuccess) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    io_object_t device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!device) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    result = IOServiceOpen(device, mach_task_self(), 0, &g_conn);
    IOObjectRelease(device);
    if (result != kIOReturnSuccess) g_conn = 0;
    bool ok = g_conn != 0;
    pthread_mutex_unlock(&g_lock);
    return ok;
}

void bt_smc_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) IOServiceClose(g_conn);
    g_conn = 0;
    g_cache_count = 0;
    pthread_mutex_unlock(&g_lock);
}

static bool key_info(UInt32 key, SMCKeyData_keyInfo_t *info) {
    for (int i = 0; i < g_cache_count; i++) {
        if (g_cache[i].key == key) {
            if (g_cache[i].missing) return false;
            *info = g_cache[i].info;
            return true;
        }
    }
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    bool ok = smc_call(&in, &out) == kIOReturnSuccess && out.result == 0 && out.keyInfo.dataSize > 0;
    if (g_cache_count < KEYINFO_CACHE) {
        g_cache[g_cache_count].key = key;
        g_cache[g_cache_count].info = out.keyInfo;
        g_cache[g_cache_count].missing = !ok;
        g_cache_count++;
    }
    if (ok) *info = out.keyInfo;
    return ok;
}

static bool decode(UInt32 type, UInt32 size, const unsigned char *b, double *value) {
    char t[5] = { (char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type, 0 };

    if (strcmp(t, "flt ") == 0 && size == 4) {
        float f;
        memcpy(&f, b, 4);  // little-endian on both Intel and Apple Silicon
        *value = f;
        return true;
    }
    if (t[0] == 's' && t[1] == 'p' && size == 2) {  // spXY: signed fixed point, Y fraction bits (sp78)
        int frac = (t[3] >= 'a') ? t[3] - 'a' + 10 : t[3] - '0';
        int16_t raw = (int16_t)((b[0] << 8) | b[1]);
        *value = (double)raw / (double)(1 << frac);
        return true;
    }
    if (t[0] == 'f' && t[1] == 'p' && size == 2) {  // fpXY: unsigned fixed point (fpe2 for fans)
        int frac = (t[3] >= 'a') ? t[3] - 'a' + 10 : t[3] - '0';
        uint16_t raw = (uint16_t)((b[0] << 8) | b[1]);
        *value = (double)raw / (double)(1 << frac);
        return true;
    }
    if (strcmp(t, "ui8 ") == 0 || strcmp(t, "ui16") == 0 || strcmp(t, "ui32") == 0) {
        uint64_t v = 0;
        for (UInt32 i = 0; i < size && i < 4; i++) v = (v << 8) | b[i];
        *value = (double)v;
        return true;
    }
    if (strcmp(t, "si8 ") == 0 && size == 1) {
        *value = (int8_t)b[0];
        return true;
    }
    if (strcmp(t, "si16") == 0 && size == 2) {
        *value = (int16_t)((b[0] << 8) | b[1]);
        return true;
    }
    return false;
}

bool bt_smc_read(const char *key, double *value) {
    if (!key || strlen(key) != 4 || !value) return false;
    pthread_mutex_lock(&g_lock);
    if (!g_conn) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    UInt32 k = key_to_u32(key);
    SMCKeyData_keyInfo_t info;
    if (!key_info(k, &info)) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    bool ok = smc_call(&in, &out) == kIOReturnSuccess && out.result == 0;
    if (ok) ok = decode(info.dataType, info.dataSize, (const unsigned char *)out.bytes, value);
    pthread_mutex_unlock(&g_lock);
    return ok;
}
