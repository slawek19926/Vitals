// SysInfo.cpp - implementacja odczytu danych systemowych macOS
#include "SysInfo.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pwd.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include "include/syscore.h"
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

#include <algorithm>
#include <cstring>
#include <map>

namespace sysinfo {

// ------------------------------------------------------------ narzędzia
uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

static uint64_t machToNs(uint64_t mach) {
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t; mach_timebase_info(&t); return t;
    }();
    if (tb.numer == tb.denom) return mach;
    return (uint64_t)(((__uint128_t)mach * tb.numer) / tb.denom);
}

static std::string sysctlString(const char* name) {
    size_t len = 0;
    if (sysctlbyname(name, nullptr, &len, nullptr, 0) != 0 || len == 0) return {};
    std::string s(len, '\0');
    if (sysctlbyname(name, s.data(), &len, nullptr, 0) != 0) return {};
    while (!s.empty() && (s.back() == '\0' || s.back() == '\n')) s.pop_back();
    return s;
}

static uint64_t sysctlU64(const char* name) {
    uint64_t v = 0; size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, nullptr, 0) != 0) {
        uint32_t v32 = 0; len = sizeof v32;
        if (sysctlbyname(name, &v32, &len, nullptr, 0) != 0) return 0;
        return v32;
    }
    return v;
}

bool isRoot() { return geteuid() == 0; }

static time_t bootTime() {
    struct timeval tv{}; size_t len = sizeof tv;
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &tv, &len, nullptr, 0) != 0) return 0;
    return tv.tv_sec;
}

double uptimeSeconds() {
    time_t bt = bootTime();
    return bt ? difftime(time(nullptr), bt) : 0.0;
}

void loadAverage(double out[3]) {
    out[0] = out[1] = out[2] = 0;
    getloadavg(out, 3);
}

static int64_t cfNumber(CFDictionaryRef d, CFStringRef key, int64_t def = -1) {
    if (!d) return def;
    CFTypeRef v = CFDictionaryGetValue(d, key);
    if (!v) return def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int64_t out = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &out)) return out;
    } else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    } else if (CFGetTypeID(v) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)v;
        CFIndex n = CFDataGetLength(data);
        if (n >= 1 && n <= 8) {
            int64_t out = 0;
            memcpy(&out, CFDataGetBytePtr(data), n);
            return out;
        }
    }
    return def;
}

static std::string cfString(CFTypeRef v) {
    if (!v) return {};
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        char buf[512];
        if (CFStringGetCString((CFStringRef)v, buf, sizeof buf, kCFStringEncodingUTF8)) return buf;
    } else if (CFGetTypeID(v) == CFDataGetTypeID()) {
        CFDataRef d = (CFDataRef)v;
        std::string s((const char*)CFDataGetBytePtr(d), CFDataGetLength(d));
        while (!s.empty() && s.back() == '\0') s.pop_back();
        return s;
    }
    return {};
}

static std::string cfDictString(CFDictionaryRef d, CFStringRef key) {
    return d ? cfString(CFDictionaryGetValue(d, key)) : std::string();
}

// -------------------------------------------------------------- procesy
enum { P_SIDL = 1, P_SRUN = 2, P_SSLEEP = 3, P_SSTOP = 4, P_SZOMB = 5 };

std::vector<ProcessInfo> ProcessSampler::sample() {
    std::vector<ProcessInfo> out;
    const uint64_t now = nowNs();
    const double wallDelta = m_prevWallNs ? double(now - m_prevWallNs) : 0.0;

    // Lista wszystkich procesów przez sysctl (działa również dla procesów innych użytkowników)
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, nullptr, &len, nullptr, 0) != 0) return out;
    std::vector<char> buf(len + 64 * sizeof(kinfo_proc));
    len = buf.size();
    if (sysctl(mib, 3, buf.data(), &len, nullptr, 0) != 0) return out;
    const size_t n = len / sizeof(kinfo_proc);
    const kinfo_proc* procs = reinterpret_cast<const kinfo_proc*>(buf.data());

    out.reserve(n);
    std::unordered_map<int, Prev> newPrev;
    newPrev.reserve(n);
    std::unordered_map<int, std::string> newPathCache;
    newPathCache.reserve(n);
    m_totalThreads = 0;

    for (size_t i = 0; i < n; ++i) {
        const kinfo_proc& kp = procs[i];
        ProcessInfo p;
        p.pid = kp.kp_proc.p_pid;
        if (p.pid < 0) continue;
        p.ppid = kp.kp_eproc.e_ppid;
        p.uid = kp.kp_eproc.e_ucred.cr_uid;
        p.startTime = kp.kp_proc.p_starttime.tv_sec;
        p.name.assign(kp.kp_proc.p_comm, strnlen(kp.kp_proc.p_comm, MAXCOMLEN));
        const int status = kp.kp_proc.p_stat;

        // Ścieżka (cache - nie zmienia się w trakcie życia procesu)
        auto pc = m_pathCache.find(p.pid);
        if (pc != m_pathCache.end()) {
            p.path = pc->second;
        } else if (p.pid > 0) {
            char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(p.pid, pathBuf, sizeof pathBuf) > 0) p.path = pathBuf;
        }
        newPathCache[p.pid] = p.path;
        if (!p.path.empty()) {
            auto slash = p.path.find_last_of('/');
            std::string base = slash == std::string::npos ? p.path : p.path.substr(slash + 1);
            if (!base.empty() && (p.name.size() >= MAXCOMLEN || base.size() > p.name.size())) p.name = base;
        }
        if (p.pid == 0 && p.name.empty()) p.name = "kernel_task";

        // Użytkownik (cache po uid)
        auto uc = m_userCache.find(p.uid);
        if (uc == m_userCache.end()) {
            struct passwd* pw = getpwuid(p.uid);
            std::string u = pw ? pw->pw_name : std::to_string(p.uid);
            uc = m_userCache.emplace(p.uid, u).first;
        }
        p.user = uc->second;

        // Szczegóły (CPU, pamięć, wątki) - dostępne tylko dla własnych procesów bez roota
        uint64_t cpuNs = 0;
        bool got = false;
        int running = 0;
        rusage_info_v4 ru{};
        if (p.pid > 0 && proc_pid_rusage(p.pid, RUSAGE_INFO_V4, (rusage_info_t*)&ru) == 0) {
            cpuNs = machToNs(ru.ri_user_time + ru.ri_system_time);
            p.memBytes = ru.ri_phys_footprint;
            p.diskRead = ru.ri_diskio_bytesread;
            p.diskWrite = ru.ri_diskio_byteswritten;
            got = true;
        }
        proc_taskinfo ti{};
        if (p.pid > 0 && proc_pidinfo(p.pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == (int)sizeof ti) {
            p.threads = ti.pti_threadnum;
            p.contextSwitches = ti.pti_csw;
            running = ti.pti_numrunning;
            if (!got) {
                cpuNs = machToNs(ti.pti_total_user + ti.pti_total_system);
                p.memBytes = ti.pti_resident_size;
                got = true;
            }
        }
        p.accessible = got;
        p.cpuTimeNs = cpuNs;
        m_totalThreads += p.threads;

        auto prev = m_prev.find(p.pid);
        if (got && prev != m_prev.end() && prev->second.start == p.startTime && wallDelta > 0 && cpuNs >= prev->second.cpuNs) {
            p.cpuPercent = double(cpuNs - prev->second.cpuNs) * 100.0 / wallDelta;
        }
        newPrev[p.pid] = { cpuNs, p.startTime };

        switch (status) {
            case P_SZOMB:  p.state = "Zombie"; break;
            case P_SSTOP:  p.state = "Zatrzymany"; break;
            case P_SIDL:   p.state = "Tworzony"; break;
            default:
                if (!got) p.state = "—";
                else p.state = running > 0 ? "Działa" : "Śpi";
        }
        out.push_back(std::move(p));
    }

    m_prev = std::move(newPrev);
    m_pathCache = std::move(newPathCache);
    m_prevWallNs = now;
    return out;
}

// ------------------------------------------------------------------ CPU
CpuStats CpuSampler::sample() {
    CpuStats st;
    natural_t cpuCount = 0;
    processor_info_array_t info = nullptr;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) != KERN_SUCCESS)
        return st;
    auto load = reinterpret_cast<processor_cpu_load_info_t>(info);
    std::vector<uint64_t> ticks(cpuCount * 4);
    for (natural_t i = 0; i < cpuCount; ++i) {
        ticks[i * 4 + 0] = load[i].cpu_ticks[CPU_STATE_USER];
        ticks[i * 4 + 1] = load[i].cpu_ticks[CPU_STATE_SYSTEM];
        ticks[i * 4 + 2] = load[i].cpu_ticks[CPU_STATE_IDLE];
        ticks[i * 4 + 3] = load[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));

    st.perCore.assign(cpuCount, 0.0);
    st.perCoreSystem.assign(cpuCount, 0.0);
    if (m_prevTicks.size() == ticks.size()) {
        double sumUser = 0, sumSys = 0, sumIdle = 0, sumAll = 0;
        for (natural_t i = 0; i < cpuCount; ++i) {
            double du = double(ticks[i * 4 + 0] - m_prevTicks[i * 4 + 0]);
            double ds = double(ticks[i * 4 + 1] - m_prevTicks[i * 4 + 1]);
            double di = double(ticks[i * 4 + 2] - m_prevTicks[i * 4 + 2]);
            double dn = double(ticks[i * 4 + 3] - m_prevTicks[i * 4 + 3]);
            double all = du + ds + di + dn;
            st.perCore[i] = all > 0 ? (du + ds + dn) * 100.0 / all : 0.0;
            st.perCoreSystem[i] = all > 0 ? ds * 100.0 / all : 0.0;
            sumUser += du + dn; sumSys += ds; sumIdle += di; sumAll += all;
        }
        if (sumAll > 0) {
            st.user = sumUser * 100.0 / sumAll;
            st.system = sumSys * 100.0 / sumAll;
            st.idle = sumIdle * 100.0 / sumAll;
            st.total = st.user + st.system;
        }
    }
    m_prevTicks = std::move(ticks);
    return st;
}

// --------------------------------------------------------------- pamięć
MemStats readMemStats() {
    MemStats m;
    m.total = sysctlU64("hw.memsize");
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    m.pageSize = pageSize;

    vm_statistics64_data_t vm{};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        const uint64_t ps = pageSize;
        uint64_t internal = vm.internal_page_count;
        uint64_t purgeable = vm.purgeable_count;
        m.app = (internal > purgeable ? internal - purgeable : 0) * ps;
        m.wired = uint64_t(vm.wire_count) * ps;
        m.compressed = uint64_t(vm.compressor_page_count) * ps;
        m.cached = (uint64_t(vm.external_page_count) + purgeable) * ps;
        m.free = uint64_t(vm.free_count) * ps;
        m.used = m.app + m.wired + m.compressed;
        m.pageIns = vm.pageins;
        m.pageOuts = vm.pageouts;
        m.active = uint64_t(vm.active_count) * ps;
        m.inactive = uint64_t(vm.inactive_count) * ps;
        m.speculative = uint64_t(vm.speculative_count) * ps;
        m.purgeable = purgeable * ps;
        m.external = uint64_t(vm.external_page_count) * ps;
        m.freeCount = uint64_t(vm.free_count) * ps;
        m.faults = vm.faults;
        m.cowFaults = vm.cow_faults;
        m.lookups = vm.lookups;
        m.hits = vm.hits;
        m.compressions = vm.compressions;
        m.decompressions = vm.decompressions;
        m.swapIns = vm.swapins;
        m.swapOuts = vm.swapouts;
    }
    m.pressureLevel = int(sysctlU64("kern.memorystatus_vm_pressure_level"));
    if (m.pressureLevel == 0) m.pressureLevel = 1;
    m.freePercent = int(sysctlU64("kern.memorystatus_level"));
    xsw_usage sw{}; size_t len = sizeof sw;
    if (sysctlbyname("vm.swapusage", &sw, &len, nullptr, 0) == 0) {
        m.swapTotal = sw.xsu_total;
        m.swapUsed = sw.xsu_used;
        m.swapFree = sw.xsu_avail;
    }
    return m;
}

// ----------------------------------------------------------------- sieć
NetStats NetSampler::sample() {
    NetStats s;
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    if (sysctl(mib, 6, nullptr, &len, nullptr, 0) != 0) return s;
    std::vector<char> buf(len);
    if (sysctl(mib, 6, buf.data(), &len, nullptr, 0) != 0) return s;
    for (char* p = buf.data(); p < buf.data() + len;) {
        auto* ifm = reinterpret_cast<if_msghdr*>(p);
        if (ifm->ifm_msglen == 0) break;
        if (ifm->ifm_type == RTM_IFINFO2) {
            auto* ifm2 = reinterpret_cast<if_msghdr2*>(p);
            if (!(ifm2->ifm_flags & IFF_LOOPBACK)) {
                s.rxBytes += ifm2->ifm_data.ifi_ibytes;
                s.txBytes += ifm2->ifm_data.ifi_obytes;
                s.rxPackets += ifm2->ifm_data.ifi_ipackets;
                s.txPackets += ifm2->ifm_data.ifi_opackets;
            }
        }
        p += ifm->ifm_msglen;
    }
    const uint64_t now = nowNs();
    if (m_has && now > m_prevWallNs) {
        double dt = double(now - m_prevWallNs) / 1e9;
        auto rate = [dt](uint64_t a, uint64_t b) { return a >= b ? double(a - b) / dt : 0.0; };
        s.rxRate = rate(s.rxBytes, m_prev.rxBytes);
        s.txRate = rate(s.txBytes, m_prev.txBytes);
        s.rxPacketRate = rate(s.rxPackets, m_prev.rxPackets);
        s.txPacketRate = rate(s.txPackets, m_prev.txPackets);
    }
    m_prev = s; m_prevWallNs = now; m_has = true;
    return s;
}

// ----------------------------------------------------- pojedyncze dyski
static std::string cfStr(CFDictionaryRef d, CFStringRef key) {
    if (!d) return {};
    auto v = (CFStringRef)CFDictionaryGetValue(d, key);
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return {};
    char buf[256] = {0};
    CFStringGetCString(v, buf, sizeof(buf), kCFStringEncodingUTF8);
    return buf;
}

static void copyStr(char* dst, size_t cap, const std::string& src) {
    if (cap == 0) return;
    std::strncpy(dst, src.c_str(), cap - 1);
    dst[cap - 1] = '\0';
}

int diskDevices(SCDiskDevice* out, int max) {
    if (!out || max <= 0) return 0;
    int n = 0;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &it) != KERN_SUCCESS) return 0;
    io_registry_entry_t drive;
    while ((drive = IOIteratorNext(it)) != IO_OBJECT_NULL && n < max) {
        SCDiskDevice d = {};
        CFMutableDictionaryRef props = nullptr;
        if (IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            auto stats = (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR(kIOBlockStorageDriverStatisticsKey));
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                d.readBytes = std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey), 0));
                d.writeBytes = std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey), 0));
            }
            CFRelease(props);
        }
        // rodzic: urządzenie blokowe z nazwą produktu i rodzajem nośnika
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(drive, kIOServicePlane, &parent) == KERN_SUCCESS && parent) {
            CFMutableDictionaryRef pp = nullptr;
            if (IORegistryEntryCreateCFProperties(parent, &pp, kCFAllocatorDefault, 0) == KERN_SUCCESS && pp) {
                auto dev = (CFDictionaryRef)CFDictionaryGetValue(pp, CFSTR("Device Characteristics"));
                auto proto = (CFDictionaryRef)CFDictionaryGetValue(pp, CFSTR("Protocol Characteristics"));
                std::string name = cfStr(dev, CFSTR("Product Name"));
                std::string vendor = cfStr(dev, CFSTR("Vendor Name"));
                if (name.empty()) name = vendor;
                else if (!vendor.empty() && name.find(vendor) == std::string::npos) name = vendor + " " + name;
                copyStr(d.name, sizeof(d.name), name);
                std::string medium = cfStr(dev, CFSTR("Medium Type"));
                copyStr(d.medium, sizeof(d.medium), medium.find("Solid") != std::string::npos ? "SSD"
                                                   : (medium.empty() ? "" : "HDD"));
                copyStr(d.interconnect, sizeof(d.interconnect), cfStr(proto, CFSTR("Physical Interconnect")));
                d.internalDisk = cfStr(proto, CFSTR("Physical Interconnect Location")) == "Internal" ? 1 : 0;
                CFRelease(pp);
            }
            IOObjectRelease(parent);
        }
        // architektura: klasa kontrolera w drzewie IOKit nad urządzeniem blokowym
        {
            io_registry_entry_t node = drive;
            IOObjectRetain(node);
            for (int depth = 0; depth < 8 && node != IO_OBJECT_NULL; ++depth) {
                io_name_t className = {0};
                if (IOObjectGetClass(node, className) == KERN_SUCCESS) {
                    std::string c = className;
                    const char* arch = nullptr;
                    if (c.find("NVMe") != std::string::npos || c.find("ANS") != std::string::npos) arch = "NVMe";
                    else if (c.find("AHCI") != std::string::npos || c.find("SATA") != std::string::npos) arch = "SATA (AHCI)";
                    else if (c.find("USBMassStorage") != std::string::npos || c.find("USBMSC") != std::string::npos) arch = "USB Mass Storage";
                    else if (c.find("SDHC") != std::string::npos || c.find("SDXC") != std::string::npos) arch = "Czytnik kart SD";
                    else if (c.find("DiskImage") != std::string::npos) arch = "Obraz dysku";
                    if (arch && d.architecture[0] == '\0') copyStr(d.architecture, sizeof(d.architecture), arch);
                    // parametry łącza PCIe czytamy z kontrolera NVMe
                    if (arch && std::string(arch) == "NVMe" && d.link[0] == '\0') {
                        auto status = (CFNumberRef)IORegistryEntrySearchCFProperty(node, kIOServicePlane, CFSTR("IOPCIExpressLinkStatus"),
                                                                                   kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
                        if (status && CFGetTypeID(status) == CFNumberGetTypeID()) {
                            int32_t v = 0;
                            CFNumberGetValue(status, kCFNumberSInt32Type, &v);
                            const int speed = v & 0xF;            // 1 = 2.5 GT/s, 2 = 5, 3 = 8, 4 = 16, 5 = 32
                            const int width = (v >> 4) & 0x3F;
                            const char* gen = speed == 1 ? "1.0" : speed == 2 ? "2.0" : speed == 3 ? "3.0"
                                            : speed == 4 ? "4.0" : speed == 5 ? "5.0" : nullptr;
                            char buf[48];
                            if (gen && width > 0) { snprintf(buf, sizeof buf, "PCIe %s x%d", gen, width); copyStr(d.link, sizeof(d.link), buf); }
                            else if (width > 0) { snprintf(buf, sizeof buf, "PCIe x%d", width); copyStr(d.link, sizeof(d.link), buf); }
                        }
                        if (status) CFRelease(status);
                    }
                }
                io_registry_entry_t parent = IO_OBJECT_NULL;
                if (IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) != KERN_SUCCESS) { IOObjectRelease(node); break; }
                IOObjectRelease(node);
                node = parent;
                if (d.architecture[0] != '\0' && d.link[0] != '\0') { IOObjectRelease(node); node = IO_OBJECT_NULL; break; }
            }
            if (node != IO_OBJECT_NULL) IOObjectRelease(node);
        }

        // dziecko: IOMedia całego dysku z nazwą BSD i pojemnością
        io_iterator_t kids = IO_OBJECT_NULL;
        if (IORegistryEntryGetChildIterator(drive, kIOServicePlane, &kids) == KERN_SUCCESS) {
            io_registry_entry_t kid;
            while ((kid = IOIteratorNext(kids)) != IO_OBJECT_NULL) {
                CFMutableDictionaryRef kp = nullptr;
                if (IORegistryEntryCreateCFProperties(kid, &kp, kCFAllocatorDefault, 0) == KERN_SUCCESS && kp) {
                    copyStr(d.bsd, sizeof(d.bsd), cfStr(kp, CFSTR("BSD Name")));
                    d.size = (uint64_t)std::max<int64_t>(0, cfNumber(kp, CFSTR("Size"), 0));
                    auto rem = (CFBooleanRef)CFDictionaryGetValue(kp, CFSTR("Removable"));
                    if (rem && CFGetTypeID(rem) == CFBooleanGetTypeID()) d.removable = CFBooleanGetValue(rem) ? 1 : 0;
                    CFRelease(kp);
                }
                IOObjectRelease(kid);
                if (d.bsd[0]) break;
            }
            IOObjectRelease(kids);
        }
        IOObjectRelease(drive);
        // czytnik bez włożonego nośnika: brak nazwy BSD i zerowa pojemność
        if (d.bsd[0] == '\0' && d.size == 0) continue;
        // obrazy dysków (DMG) i inne wirtualne nośniki nie są dyskami fizycznymi
        if (std::string(d.interconnect) == "Virtual Interface") continue;
        out[n++] = d;
    }
    IOObjectRelease(it);
    return n;
}

// ----------------------------------------------------------------- dysk
DiskStats DiskSampler::sample() {
    DiskStats s;
    int driveCount = 0;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &it) == KERN_SUCCESS) {
        io_registry_entry_t drive;
        while ((drive = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            CFMutableDictionaryRef props = nullptr;
            if (IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                auto stats = (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR(kIOBlockStorageDriverStatisticsKey));
                if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                    s.readBytes  += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey), 0));
                    s.writeBytes += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey), 0));
                    s.readOps    += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsReadsKey), 0));
                    s.writeOps   += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsWritesKey), 0));
                    s.readTimeNs  += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsTotalReadTimeKey), 0));
                    s.writeTimeNs += std::max<int64_t>(0, cfNumber(stats, CFSTR(kIOBlockStorageDriverStatisticsTotalWriteTimeKey), 0));
                }
                CFRelease(props);
            }
            IOObjectRelease(drive);
            driveCount++;
        }
        IOObjectRelease(it);
    }
    const uint64_t now = nowNs();
    if (m_has && now > m_prevWallNs) {
        double dt = double(now - m_prevWallNs) / 1e9;
        auto rate = [dt](uint64_t a, uint64_t b) { return a >= b ? double(a - b) / dt : 0.0; };
        s.readRate = rate(s.readBytes, m_prev.readBytes);
        s.writeRate = rate(s.writeBytes, m_prev.writeBytes);
        s.readOpsRate = rate(s.readOps, m_prev.readOps);
        s.writeOpsRate = rate(s.writeOps, m_prev.writeOps);
        double busyNs = double((s.readTimeNs + s.writeTimeNs) - (m_prev.readTimeNs + m_prev.writeTimeNs));
        double ops = double((s.readOps + s.writeOps) - (m_prev.readOps + m_prev.writeOps));
        const double window = double(now - m_prevWallNs) * std::max(1, driveCount);
        s.activeFraction = std::min(1.0, std::max(0.0, busyNs / window));
        s.avgResponseMs = ops > 0 ? busyNs / ops / 1e6 : 0;
    }
    // pojemność i liczba dysków fizycznych (IOMedia Whole = true), odświeżana co ~30 s
    static uint64_t cachedCap = 0; static int cachedCount = 0; static uint64_t cachedAt = 0;
    if (now - cachedAt > 30ull * 1000000000ull || cachedAt == 0) {
        cachedCap = 0; cachedCount = 0; cachedAt = now;
        CFMutableDictionaryRef match = IOServiceMatching("IOMedia");
        if (match) {
            CFDictionarySetValue(match, CFSTR("Whole"), kCFBooleanTrue);
            io_iterator_t it2 = IO_OBJECT_NULL;
            if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it2) == KERN_SUCCESS) {
                io_registry_entry_t m;
                while ((m = IOIteratorNext(it2)) != IO_OBJECT_NULL) {
                    CFTypeRef size = IORegistryEntryCreateCFProperty(m, CFSTR("Size"), kCFAllocatorDefault, 0);
                    CFTypeRef bsd = IORegistryEntryCreateCFProperty(m, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                    std::string name = cfString(bsd);
                    // tylko dyski fizyczne diskN (bez woluminów APFS/synthesized "diskNsM" i bez obrazów bez nazwy)
                    bool physical = name.rfind("disk", 0) == 0 && name.size() > 4 && std::all_of(name.begin() + 4, name.end(), [](char ch) { return ch >= '0' && ch <= '9'; });
                    // pomiń syntetyczne dyski APFS i obrazy dysków (wirtualny interfejs)
                    if (IOObjectConformsTo(m, "AppleAPFSMedia")) physical = false;
                    if (physical) {
                        CFTypeRef proto = IORegistryEntrySearchCFProperty(m, kIOServicePlane, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
                        if (proto && CFGetTypeID(proto) == CFDictionaryGetTypeID()) {
                            std::string ic = cfDictString((CFDictionaryRef)proto, CFSTR("Physical Interconnect"));
                            if (ic == "Virtual Interface") physical = false;
                        }
                        if (proto) CFRelease(proto);
                    }
                    if (size && CFGetTypeID(size) == CFNumberGetTypeID() && physical) {
                        int64_t v = 0; CFNumberGetValue((CFNumberRef)size, kCFNumberSInt64Type, &v);
                        CFTypeRef content = IORegistryEntryCreateCFProperty(m, CFSTR("Content"), kCFAllocatorDefault, 0);
                        std::string c = cfString(content);
                        if (content) CFRelease(content);
                        if (c != "Apple_APFS_Container" && c != "Apple_HFS" && c != "Apple_APFS") { cachedCap += uint64_t(v); cachedCount++; }
                    }
                    if (size) CFRelease(size);
                    if (bsd) CFRelease(bsd);
                    IOObjectRelease(m);
                }
                IOObjectRelease(it2);
            }
        }
    }
    s.capacityBytes = cachedCap; s.diskCount = cachedCount;
    m_prev = s; m_prevWallNs = now; m_has = true;
    return s;
}

std::vector<VolumeInfo> readVolumes() {
    std::vector<VolumeInfo> out;
    int n = getfsstat(nullptr, 0, MNT_NOWAIT);
    if (n <= 0) return out;
    std::vector<struct statfs> fs(n + 8);
    n = getfsstat(fs.data(), int(fs.size() * sizeof(struct statfs)), MNT_NOWAIT);
    for (int i = 0; i < n; ++i) {
        const struct statfs& f = fs[i];
        if (f.f_flags & MNT_DONTBROWSE) continue;          // woluminy ukryte/systemowe
        if (f.f_blocks == 0) continue;
        if (strcmp(f.f_fstypename, "devfs") == 0 || strcmp(f.f_fstypename, "autofs") == 0) continue;
        VolumeInfo v;
        v.mount = f.f_mntonname;
        v.device = f.f_mntfromname;
        v.fs = f.f_fstypename;
        v.total = uint64_t(f.f_blocks) * f.f_bsize;
        v.free = uint64_t(f.f_bavail) * f.f_bsize;
        v.used = v.total > v.free ? v.total - v.free : 0;
        v.local = (f.f_flags & MNT_LOCAL) != 0;
        out.push_back(v);
    }
    return out;
}

// -------------------------------------------------------------- bateria
BatteryInfo readBattery() {
    BatteryInfo b;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info) {
        CFArrayRef list = IOPSCopyPowerSourcesList(info);
        if (list) {
            for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
                if (!d) continue;
                if (cfDictString(d, CFSTR(kIOPSTypeKey)) != kIOPSInternalBatteryType) continue;
                b.present = cfNumber(d, CFSTR(kIOPSIsPresentKey), 1) != 0;
                int64_t cur = cfNumber(d, CFSTR(kIOPSCurrentCapacityKey), 0);
                int64_t max = cfNumber(d, CFSTR(kIOPSMaxCapacityKey), 100);
                b.percent = max > 0 ? int(cur * 100 / max) : 0;
                b.charging = cfNumber(d, CFSTR(kIOPSIsChargingKey), 0) != 0;
                b.onAC = cfDictString(d, CFSTR(kIOPSPowerSourceStateKey)) == kIOPSACPowerValue;
                b.timeToEmptyMin = int(cfNumber(d, CFSTR(kIOPSTimeToEmptyKey), -1));
                b.timeToFullMin = int(cfNumber(d, CFSTR(kIOPSTimeToFullChargeKey), -1));
                b.health = cfDictString(d, CFSTR(kIOPSBatteryHealthKey));
                break;
            }
            CFRelease(list);
        }
        CFRelease(info);
    }
    if (!b.present) return b;

    // Szczegóły z IORegistry (AppleSmartBattery)
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (svc != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = nullptr;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            b.cycleCount = int(cfNumber(props, CFSTR("CycleCount"), -1));
            b.voltage_mV = int(cfNumber(props, CFSTR("Voltage"), 0));
            b.amperage_mA = int(cfNumber(props, CFSTR("Amperage"), 0));
            int64_t temp = cfNumber(props, CFSTR("Temperature"), 0);
            if (temp > 0) b.temperatureC = temp / 100.0;
            b.designCapacity = int(cfNumber(props, CFSTR("DesignCapacity"), -1));
            b.nominalCapacity = int(cfNumber(props, CFSTR("AppleRawMaxCapacity"), -1));
            auto bd = (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR("BatteryData"));
            if (bd && CFGetTypeID(bd) == CFDictionaryGetTypeID()) {
                if (b.designCapacity <= 0) b.designCapacity = int(cfNumber(bd, CFSTR("DesignCapacity"), -1));
                if (b.nominalCapacity <= 0) b.nominalCapacity = int(cfNumber(bd, CFSTR("NominalChargeCapacity"), -1));
                if (b.nominalCapacity <= 0) b.nominalCapacity = int(cfNumber(bd, CFSTR("FullChargeCapacity"), -1));
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    return b;
}

// ------------------------------------------------------------ interfejsy
// opis medium (prędkość i dupleks) z ioctl SIOCGIFMEDIA
static void readMedia(const std::string& name, NetInterface& ni) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return;
    struct ifmediareq ifmr = {};
    std::strncpy(ifmr.ifm_name, name.c_str(), sizeof(ifmr.ifm_name) - 1);
    if (ioctl(sock, SIOCGIFMEDIA, &ifmr) == 0 && (ifmr.ifm_status & IFM_AVALID)) {
        const int active = ifmr.ifm_active;
        const char* desc = nullptr;
        int speed = 0;
        switch (IFM_SUBTYPE(active)) {
            case IFM_10_T: desc = "10baseT"; speed = 10; break;
            case IFM_100_TX: desc = "100baseTX"; speed = 100; break;
            case IFM_1000_T: desc = "1000baseT"; speed = 1000; break;
            case IFM_2500_T: desc = "2500baseT"; speed = 2500; break;
            case IFM_5000_T: desc = "5000baseT"; speed = 5000; break;
            case IFM_10G_T: desc = "10GbaseT"; speed = 10000; break;
            case IFM_AUTO: desc = "auto"; break;
            default: desc = nullptr; break;
        }
        std::string m = desc ? desc : "";
        if (IFM_TYPE(active) == IFM_IEEE80211) m = "IEEE 802.11";
        if (active & IFM_FDX) m += m.empty() ? "full-duplex" : " full-duplex";
        else if (active & IFM_HDX) m += m.empty() ? "half-duplex" : " half-duplex";
        if (!(ifmr.ifm_status & IFM_ACTIVE)) m += m.empty() ? "brak łącza" : " (brak łącza)";
        ni.media = m;
        ni.linkSpeedMbps = speed;
    }
    struct ifreq ifr = {};
    std::strncpy(ifr.ifr_name, name.c_str(), sizeof(ifr.ifr_name) - 1);
    if (ioctl(sock, SIOCGIFMTU, &ifr) == 0) ni.mtu = ifr.ifr_mtu;
    close(sock);
}

// MAC z IOKit – getifaddrs zwraca aplikacjom 02:00:00:00:00:00
static std::string macFromIOKit(const std::string& bsd) {
    std::string out;
    CFMutableDictionaryRef match = IOServiceMatching("IOEthernetInterface");
    if (!match) return out;
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, bsd.c_str(), kCFStringEncodingUTF8);
    CFDictionarySetValue(props, CFSTR("BSD Name"), name);
    CFDictionarySetValue(match, CFSTR(kIOPropertyMatchKey), props);
    CFRelease(props); CFRelease(name);
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return out;
    io_object_t svc;
    while ((svc = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        io_object_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS) {
            auto data = (CFDataRef)IORegistryEntryCreateCFProperty(parent, CFSTR("IOMACAddress"), kCFAllocatorDefault, 0);
            if (data && CFGetTypeID(data) == CFDataGetTypeID() && CFDataGetLength(data) == 6) {
                const UInt8* m = CFDataGetBytePtr(data);
                char buf[32];
                snprintf(buf, sizeof buf, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
                out = buf;
            }
            if (data) CFRelease(data);
            IOObjectRelease(parent);
        }
        IOObjectRelease(svc);
        if (!out.empty()) break;
    }
    IOObjectRelease(it);
    return out;
}

std::vector<NetInterface> readInterfaces() {
    std::map<std::string, NetInterface> byName;
    struct ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return {};
    for (struct ifaddrs* a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || !a->ifa_name) continue;
        NetInterface& ni = byName[a->ifa_name];
        ni.name = a->ifa_name;
        ni.up = (a->ifa_flags & IFF_UP) && (a->ifa_flags & IFF_RUNNING);
        char buf[INET6_ADDRSTRLEN];
        ni.loopback = a->ifa_flags & IFF_LOOPBACK;
        ni.pointToPoint = a->ifa_flags & IFF_POINTOPOINT;
        ni.multicastCapable = a->ifa_flags & IFF_MULTICAST;
        if (a->ifa_addr->sa_family == AF_INET) {
            auto* sin = reinterpret_cast<sockaddr_in*>(a->ifa_addr);
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) ni.addrs.insert(ni.addrs.begin(), buf);
            if (a->ifa_netmask) {
                auto* nm = reinterpret_cast<sockaddr_in*>(a->ifa_netmask);
                char nb[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET, &nm->sin_addr, nb, sizeof nb)) ni.netmask = nb;
            }
            if (a->ifa_dstaddr && (a->ifa_flags & IFF_BROADCAST)) {
                auto* br = reinterpret_cast<sockaddr_in*>(a->ifa_dstaddr);
                char bb[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET, &br->sin_addr, bb, sizeof bb)) ni.broadcast = bb;
            }
        } else if (a->ifa_addr->sa_family == AF_INET6) {
            auto* sin6 = reinterpret_cast<sockaddr_in6*>(a->ifa_addr);
            if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) continue;
            if (inet_ntop(AF_INET6, &sin6->sin6_addr, buf, sizeof buf)) ni.addrs.push_back(buf);
        } else if (a->ifa_addr->sa_family == AF_LINK) {
            auto* sdl = reinterpret_cast<sockaddr_dl*>(a->ifa_addr);
            if (sdl->sdl_alen == 6) {
                const unsigned char* m = reinterpret_cast<const unsigned char*>(LLADDR(sdl));
                char mac[32];
                snprintf(mac, sizeof mac, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
                ni.mac = mac;
            }
            if (a->ifa_data) {
                auto* d = reinterpret_cast<struct if_data*>(a->ifa_data);
                ni.rxBytes = d->ifi_ibytes; ni.txBytes = d->ifi_obytes;
                ni.rxPackets = d->ifi_ipackets; ni.txPackets = d->ifi_opackets;
                ni.rxErrors = d->ifi_ierrors; ni.txErrors = d->ifi_oerrors;
                ni.drops = d->ifi_iqdrops; ni.collisions = d->ifi_collisions;
                if (ni.mtu == 0) ni.mtu = d->ifi_mtu;
            }
        }
    }
    freeifaddrs(list);
    std::vector<NetInterface> out;
    for (auto& [name, ni] : byName) {
        if (name == "lo0") continue;
        if (ni.addrs.empty() && ni.rxBytes == 0 && ni.txBytes == 0) continue;
        // system ukrywa MAC przed zwykłymi aplikacjami – bierzemy go wtedy z IORegistry
        readMedia(name, ni);
        if (ni.mac.empty() || ni.mac == "02:00:00:00:00:00") {
            std::string m = macFromIOKit(name);
            if (!m.empty()) ni.mac = m;
        }
        out.push_back(ni);
    }
    return out;
}

// ---------------------------------------------------------------- sprzęt
static void readGpu(HardwareInfo& hw) {
    // Apple Silicon: klasa AGXAccelerator ma "model" i "gpu-core-count"
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS) {
        io_registry_entry_t e;
        while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            CFMutableDictionaryRef props = nullptr;
            if (IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                std::string model = cfDictString(props, CFSTR("model"));
                int cores = int(cfNumber(props, CFSTR("gpu-core-count"), 0));
                if (!model.empty() && hw.gpuName.empty()) hw.gpuName = model;
                if (cores > 0 && hw.gpuCores == 0) hw.gpuCores = cores;
                CFRelease(props);
            }
            IOObjectRelease(e);
            if (!hw.gpuName.empty()) break;
        }
        IOObjectRelease(it);
    }
    if (!hw.gpuName.empty()) return;
    // Intel/AMD: urządzenie PCI klasy display z właściwością "model"
    CFMutableDictionaryRef match = IOServiceMatching("IOPCIDevice");
    if (match && IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS) {
        io_registry_entry_t e;
        while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            CFTypeRef cc = IORegistryEntryCreateCFProperty(e, CFSTR("class-code"), kCFAllocatorDefault, 0);
            CFTypeRef model = IORegistryEntryCreateCFProperty(e, CFSTR("model"), kCFAllocatorDefault, 0);
            if (cc && model && CFGetTypeID(cc) == CFDataGetTypeID()) {
                uint32_t code = 0;
                memcpy(&code, CFDataGetBytePtr((CFDataRef)cc), std::min<CFIndex>(4, CFDataGetLength((CFDataRef)cc)));
                if ((code & 0xff0000) == 0x030000) hw.gpuName = cfString(model);
            }
            if (cc) CFRelease(cc);
            if (model) CFRelease(model);
            IOObjectRelease(e);
            if (!hw.gpuName.empty()) break;
        }
        IOObjectRelease(it);
    }
}

GpuStats readGpuStats() {
    GpuStats g;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return g;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        CFTypeRef perf = IORegistryEntryCreateCFProperty(e, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (perf && CFGetTypeID(perf) == CFDictionaryGetTypeID()) {
            auto d = (CFDictionaryRef)perf;
            int64_t v;
            if ((v = cfNumber(d, CFSTR("Device Utilization %"), -1)) >= 0) g.device = std::max(g.device, double(v));
            if ((v = cfNumber(d, CFSTR("Renderer Utilization %"), -1)) >= 0) g.renderer = std::max(g.renderer, double(v));
            if ((v = cfNumber(d, CFSTR("Tiler Utilization %"), -1)) >= 0) g.tiler = std::max(g.tiler, double(v));
            if ((v = cfNumber(d, CFSTR("In use system memory"), -1)) >= 0) g.memUsed += uint64_t(v);
            if ((v = cfNumber(d, CFSTR("Alloc system memory"), -1)) >= 0) g.memAlloc += uint64_t(v);
        }
        if (perf) CFRelease(perf);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return g;
}

double readGpuUtilization() {
    double result = -1;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return -1;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        CFTypeRef perf = IORegistryEntryCreateCFProperty(e, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (perf && CFGetTypeID(perf) == CFDictionaryGetTypeID()) {
            int64_t v = cfNumber((CFDictionaryRef)perf, CFSTR("Device Utilization %"), -1);
            if (v < 0) v = cfNumber((CFDictionaryRef)perf, CFSTR("GPU Activity(%)"), -1);
            if (v >= 0) result = std::max(result, double(v));
        }
        if (perf) CFRelease(perf);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return result;
}

HardwareInfo readHardwareInfo() {
    HardwareInfo hw;
    hw.model = sysctlString("hw.model");
    hw.cpuBrand = sysctlString("machdep.cpu.brand_string");
    hw.arch = sysctlString("hw.machine");
    hw.osVersion = sysctlString("kern.osproductversion");
    hw.osBuild = sysctlString("kern.osversion");
    hw.kernel = "Darwin " + sysctlString("kern.osrelease");
    hw.hostname = sysctlString("kern.hostname");
    hw.ncpu = int(sysctlU64("hw.ncpu"));
    hw.physCpu = int(sysctlU64("hw.physicalcpu"));
    hw.perfCores = int(sysctlU64("hw.perflevel0.physicalcpu"));
    hw.effCores = int(sysctlU64("hw.perflevel1.physicalcpu"));
    hw.memTotal = sysctlU64("hw.memsize");
    hw.l2Cache = sysctlU64("hw.perflevel0.l2cachesize");
    if (!hw.l2Cache) hw.l2Cache = sysctlU64("hw.l2cachesize");
    hw.pageSize = sysctlU64("hw.pagesize");
    hw.bootTime = bootTime();
    hw.l1iCache = sysctlU64("hw.perflevel0.l1icachesize");
    hw.l1dCache = sysctlU64("hw.perflevel0.l1dcachesize");
    hw.l2CacheE = sysctlU64("hw.perflevel1.l2cachesize");
    hw.hvSupport = sysctlU64("kern.hv_support") != 0;
    hw.vmPresent = sysctlU64("kern.hv_vmm_present") != 0;
    readGpu(hw);
    return hw;
}

} // namespace sysinfo
