// Sensors.cpp - temperatury z SMC (AppleSMC) oraz moc podsystemów z IOReport (jak powermetrics)
#include "include/SysCore.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <string>
#include <vector>

// ------------------------------------------------------------------ SMC
namespace {

struct SMCVers { uint8_t major, minor, build, reserved; uint16_t release; };
struct SMCPLimit { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; };
struct SMCKeyInfo { uint32_t dataSize, dataType; uint8_t dataAttributes; };
struct SMCKeyData {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
};

constexpr uint32_t KERNEL_INDEX_SMC = 2;
constexpr uint8_t SMC_CMD_READ_BYTES = 5, SMC_CMD_READ_INDEX = 8, SMC_CMD_READ_KEYINFO = 9;

uint32_t fourcc(const char* s) { return (uint32_t(s[0]) << 24) | (uint32_t(s[1]) << 16) | (uint32_t(s[2]) << 8) | uint32_t(s[3]); }
std::string fourccStr(uint32_t v) { char b[5] = { char(v >> 24), char(v >> 16), char(v >> 8), char(v), 0 }; return b; }

class SMC {
public:
    static SMC& get() { static SMC s; return s; }
    bool ok() const { return m_conn != IO_OBJECT_NULL; }

    bool call(SMCKeyData& in, SMCKeyData& out) {
        size_t outSize = sizeof out;
        return ok() && IOConnectCallStructMethod(m_conn, KERNEL_INDEX_SMC, &in, sizeof in, &out, &outSize) == kIOReturnSuccess;
    }

    bool keyInfo(uint32_t key, SMCKeyInfo& info) {
        {   // opis klucza nie zmienia się w czasie pracy, więc pamiętamy go raz
            std::lock_guard<std::mutex> lock(m_infoMutex);
            auto it = m_infoCache.find(key);
            if (it != m_infoCache.end()) { info = it->second; return true; }
        }
        SMCKeyData in{}, out{};
        in.key = key; in.data8 = SMC_CMD_READ_KEYINFO;
        if (!call(in, out) || out.result != 0) return false;
        info = out.keyInfo;
        std::lock_guard<std::mutex> lock(m_infoMutex);
        m_infoCache[key] = info;
        return true;
    }

    // Odczyt klucza jako double (obsługa typów flt, sp78, ui8/16/32, ioft)
    bool read(uint32_t key, double& value, SMCKeyInfo* infoOut = nullptr) {
        SMCKeyInfo info{};
        if (!keyInfo(key, info) || info.dataSize == 0 || info.dataSize > 32) return false;
        SMCKeyData in{}, out{};
        in.key = key; in.keyInfo.dataSize = info.dataSize; in.data8 = SMC_CMD_READ_BYTES;
        if (!call(in, out) || out.result != 0) return false;
        if (infoOut) *infoOut = info;
        const std::string type = fourccStr(info.dataType);
        const uint8_t* b = out.bytes;
        if (type == "flt " && info.dataSize == 4) { float f; memcpy(&f, b, 4); value = f; return std::isfinite(value); }
        if (type == "sp78" && info.dataSize == 2) { value = int16_t((b[0] << 8) | b[1]) / 256.0; return true; }
        if (type == "ui8 ") { value = b[0]; return true; }
        if (type == "ui16") { value = (b[0] << 8) | b[1]; return true; }
        if (type == "ui32") { value = (uint32_t(b[0]) << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return true; }
        if (type == "ioft" && info.dataSize == 8) { uint64_t v = 0; for (int i = 0; i < 8; ++i) v = (v << 8) | b[i]; value = double(v) / 65536.0; return true; }
        return false;
    }

    // Lista wszystkich kluczy (raz)
    const std::vector<uint32_t>& keys() {
        std::call_once(m_once, [this] {
            double cnt = 0;
            if (!read(fourcc("#KEY"), cnt)) return;
            for (uint32_t i = 0; i < uint32_t(cnt); ++i) {
                SMCKeyData in{}, out{};
                in.data8 = SMC_CMD_READ_INDEX; in.data32 = i;
                if (call(in, out) && out.result == 0) m_keys.push_back(out.key);
            }
        });
        return m_keys;
    }

private:
    SMC() {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (svc != IO_OBJECT_NULL) {
            if (IOServiceOpen(svc, mach_task_self(), 0, &m_conn) != kIOReturnSuccess) m_conn = IO_OBJECT_NULL;
            IOObjectRelease(svc);
        }
    }
    io_connect_t m_conn = IO_OBJECT_NULL;
    std::once_flag m_once;
    std::vector<uint32_t> m_keys;
    std::unordered_map<uint32_t, SMCKeyInfo> m_infoCache;
    std::mutex m_infoMutex;
};

std::vector<uint32_t> g_tempKeys;
std::once_flag g_tempOnce;

} // namespace

extern "C" {

double sc_smc_read_float(const char* key) {
    double v = NAN;
    if (strlen(key) != 4) return NAN;
    return SMC::get().read(fourcc(key), v) ? v : NAN;
}

int sc_smc_read_temps(SCSensor* out, int max) {
    SMC& smc = SMC::get();
    if (!smc.ok()) return 0;
    std::call_once(g_tempOnce, [&] {
        for (uint32_t k : smc.keys()) {
            std::string name = fourccStr(k);
            if (name[0] != 'T') continue;
            SMCKeyInfo info{};
            double v = 0;
            if (!smc.read(k, v, &info)) continue;
            std::string type = fourccStr(info.dataType);
            if (type != "flt " && type != "sp78") continue;
            if (v < 5 || v > 125) continue;   // odrzuć wartości niebędące temperaturą
            g_tempKeys.push_back(k);
        }
    });
    int n = 0;
    for (uint32_t k : g_tempKeys) {
        if (n >= max) break;
        double v = 0;
        if (!smc.read(k, v) || v < 0 || v > 130) continue;
        std::string name = fourccStr(k);
        strncpy(out[n].name, name.c_str(), sizeof(out[n].name) - 1);
        out[n].name[sizeof(out[n].name) - 1] = 0;
        out[n].value = v;
        ++n;
    }
    return n;
}

} // extern "C"

// -------------------------------------------------------------- IOReport
namespace {

typedef CFDictionaryRef (*IOReportCopyChannelsInGroup_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void* (*IOReportCreateSubscription_t)(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamples_t)(void*, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesDelta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*IOReportChannelGetGroup_t)(CFDictionaryRef);
typedef CFStringRef (*IOReportChannelGetChannelName_t)(CFDictionaryRef);
typedef CFStringRef (*IOReportChannelGetUnitLabel_t)(CFDictionaryRef);
typedef int64_t (*IOReportSimpleGetIntegerValue_t)(CFDictionaryRef, int32_t*);
typedef void (*IOReportMergeChannels_t)(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef);

struct IOReport {
    bool ok = false;
    IOReportCopyChannelsInGroup_t copyChannelsInGroup = nullptr;
    IOReportCreateSubscription_t createSubscription = nullptr;
    IOReportCreateSamples_t createSamples = nullptr;
    IOReportCreateSamplesDelta_t createSamplesDelta = nullptr;
    IOReportChannelGetGroup_t getGroup = nullptr;
    IOReportChannelGetChannelName_t getChannelName = nullptr;
    IOReportChannelGetUnitLabel_t getUnitLabel = nullptr;
    IOReportSimpleGetIntegerValue_t getInteger = nullptr;
    IOReportMergeChannels_t mergeChannels = nullptr;

    void* subscription = nullptr;
    CFMutableDictionaryRef subscribed = nullptr;
    CFDictionaryRef prevSample = nullptr;
    uint64_t prevTime = 0;

    static IOReport& get() { static IOReport r; return r; }

    IOReport() {
        void* h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY);
        if (!h) return;
        copyChannelsInGroup = (IOReportCopyChannelsInGroup_t)dlsym(h, "IOReportCopyChannelsInGroup");
        createSubscription = (IOReportCreateSubscription_t)dlsym(h, "IOReportCreateSubscription");
        createSamples = (IOReportCreateSamples_t)dlsym(h, "IOReportCreateSamples");
        createSamplesDelta = (IOReportCreateSamplesDelta_t)dlsym(h, "IOReportCreateSamplesDelta");
        getGroup = (IOReportChannelGetGroup_t)dlsym(h, "IOReportChannelGetGroup");
        getChannelName = (IOReportChannelGetChannelName_t)dlsym(h, "IOReportChannelGetChannelName");
        getUnitLabel = (IOReportChannelGetUnitLabel_t)dlsym(h, "IOReportChannelGetUnitLabel");
        getInteger = (IOReportSimpleGetIntegerValue_t)dlsym(h, "IOReportSimpleGetIntegerValue");
        mergeChannels = (IOReportMergeChannels_t)dlsym(h, "IOReportMergeChannels");
        if (!copyChannelsInGroup || !createSubscription || !createSamples || !createSamplesDelta || !getGroup || !getChannelName || !getUnitLabel || !getInteger) return;

        CFDictionaryRef energy = copyChannelsInGroup(CFSTR("Energy Model"), nullptr, 0, 0, 0);
        if (!energy) return;
        CFMutableDictionaryRef channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy);
        CFRelease(energy);
        subscription = createSubscription(nullptr, channels, &subscribed, 0, nullptr);
        CFRelease(channels);
        if (!subscription) return;
        prevSample = createSamples(subscription, subscribed, nullptr);
        prevTime = mach_absolute_time();
        ok = prevSample != nullptr;
    }

    static double toNs(uint64_t mach) {
        static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
        return double(mach) * tb.numer / tb.denom;
    }

    static double unitToJoules(CFStringRef unit) {
        char buf[32] = {};
        if (unit) CFStringGetCString(unit, buf, sizeof buf, kCFStringEncodingUTF8);
        std::string u = buf;
        if (u == "mJ") return 1e-3;
        if (u == "uJ" || u == "µJ") return 1e-6;
        if (u == "nJ") return 1e-9;
        return 1.0; // J
    }

    SCPower sample() {
        SCPower p{};
        if (!ok) return p;
        CFDictionaryRef cur = createSamples(subscription, subscribed, nullptr);
        if (!cur) return p;
        uint64_t now = mach_absolute_time();
        double dt = toNs(now - prevTime) / 1e9;
        CFDictionaryRef delta = createSamplesDelta(prevSample, cur, nullptr);
        CFRelease(prevSample);
        prevSample = cur;
        prevTime = now;
        if (!delta || dt <= 0) { if (delta) CFRelease(delta); return p; }
        auto arr = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
        if (arr) {
            for (CFIndex i = 0; i < CFArrayGetCount(arr); ++i) {
                auto ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
                CFStringRef name = getChannelName(ch);
                char nbuf[64] = {};
                if (name) CFStringGetCString(name, nbuf, sizeof nbuf, kCFStringEncodingUTF8);
                int32_t err = 0;
                int64_t v = getInteger(ch, &err);
                double watts = double(v) * unitToJoules(getUnitLabel(ch)) / dt;
                std::string n = nbuf;
                if (n == "CPU Energy") { p.cpuWatts += watts; p.available = true; }
                else if (n == "GPU") { p.gpuWatts += watts; p.available = true; }
                else if (n == "ANE") { p.aneWatts += watts; p.available = true; }
                else if (n == "DRAM") { p.dramWatts += watts; p.available = true; }
                else if (n == "AVE") { p.encoderWatts += watts; p.available = true; }   // enkoder wideo
                else if (n == "VDEC") { p.decoderWatts += watts; p.available = true; }  // dekoder wideo
                else if (n == "ISP") { p.ispWatts += watts; }
                else if (n == "DISP" || n == "DISPEXT") { p.displayWatts += watts; }
                if (getenv("SC_DEBUG")) fprintf(stderr, "delta %s = %lld (%g W)\n", nbuf, (long long)v, watts);
            }
        } else if (getenv("SC_DEBUG")) {
            fprintf(stderr, "delta has no IOReportChannels\n"); CFShow(delta);
        }
        CFRelease(delta);
        // zamrożone liczniki (brak uprawnień administratora) = brak danych
        if (p.cpuWatts + p.gpuWatts + p.aneWatts + p.dramWatts <= 0) p.available = false;
        double sys = sc_smc_read_float("PSTR");
        p.sysWatts = std::isfinite(sys) ? sys : 0;
        return p;
    }
};

} // namespace

extern "C" SCPower sc_power_sample(void) { return IOReport::get().sample(); }

// Debug: wypisz kanały grupy
extern "C" void sc_power_debug(void) {
    IOReport& r = IOReport::get();
    printf("ok=%d sub=%p subscribed=%p prev=%p\n", r.ok, r.subscription, (void*)r.subscribed, (void*)r.prevSample);
    if (!r.copyChannelsInGroup) { printf("no symbols\n"); return; }
    CFDictionaryRef energy = r.copyChannelsInGroup(CFSTR("Energy Model"), nullptr, 0, 0, 0);
    if (!energy) { printf("no group\n"); return; }
    CFShow(energy);
    if (r.prevSample) {
        auto arr = (CFArrayRef)CFDictionaryGetValue(r.prevSample, CFSTR("IOReportChannels"));
        printf("sample channels=%ld\n", arr ? CFArrayGetCount(arr) : -1L);
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); ++i) {
            auto ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            char g[64] = {}, n[64] = {}, u[32] = {};
            CFStringRef gs = r.getGroup(ch), ns = r.getChannelName(ch), us = r.getUnitLabel(ch);
            if (gs) CFStringGetCString(gs, g, 64, kCFStringEncodingUTF8);
            if (ns) CFStringGetCString(ns, n, 64, kCFStringEncodingUTF8);
            if (us) CFStringGetCString(us, u, 32, kCFStringEncodingUTF8);
            int32_t e = 0; int64_t v = r.getInteger(ch, &e);
            printf("  [%s] %s = %lld %s\n", g, n, v, u);
        }
    }
}

extern "C" void sc_power_debug2(void) {
    IOReport& r = IOReport::get();
    auto dump = [&](CFDictionaryRef s, const char* tag) {
        auto arr = (CFArrayRef)CFDictionaryGetValue(s, CFSTR("IOReportChannels"));
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); ++i) {
            auto ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            char n[64] = {}; CFStringRef ns = r.getChannelName(ch); if (ns) CFStringGetCString(ns, n, 64, kCFStringEncodingUTF8);
            if (strcmp(n, "CPU Energy") == 0) { int32_t e = 0; printf("%s CPU Energy = %lld err=%d\n", tag, (long long)r.getInteger(ch, &e), e); }
        }
    };
    CFDictionaryRef a = r.createSamples(r.subscription, r.subscribed, nullptr);
    dump(a, "A");
    usleep(1500000);
    CFDictionaryRef b = r.createSamples(r.subscription, r.subscribed, nullptr);
    dump(b, "B");
    CFDictionaryRef d = r.createSamplesDelta(a, b, nullptr);
    dump(d, "delta");
    printf("a==b %d\n", a == b);
}

extern "C" void sc_power_debug3(int seconds) {
    IOReport& r = IOReport::get();
    for (int t = 0; t < seconds; ++t) {
        CFDictionaryRef a = r.createSamples(r.subscription, r.subscribed, nullptr);
        auto arr = (CFArrayRef)CFDictionaryGetValue(a, CFSTR("IOReportChannels"));
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); ++i) {
            auto ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            char n[64] = {}; CFStringRef ns = r.getChannelName(ch); if (ns) CFStringGetCString(ns, n, 64, kCFStringEncodingUTF8);
            if (strcmp(n, "CPU Energy") == 0 || strcmp(n, "GPU") == 0) { int32_t e = 0; printf("t=%d %s=%lld  ", t, n, (long long)r.getInteger(ch, &e)); }
        }
        printf("\n"); fflush(stdout);
        CFRelease(a);
        sleep(1);
    }
}

extern "C" void sc_smc_dump(char prefix) {
    SMC& smc = SMC::get();
    for (uint32_t k : smc.keys()) {
        std::string name = fourccStr(k);
        if (name[0] != prefix) continue;
        SMCKeyInfo info{}; double v = 0;
        if (!smc.read(k, v, &info)) continue;
        printf("%s [%s] = %.3f\n", name.c_str(), fourccStr(info.dataType).c_str(), v);
    }
}

// Apple Neural Engine: liczba rdzeni i architektura z IORegistry (DeviceProperties sterownika ANE)
extern "C" bool sc_ane_info(int* cores, char* arch, int archLen) {
    *cores = 0; if (archLen > 0) arch[0] = 0;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return false;
    bool found = false;
    io_registry_entry_t e;
    while (!found && (e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        CFTypeRef props = IORegistryEntryCreateCFProperty(e, CFSTR("DeviceProperties"), kCFAllocatorDefault, 0);
        if (props && CFGetTypeID(props) == CFDictionaryGetTypeID()) {
            auto d = (CFDictionaryRef)props;
            CFTypeRef n = CFDictionaryGetValue(d, CFSTR("ANEDevicePropertyNumANECores"));
            if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)n, kCFNumberIntType, cores);
                CFTypeRef a = CFDictionaryGetValue(d, CFSTR("ANEDevicePropertyTypeANEArchitectureTypeStr"));
                if (a && CFGetTypeID(a) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)a, arch, archLen, kCFStringEncodingUTF8);
                found = true;
            }
        }
        if (props) CFRelease(props);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return found;
}

// Wszystkie klucze SMC o danym prefiksie (T = temperatury, P = moce, V = napięcia, I = prądy, F = wentylatory)
extern "C" int sc_smc_read_keys(char prefix, SCSensor* out, int max) {
    SMC& smc = SMC::get();
    if (!smc.ok()) return 0;
    int n = 0;
    for (uint32_t k : smc.keys()) {
        if (n >= max) break;
        std::string name = fourccStr(k);
        if (name[0] != prefix) continue;
        SMCKeyInfo info{}; double v = 0;
        if (!smc.read(k, v, &info)) continue;
        std::string type = fourccStr(info.dataType);
        if (type != "flt " && type != "sp78" && type != "ui8 " && type != "ui16") continue;
        if (!std::isfinite(v)) continue;
        strncpy(out[n].name, name.c_str(), sizeof(out[n].name) - 1);
        out[n].name[sizeof(out[n].name) - 1] = 0;
        out[n].value = v;
        ++n;
    }
    return n;
}
