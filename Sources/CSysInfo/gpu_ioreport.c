/*
 * Apple Silicon GPU utilization, frequency and power via IOReport.
 * Ported from btop src/osx/btop_collect.cpp (Gpu::AppleSilicon) — Copyright 2021 Aristocratos, Apache-2.0.
 * libIOReport is resolved at runtime so Intel builds and older systems degrade gracefully.
 */
#include "CSysInfo.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;

typedef CFDictionaryRef (*fn_CopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*fn_MergeChannels)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef IOReportSubscriptionRef (*fn_CreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*fn_ChannelGetString)(CFDictionaryRef);
typedef int64_t (*fn_SimpleGetIntegerValue)(CFDictionaryRef, int32_t);
typedef int32_t (*fn_StateGetCount)(CFDictionaryRef);
typedef CFStringRef (*fn_StateGetNameForIndex)(CFDictionaryRef, int32_t);
typedef int64_t (*fn_StateGetResidency)(CFDictionaryRef, int32_t);

static struct {
    fn_CopyChannelsInGroup CopyChannelsInGroup;
    fn_MergeChannels MergeChannels;
    fn_CreateSubscription CreateSubscription;
    fn_CreateSamples CreateSamples;
    fn_CreateSamplesDelta CreateSamplesDelta;
    fn_ChannelGetString ChannelGetGroup;
    fn_ChannelGetString ChannelGetSubGroup;
    fn_ChannelGetString ChannelGetChannelName;
    fn_ChannelGetString ChannelGetUnitLabel;
    fn_SimpleGetIntegerValue SimpleGetIntegerValue;
    fn_StateGetCount StateGetCount;
    fn_StateGetNameForIndex StateGetNameForIndex;
    fn_StateGetResidency StateGetResidency;
} ior;

static bool g_initialized = false;
static IOReportSubscriptionRef g_sub = NULL;
static CFMutableDictionaryRef g_chan = NULL;
static CFDictionaryRef g_prev = NULL;
static uint64_t g_prev_ms = 0;
static uint32_t g_freqs[64];
static int g_freq_count = 0;

static uint64_t now_ms(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (mach_absolute_time() * tb.numer / tb.denom) / 1000000;
}

static bool load_symbols(void) {
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!h) return false;
#define LOAD(field, sym) \
    ior.field = (__typeof__(ior.field))dlsym(h, sym); \
    if (!ior.field) return false;
    LOAD(CopyChannelsInGroup, "IOReportCopyChannelsInGroup");
    LOAD(MergeChannels, "IOReportMergeChannels");
    LOAD(CreateSubscription, "IOReportCreateSubscription");
    LOAD(CreateSamples, "IOReportCreateSamples");
    LOAD(CreateSamplesDelta, "IOReportCreateSamplesDelta");
    LOAD(ChannelGetGroup, "IOReportChannelGetGroup");
    LOAD(ChannelGetSubGroup, "IOReportChannelGetSubGroup");
    LOAD(ChannelGetChannelName, "IOReportChannelGetChannelName");
    LOAD(ChannelGetUnitLabel, "IOReportChannelGetUnitLabel");
    LOAD(SimpleGetIntegerValue, "IOReportSimpleGetIntegerValue");
    LOAD(StateGetCount, "IOReportStateGetCount");
    LOAD(StateGetNameForIndex, "IOReportStateGetNameForIndex");
    LOAD(StateGetResidency, "IOReportStateGetResidency");
#undef LOAD
    return true;
}

// GPU DVFS frequency table from the IORegistry "pmgr" node ("voltage-states9": pairs of freq/voltage).
static void load_gpu_freqs(void) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) != kIOReturnSuccess)
        return;
    io_object_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        io_name_t name;
        if (IORegistryEntryGetName(entry, name) == kIOReturnSuccess && strcmp(name, "pmgr") == 0) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess && props) {
                CFDataRef data = (CFDataRef)CFDictionaryGetValue(props, CFSTR("voltage-states9"));
                if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
                    CFIndex len = CFDataGetLength(data);
                    const UInt8 *p = CFDataGetBytePtr(data);
                    for (CFIndex i = 0; i + 7 < len && g_freq_count < 64; i += 8) {
                        uint32_t f = 0;
                        memcpy(&f, p + i, 4);
                        if (f > 0) g_freqs[g_freq_count++] = f / (1000 * 1000);
                    }
                }
                CFRelease(props);
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
}

static bool cfeq(CFStringRef s, const char *c) {
    if (!s) return false;
    char buf[128];
    if (!CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) return false;
    return strcmp(buf, c) == 0;
}

bool bt_gpu_ioreport_init(void) {
#if !defined(__arm64__)
    return false;
#else
    if (g_initialized) return true;
    if (!load_symbols()) return false;

    load_gpu_freqs();

    CFDictionaryRef gpu_chan = ior.CopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    CFDictionaryRef energy_chan = ior.CopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!gpu_chan && !energy_chan) return false;

    if (gpu_chan && energy_chan) ior.MergeChannels(gpu_chan, energy_chan, NULL);
    CFDictionaryRef base = gpu_chan ? gpu_chan : energy_chan;
    g_chan = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(base), base);
    if (gpu_chan) CFRelease(gpu_chan);
    if (energy_chan) CFRelease(energy_chan);

    CFMutableDictionaryRef sub_dict = NULL;
    g_sub = ior.CreateSubscription(NULL, g_chan, &sub_dict, 0, NULL);
    if (!g_sub) {
        CFRelease(g_chan);
        g_chan = NULL;
        return false;
    }
    g_prev = ior.CreateSamples(g_sub, g_chan, NULL);
    g_prev_ms = now_ms();
    g_initialized = true;
    return true;
#endif
}

bool bt_gpu_ioreport_sample(bt_gpu_sample *out) {
    if (!g_initialized || !out) return false;
    memset(out, 0, sizeof(*out));

    CFDictionaryRef cur = ior.CreateSamples(g_sub, g_chan, NULL);
    if (!cur) return false;
    uint64_t t = now_ms();
    uint64_t dt = t - g_prev_ms;
    if (dt == 0) dt = 1;

    CFDictionaryRef delta = NULL;
    if (g_prev) {
        delta = ior.CreateSamplesDelta(g_prev, cur, NULL);
        CFRelease(g_prev);
    }
    g_prev = cur;
    g_prev_ms = t;
    if (!delta) return false;

    CFArrayRef channels = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!channels) {
        CFRelease(delta);
        return false;
    }

    CFIndex n = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, i);
        if (!item) continue;
        CFStringRef group = ior.ChannelGetGroup(item);
        CFStringRef channel = ior.ChannelGetChannelName(item);

        // Utilization from residency in active performance states.
        if (cfeq(group, "GPU Stats") && cfeq(ior.ChannelGetSubGroup(item), "GPU Performance States") && cfeq(channel, "GPUPH")) {
            int32_t states = ior.StateGetCount(item);
            if (states <= 0) continue;
            int64_t total = 0, active = 0;
            double weighted = 0;
            int offset = 0;
            for (int32_t s = 0; s < states; s++) {
                CFStringRef sn = ior.StateGetNameForIndex(item, s);
                if (cfeq(sn, "IDLE") || cfeq(sn, "OFF") || cfeq(sn, "DOWN")) offset = s + 1;
                total += ior.StateGetResidency(item, s);
            }
            for (int32_t s = offset; s < states; s++) {
                int64_t res = ior.StateGetResidency(item, s);
                active += res;
                int fi = s - offset;
                if (fi < g_freq_count) weighted += (double)res * g_freqs[fi];
            }
            if (total > 0) {
                double u = round((double)active * 100.0 / (double)total);
                out->utilization = u < 0 ? 0 : (u > 100 ? 100 : u);
                out->has_utilization = true;
                if (active > 0 && g_freq_count > 0) {
                    out->freq_mhz = weighted / (double)active;
                    out->has_freq = true;
                }
            }
        }

        // Power from the energy model.
        if (cfeq(group, "Energy Model") && cfeq(channel, "GPU Energy")) {
            char unit[32] = {0};
            CFStringRef ul = ior.ChannelGetUnitLabel(item);
            if (ul) CFStringGetCString(ul, unit, sizeof(unit), kCFStringEncodingUTF8);
            double energy = (double)ior.SimpleGetIntegerValue(item, 0);
            if (strstr(unit, "nJ")) energy /= 1e9;
            else if (strstr(unit, "uJ") || strstr(unit, "\xc2\xb5J")) energy /= 1e6;
            else if (strstr(unit, "mJ")) energy /= 1e3;
            out->power_w = energy / ((double)dt / 1000.0);
            out->has_power = true;
        }
    }
    CFRelease(delta);
    return out->has_utilization || out->has_power;
}
