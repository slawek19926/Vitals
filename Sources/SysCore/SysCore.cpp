// SysCore.cpp - most C++ -> C API
#include "include/SysCore.h"
#include "SysInfo.h"
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <libproc.h>

namespace {
template <size_t N>
void copyStr(char (&dst)[N], const std::string& src) {
    strncpy(dst, src.c_str(), N - 1);
    dst[N - 1] = '\0';
}
}

struct SCSampler {
    sysinfo::ProcessSampler procs;
    sysinfo::CpuSampler cpu;
    sysinfo::NetSampler net;
    sysinfo::DiskSampler disk;
};

extern "C" {

SCSampler* sc_sampler_create(void) { return new SCSampler(); }
void sc_sampler_destroy(SCSampler* s) { delete s; }

SCCpu sc_sample_cpu(SCSampler* s) {
    SCCpu out{};
    sysinfo::CpuStats st = s->cpu.sample();
    out.total = st.total; out.user = st.user; out.system = st.system; out.idle = st.idle;
    out.coreCount = std::min<int>(SC_MAX_CORES, int(st.perCore.size()));
    for (int i = 0; i < out.coreCount; ++i) { out.perCore[i] = st.perCore[i]; out.perCoreSystem[i] = i < (int)st.perCoreSystem.size() ? st.perCoreSystem[i] : 0; }
    return out;
}

SCNet sc_sample_net(SCSampler* s) {
    sysinfo::NetStats n = s->net.sample();
    return SCNet{ n.rxBytes, n.txBytes, n.rxPackets, n.txPackets, n.rxRate, n.txRate, n.rxPacketRate, n.txPacketRate };
}

SCDisk sc_sample_disk(SCSampler* s) {
    sysinfo::DiskStats d = s->disk.sample();
    return SCDisk{ d.readBytes, d.writeBytes, d.readOps, d.writeOps, d.readRate, d.writeRate, d.readOpsRate, d.writeOpsRate,
                   d.readTimeNs, d.writeTimeNs, d.activeFraction, d.avgResponseMs, d.capacityBytes, d.diskCount };
}

SCMem sc_read_mem(void) {
    sysinfo::MemStats m = sysinfo::readMemStats();
    SCMem o{};
    o.total = m.total; o.used = m.used; o.app = m.app; o.wired = m.wired; o.compressed = m.compressed;
    o.cached = m.cached; o.freeBytes = m.free; o.swapUsed = m.swapUsed; o.swapTotal = m.swapTotal; o.pageSize = m.pageSize;
    o.pageIns = m.pageIns; o.pageOuts = m.pageOuts;
    o.active = m.active; o.inactive = m.inactive; o.speculative = m.speculative; o.purgeable = m.purgeable;
    o.external = m.external; o.freeCount = m.freeCount;
    o.faults = m.faults; o.cowFaults = m.cowFaults; o.lookups = m.lookups; o.hits = m.hits;
    o.compressions = m.compressions; o.decompressions = m.decompressions;
    o.swapIns = m.swapIns; o.swapOuts = m.swapOuts; o.swapFree = m.swapFree;
    o.pressureLevel = m.pressureLevel; o.freePercent = m.freePercent;
    return o;
}

SCProcess* sc_sample_processes(SCSampler* s, int* count, int* totalThreads) {
    std::vector<sysinfo::ProcessInfo> v = s->procs.sample();
    *count = int(v.size());
    *totalThreads = s->procs.totalThreads();
    auto* out = static_cast<SCProcess*>(calloc(v.size() + 1, sizeof(SCProcess)));
    for (size_t i = 0; i < v.size(); ++i) {
        const auto& p = v[i];
        SCProcess& o = out[i];
        o.pid = p.pid; o.ppid = p.ppid; o.uid = p.uid;
        copyStr(o.name, p.name); copyStr(o.user, p.user); copyStr(o.state, p.state); copyStr(o.path, p.path);
        o.cpuPercent = p.cpuPercent; o.memBytes = p.memBytes; o.threads = p.threads;
        o.cpuTimeNs = p.cpuTimeNs; o.startTime = p.startTime; o.startTimeMicros = p.startTimeMicros; o.accessible = p.accessible;
        o.diskRead = p.diskRead; o.diskWrite = p.diskWrite;
        o.contextSwitches = p.contextSwitches;
    }
    return out;
}
void sc_free_processes(SCProcess* p) { free(p); }

SCVolume* sc_read_volumes(int* count) {
    auto v = sysinfo::readVolumes();
    *count = int(v.size());
    auto* out = static_cast<SCVolume*>(calloc(v.size() + 1, sizeof(SCVolume)));
    for (size_t i = 0; i < v.size(); ++i) {
        copyStr(out[i].mount, v[i].mount); copyStr(out[i].device, v[i].device); copyStr(out[i].fs, v[i].fs);
        out[i].total = v[i].total; out[i].freeBytes = v[i].free; out[i].used = v[i].used; out[i].local = v[i].local;
    }
    return out;
}
void sc_free_volumes(SCVolume* v) { free(v); }

int sc_disk_devices(SCDiskDevice* out, int max) { return sysinfo::diskDevices(out, max); }

SCInterface* sc_read_interfaces(int* count) {
    auto v = sysinfo::readInterfaces();
    *count = int(v.size());
    auto* out = static_cast<SCInterface*>(calloc(v.size() + 1, sizeof(SCInterface)));
    for (size_t i = 0; i < v.size(); ++i) {
        copyStr(out[i].name, v[i].name); copyStr(out[i].mac, v[i].mac);
        out[i].rxBytes = v[i].rxBytes; out[i].txBytes = v[i].txBytes;
        out[i].rxPackets = v[i].rxPackets; out[i].txPackets = v[i].txPackets;
        out[i].rxErrors = v[i].rxErrors; out[i].txErrors = v[i].txErrors;
        out[i].drops = v[i].drops; out[i].collisions = v[i].collisions;
        out[i].mtu = v[i].mtu; out[i].linkSpeedMbps = v[i].linkSpeedMbps;
        copyStr(out[i].media, v[i].media); copyStr(out[i].netmask, v[i].netmask); copyStr(out[i].broadcast, v[i].broadcast);
        out[i].loopback = v[i].loopback; out[i].pointToPoint = v[i].pointToPoint; out[i].multicastCapable = v[i].multicastCapable;
        std::string addrs;
        for (const auto& a : v[i].addrs) { if (!addrs.empty()) addrs += ", "; addrs += a; }
        copyStr(out[i].addrs, addrs);
        out[i].up = v[i].up;
    }
    return out;
}
void sc_free_interfaces(SCInterface* i) { free(i); }

SCBattery sc_read_battery(void) {
    sysinfo::BatteryInfo b = sysinfo::readBattery();
    SCBattery o{};
    o.present = b.present; o.percent = b.percent; o.charging = b.charging; o.onAC = b.onAC;
    o.timeToEmptyMin = b.timeToEmptyMin; o.timeToFullMin = b.timeToFullMin; o.cycleCount = b.cycleCount;
    o.designCapacity = b.designCapacity; o.nominalCapacity = b.nominalCapacity; o.voltage_mV = b.voltage_mV;
    o.amperage_mA = b.amperage_mA; o.temperatureC = b.temperatureC;
    copyStr(o.health, b.health);
    return o;
}

SCHardware sc_read_hardware(void) {
    sysinfo::HardwareInfo h = sysinfo::readHardwareInfo();
    SCHardware o{};
    copyStr(o.model, h.model); copyStr(o.cpuBrand, h.cpuBrand); copyStr(o.arch, h.arch);
    copyStr(o.osVersion, h.osVersion); copyStr(o.osBuild, h.osBuild); copyStr(o.kernel, h.kernel);
    copyStr(o.hostname, h.hostname); copyStr(o.gpuName, h.gpuName);
    o.ncpu = h.ncpu; o.physCpu = h.physCpu; o.perfCores = h.perfCores; o.effCores = h.effCores; o.gpuCores = h.gpuCores;
    o.memTotal = h.memTotal; o.l2Cache = h.l2Cache; o.pageSize = h.pageSize; o.bootTime = h.bootTime;
    o.l1iCache = h.l1iCache; o.l1dCache = h.l1dCache; o.l2CacheE = h.l2CacheE; o.hvSupport = h.hvSupport; o.vmPresent = h.vmPresent;
    return o;
}

double sc_gpu_utilization(void) { return sysinfo::readGpuUtilization(); }
SCGpuStats sc_gpu_stats(void) {
    sysinfo::GpuStats g = sysinfo::readGpuStats();
    return SCGpuStats{ g.device, g.renderer, g.tiler, g.memUsed, g.memAlloc };
}
double sc_uptime_seconds(void) { return sysinfo::uptimeSeconds(); }
void   sc_load_average(double out[3]) { sysinfo::loadAverage(out); }
int64_t sc_process_start_time(int pid) {
    if (pid <= 1) return 0;
    proc_bsdinfo info{};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return int64_t(info.pbi_start_tvsec) * 1000000 + info.pbi_start_tvusec;
}

bool   sc_is_root(void) { return sysinfo::isRoot(); }

} // extern "C"
