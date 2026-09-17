// SysCore.h - czyste C API warstwy pomiarowej (implementacja w C++: SysInfo.cpp / SysCore.cpp)
#ifndef SYSCORE_H
#define SYSCORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SC_MAX_CORES 64

typedef struct {
    int      pid, ppid, uid;
    char     name[96];
    char     user[40];
    char     state[24];
    char     path[1024];
    double   cpuPercent;
    uint64_t memBytes;
    int      threads;
    uint64_t cpuTimeNs;
    uint64_t diskRead, diskWrite;   // łączne bajty we/wy procesu
    uint64_t contextSwitches;       // przełączenia kontekstu procesu
    int64_t  startTime;
    bool     accessible;
} SCProcess;

typedef struct {
    double total, user, system, idle;
    int    coreCount;
    double perCore[SC_MAX_CORES];
    double perCoreSystem[SC_MAX_CORES];
} SCCpu;

typedef struct {
    uint64_t total, used, app, wired, compressed, cached, freeBytes, swapUsed, swapTotal, pageSize;
    uint64_t pageIns, pageOuts;
    uint64_t active, inactive, speculative, purgeable, external, freeCount;
    uint64_t faults, cowFaults, lookups, hits;
    uint64_t compressions, decompressions, swapIns, swapOuts;
    uint64_t swapFree;
    int      pressureLevel;     // 1 = normalna, 2 = ostrzeżenie, 4 = krytyczna
    int      freePercent;       // kern.memorystatus_level (0..100)
} SCMem;

typedef struct {
    uint64_t rxBytes, txBytes, rxPackets, txPackets;
    double   rxRate, txRate, rxPacketRate, txPacketRate;
} SCNet;

typedef struct {
    uint64_t readBytes, writeBytes, readOps, writeOps;
    double   readRate, writeRate, readOpsRate, writeOpsRate;
    uint64_t readTimeNs, writeTimeNs;   // łączny czas operacji
    double   activeFraction;            // 0..1 udział czasu aktywności od poprzedniej próbki
    double   avgResponseMs;             // średni czas operacji w oknie
    uint64_t capacityBytes;             // suma pojemności dysków fizycznych
    int      diskCount;                 // liczba dysków fizycznych (IOMedia Whole)
} SCDisk;

// Pojedynczy dysk fizyczny widziany przez IOKit
typedef struct {
    char     bsd[32];        // np. disk0
    char     name[128];      // nazwa produktu
    char     interconnect[48]; // Apple Fabric, USB, Thunderbolt…
    char     medium[24];     // SSD / HDD
    char     architecture[64];   // NVMe, SATA (AHCI), USB Mass Storage, czytnik kart…
    char     link[48];           // np. „PCIe 4.0 x4” dla kontrolerów NVMe
    uint64_t size;           // pojemność w bajtach
    uint64_t readBytes, writeBytes;
    int      internalDisk;   // 1 = wewnętrzny
    int      removable;      // 1 = wymienny
} SCDiskDevice;

// Wypełnia tablicę dysków fizycznych; zwraca ich liczbę
int sc_disk_devices(SCDiskDevice* out, int max);

typedef struct {
    char     mount[256];
    char     device[128];
    char     fs[32];
    uint64_t total, freeBytes, used;
    bool     local;
} SCVolume;

typedef struct {
    bool   present;
    int    percent;
    bool   charging, onAC;
    int    timeToEmptyMin, timeToFullMin, cycleCount, designCapacity, nominalCapacity, voltage_mV, amperage_mA;
    double temperatureC;
    char   health[32];
} SCBattery;

typedef struct {
    char     name[32];
    char     mac[24];
    char     addrs[256];
    bool     up;
    uint64_t rxBytes, txBytes, rxPackets, txPackets;   // liczniki od startu systemu
    uint64_t rxErrors, txErrors, drops, collisions;
    int      mtu;
    int      linkSpeedMbps;      // 0 = nieznana (np. Wi-Fi)
    char     media[64];          // np. „1000baseT full-duplex”
    char     netmask[64];
    char     broadcast[64];
    bool     loopback, pointToPoint, multicastCapable;
} SCInterface;

typedef struct {
    char     model[64], cpuBrand[128], arch[16], osVersion[32], osBuild[32], kernel[64], hostname[128], gpuName[64];
    int      ncpu, physCpu, perfCores, effCores, gpuCores;
    uint64_t memTotal, l2Cache, pageSize;
    int64_t  bootTime;
    uint64_t l1iCache, l1dCache, l2CacheE;
    bool     hvSupport, vmPresent;
} SCHardware;

typedef struct {
    double   device, renderer, tiler;     // % wykorzystania (-1 gdy brak)
    uint64_t memUsed, memAlloc;           // pamięć GPU (bajty)
} SCGpuStats;
SCGpuStats sc_gpu_stats(void);

typedef struct {
    char   name[8];
    double value;
} SCSensor;

typedef struct {
    double sysWatts, cpuWatts, gpuWatts, aneWatts, dramWatts;
    double encoderWatts, decoderWatts, ispWatts, displayWatts;   // silnik wideo, ISP, wyświetlacz
    bool   available;
} SCPower;

// Temperatury z SMC (klucze T*, w °C). Zwraca liczbę wpisów.
int    sc_smc_read_temps(SCSensor* out, int max);
double sc_smc_read_float(const char* key);   // NaN gdy brak klucza
int    sc_smc_read_keys(char prefix, SCSensor* out, int max);   // wszystkie klucze o prefiksie
// Moc podsystemów (W) z IOReport od poprzedniego wywołania; sysWatts z SMC (PSTR)
SCPower sc_power_sample(void);
// Apple Neural Engine: liczba rdzeni i architektura (np. 16, "h16g")
bool sc_ane_info(int* cores, char* arch, int archLen);

typedef struct SCSampler SCSampler;

SCSampler* sc_sampler_create(void);
void       sc_sampler_destroy(SCSampler* s);

SCCpu  sc_sample_cpu(SCSampler* s);
SCNet  sc_sample_net(SCSampler* s);
SCDisk sc_sample_disk(SCSampler* s);
SCMem  sc_read_mem(void);

// Zwraca tablicę procesów (zwolnić przez sc_free_processes). count i totalThreads są wyjściowe.
SCProcess* sc_sample_processes(SCSampler* s, int* count, int* totalThreads);
void       sc_free_processes(SCProcess* p);

SCVolume*    sc_read_volumes(int* count);
void         sc_free_volumes(SCVolume* v);
SCInterface* sc_read_interfaces(int* count);
void         sc_free_interfaces(SCInterface* i);

SCBattery  sc_read_battery(void);
SCHardware sc_read_hardware(void);

double sc_gpu_utilization(void);      // 0..100, lub -1 gdy niedostępne
double sc_uptime_seconds(void);
void   sc_load_average(double out[3]);
bool   sc_is_root(void);

#ifdef __cplusplus
}
#endif
#endif
