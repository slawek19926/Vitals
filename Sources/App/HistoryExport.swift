// HistoryExport.swift - zapis historii pomiarów do CSV: jednorazowy eksport i ciągłe nagrywanie
import Foundation

enum HistoryExport {
    static let shared = Recorder()

    /// Format pliku idzie za językiem interfejsu: polski arkusz oczekuje średnika i przecinka
    /// dziesiętnego, angielski przecinka i kropki. Format ustalany jest raz, przy starcie zapisu.
    struct Format {
        let separator: String
        let decimalComma: Bool
        let header: String

        static var current: Format {
            L10n.isEnglish
                ? Format(separator: ",", decimalComma: false,
                         header: "time,cpu_total,cpu_user,cpu_system,ram_used_B,swap_B,disk_read_Bs,disk_write_Bs,"
                               + "net_rx_Bs,net_tx_Bs,system_power_W,cpu_power_W,gpu_pct,hottest_C,battery_pct,processes,threads,top1_name,top1_cpu")
                : Format(separator: ";", decimalComma: true,
                         header: "czas;cpu_total;cpu_user;cpu_system;ram_uzyta_B;swap_B;dysk_odczyt_Bs;dysk_zapis_Bs;"
                               + "siec_odbior_Bs;siec_nadawanie_Bs;moc_systemu_W;moc_cpu_W;gpu_proc;najgoretszy_C;bateria_proc;procesy;watki;top1_nazwa;top1_cpu")
        }
    }

    static func line(_ s: HistorySample, _ fmt: Format = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func n(_ v: Double, _ p: Int = 2) -> String {
            let t = String(format: "%.\(p)f", v)
            return fmt.decimalComma ? t.replacingOccurrences(of: ".", with: ",") : t
        }
        let top = s.top.max { $0.cpu < $1.cpu }
        return [f.string(from: s.time), n(s.cpuTotal), n(s.cpuUser), n(s.cpuSystem), "\(s.memUsed)", "\(s.memSwap)",
                n(s.diskRead, 0), n(s.diskWrite, 0), n(s.netRx, 0), n(s.netTx, 0), n(s.sysWatts), n(s.cpuWatts),
                n(s.gpuUtil, 1), n(s.hotspotC, 1), "\(s.batteryPercent)", "\(s.processCount)", "\(s.threads)",
                (top?.name ?? "").replacingOccurrences(of: fmt.separator, with: " "), n(top?.cpu ?? 0, 1)]
            .joined(separator: fmt.separator)
    }

    /// Zapisuje całą historię trzymaną w pamięci
    static func writeCSV(to url: URL) throws {
        let fmt = Format.current
        var text = fmt.header + "\n"
        for s in Monitor.shared.history { text += line(s, fmt) + "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Dopisuje kolejne pomiary do pliku aż do zatrzymania
    final class Recorder {
        private var handle: FileHandle?
        private(set) var url: URL?
        private var count = 0
        /// format ustalony przy starcie zapisu – zmiana języka w trakcie nie psuje pliku
        private var fmt = Format.current
        var isRecording: Bool { handle != nil }

        func startRecording(to url: URL) {
            stopRecording()
            fmt = Format.current
            FileManager.default.createFile(atPath: url.path, contents: (fmt.header + "\n").data(using: .utf8))
            guard let h = FileHandle(forWritingAtPath: url.path) else { return }
            h.seekToEndOfFile()
            handle = h
            self.url = url
            count = 0
        }

        @discardableResult
        func stopRecording() -> URL? {
            guard let h = handle else { return nil }
            try? h.close()
            handle = nil
            let u = url
            url = nil
            return u
        }

        func record(_ s: HistorySample) {
            guard let h = handle, let data = (HistoryExport.line(s, fmt) + "\n").data(using: .utf8) else { return }
            h.write(data)
            count += 1
        }

        var sampleCount: Int { count }
    }
}
