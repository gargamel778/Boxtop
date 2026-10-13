/*
 * Apple Silicon thermal sensors via the IOHIDEventSystem.
 * Ported from btop src/osx/sensors.cpp — Copyright 2021 Aristocratos, Apache-2.0.
 */
#include "CSysInfo.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <string.h>

// Private IOKit HID SPI (exported by IOKit.framework), as declared in btop.
// IOHIDServiceClientRef, IOHIDEventSystemClientCopyServices and
// IOHIDServiceClientCopyProperty come from the public headers.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// {"PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x5} matches thermal sensors.
static CFDictionaryRef matching(int page, int usage) {
    CFStringRef keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    CFNumberRef nums[2] = {
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage),
    };
    CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, (const void **)nums, 2,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(nums[0]);
    CFRelease(nums[1]);
    return dict;
}

// btop creates a new client and re-enumerates services on every read, which dominated
// Boxtop's sampling cost. The client and service list are cached here and refreshed
// periodically (sensors can appear after sleep/wake). Called from one queue only.
static IOHIDEventSystemClientRef g_system = NULL;
static CFArrayRef g_services = NULL;
static int g_reads_since_refresh = 0;

static void refresh_services(void) {
    if (g_services) {
        CFRelease(g_services);
        g_services = NULL;
    }
    if (!g_system) {
        g_system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!g_system) return;
        CFDictionaryRef match = matching(0xff00, 5);
        IOHIDEventSystemClientSetMatching(g_system, match);
        CFRelease(match);
    }
    g_services = IOHIDEventSystemClientCopyServices(g_system);
    g_reads_since_refresh = 0;
}

int bt_hid_temperatures(bt_hid_sensor *out, int max) {
    if (!out || max <= 0) return 0;
    if (!g_services || ++g_reads_since_refresh >= 120) refresh_services();
    if (!g_services) return 0;

    int n = 0;
    CFIndex count = CFArrayGetCount(g_services);
    for (CFIndex i = 0; i < count && n < max; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(g_services, i);
        if (!sc) continue;
        CFTypeRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        if (!name) continue;
        if (CFGetTypeID(name) != CFStringGetTypeID()) {
            CFRelease(name);
            continue;
        }

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (event) {
            double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            CFRelease(event);
            // Same sanity window btop uses.
            if (temp > 0 && temp < 150) {
                memset(out[n].name, 0, sizeof(out[n].name));
                CFStringGetCString((CFStringRef)name, out[n].name, sizeof(out[n].name), kCFStringEncodingUTF8);
                out[n].celsius = temp;
                n++;
            }
        }
        CFRelease(name);
    }
    // Stale handles (e.g. after sleep/wake) return no events: re-enumerate on the next read.
    if (n == 0) g_reads_since_refresh = 1 << 20;
    return n;
}
