// SysInfo.h - odczyt informacji o systemie macOS (procesy, CPU, pamięć, dysk, sieć, sprzęt)
// Czysty C++ bez zależności od wxWidgets.
#pragma once

#include <cstdint>
#include <ctime>
#include <string>
#include <unordered_map>
#include <vector>

#include "include/SysCore.h"

namespace sysinfo {

uint64_t nowNs();                 // monotoniczny zegar w nanosekundach
double   uptimeSeconds();
void     loadAverage(double out[3]);
bool     isRoot();

// ---------------------------------------------------------------- procesy
struct ProcessInfo {
    int         pid = 0;
    int         ppid = 0;
    int         uid = -1;
    std::string name;
    std::string path;
    std::string user;
    std::string state;          // opis stanu po polsku
    double      cpuPercent = 0; // 0..100*rdzenie
    uint64_t    memBytes = 0;   // phys footprint (jak w Monitorze aktywności)
    int         threads = 0;
    uint64_t    cpuTimeNs = 0;  // łączny czas CPU
    uint64_t    contextSwitches = 0;
    uint64_t    diskRead = 0;   // łącznie odczytane bajty (rusage)
    uint64_t    diskWrite = 0;  // łącznie zapisane bajty
    time_t      startTime = 0;
    int64_t     startTimeMicros = 0;
    bool        accessible = true; // false = brak uprawnień do szczegółów (procesy innych użytkowników)
};

class ProcessSampler {
public:
    std::vector<ProcessInfo> sample();
    int totalThreads() const { return m_totalThreads; }
private:
    struct Prev { uint64_t cpuNs; int64_t start; };
    std::unordered_map<int, Prev>        m_prev;
    std::unordered_map<int, std::string> m_pathCache;
    std::unordered_map<int, std::string> m_userCache;
    uint64_t m_prevWallNs = 0;
    int      m_totalThreads = 0;
};

// -------------------------------------------------------------------- CPU
struct CpuStats {
    double total = 0;   // 0..100
    double user = 0;
    double system = 0;
    double idle = 100;
    std::vector<double> perCore;
    std::vector<double> perCoreSystem;
};

class CpuSampler {
public:
    CpuStats sample();
private:
    std::vector<uint64_t> m_prevTicks;
};

// ----------------------------------------------------------------- pamięć
struct MemStats {
    uint64_t active = 0, inactive = 0, speculative = 0, purgeable = 0, external = 0, freeCount = 0;
    uint64_t faults = 0, cowFaults = 0, lookups = 0, hits = 0;
    uint64_t compressions = 0, decompressions = 0, swapIns = 0, swapOuts = 0, swapFree = 0;
    uint64_t total = 0;
    uint64_t used = 0;        // app + wired + compressed
    uint64_t app = 0;
    uint64_t wired = 0;
    uint64_t compressed = 0;
    uint64_t cached = 0;
    uint64_t free = 0;
    uint64_t swapUsed = 0;
    uint64_t swapTotal = 0;
    uint64_t pageSize = 0;
    uint64_t pageIns = 0, pageOuts = 0;
    int      pressureLevel = 1;
    int      freePercent = 0;
};
MemStats readMemStats();

// ------------------------------------------------------------------- sieć
struct NetStats {
    uint64_t rxBytes = 0, txBytes = 0;
    uint64_t rxPackets = 0, txPackets = 0;
    double   rxRate = 0, txRate = 0;         // B/s
    double   rxPacketRate = 0, txPacketRate = 0;
};

class NetSampler {
public:
    NetStats sample();
private:
    NetStats m_prev;
    uint64_t m_prevWallNs = 0;
    bool     m_has = false;
};

// ------------------------------------------------------------------- dysk
struct DiskStats {
    uint64_t readBytes = 0, writeBytes = 0;
    uint64_t readOps = 0, writeOps = 0;
    double   readRate = 0, writeRate = 0;    // B/s
    double   readOpsRate = 0, writeOpsRate = 0;
    uint64_t readTimeNs = 0, writeTimeNs = 0;
    double   activeFraction = 0, avgResponseMs = 0;
    uint64_t capacityBytes = 0;
    int      diskCount = 0;
};

class DiskSampler {
public:
    DiskStats sample();
private:
    DiskStats m_prev;
    uint64_t  m_prevWallNs = 0;
    bool      m_has = false;
};

struct VolumeInfo {
    std::string mount, device, fs;
    uint64_t total = 0, free = 0, used = 0;
    bool local = true;
};
std::vector<VolumeInfo> readVolumes();

// ---------------------------------------------------------------- bateria
struct BatteryInfo {
    bool        present = false;
    int         percent = 0;
    bool        charging = false;
    bool        onAC = false;
    int         timeToEmptyMin = -1;
    int         timeToFullMin = -1;
    int         cycleCount = -1;
    int         designCapacity = -1;   // mAh
    int         nominalCapacity = -1;  // mAh (aktualna maks. pojemność)
    int         voltage_mV = 0;
    int         amperage_mA = 0;
    double      temperatureC = 0;
    std::string health;
};
BatteryInfo readBattery();

// ------------------------------------------------------- interfejsy sieciowe
struct NetInterface {
    uint64_t rxBytes = 0, txBytes = 0, rxPackets = 0, txPackets = 0;
    uint64_t rxErrors = 0, txErrors = 0, drops = 0, collisions = 0;
    int mtu = 0;
    int linkSpeedMbps = 0;
    std::string media, netmask, broadcast;
    bool loopback = false, pointToPoint = false, multicastCapable = false;
    std::string name;
    std::string mac;
    std::vector<std::string> addrs;
    bool up = false;
};
std::vector<NetInterface> readInterfaces();

// ------------------------------------------------------------------ sprzęt
struct HardwareInfo {
    std::string model, cpuBrand, arch, osVersion, osBuild, kernel, hostname, gpuName;
    int      ncpu = 0, physCpu = 0, perfCores = 0, effCores = 0, gpuCores = 0;
    uint64_t memTotal = 0, l2Cache = 0, pageSize = 0;
    time_t   bootTime = 0;
    uint64_t l1iCache = 0, l1dCache = 0, l2CacheE = 0;
    bool     hvSupport = false, vmPresent = false;
};
HardwareInfo readHardwareInfo();

struct GpuStats { double device = -1, renderer = -1, tiler = -1; uint64_t memUsed = 0, memAlloc = 0; };
GpuStats readGpuStats();
double readGpuUtilization();   // 0..100 lub -1

// Wypełnia tablicę dysków fizycznych (definicja w SysInfo.cpp)
int diskDevices(SCDiskDevice* out, int max);

} // namespace sysinfo
