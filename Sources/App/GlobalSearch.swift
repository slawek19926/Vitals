// GlobalSearch.swift - wyszukiwarka po całej aplikacji: procesy, usługi, połączenia, aplikacje, czujniki
import AppKit

/// Pojedynczy wynik wyszukiwania
struct SearchHit {
    let title: String
    let subtitle: String
    let icon: String
    /// strona, którą trzeba otworzyć
    let page: Int
    /// tekst, który ma trafić do pola filtra na docelowej stronie
    let filter: String
}

enum GlobalSearch {
    /// Szuka we wszystkim, co aplikacja ma pod ręką bez dodatkowych odczytów systemu
    static func find(_ query: String, limit: Int = 12) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var hits: [SearchHit] = []

        // procesy
        let procs = Monitor.shared.latest.processes
            .filter { $0.name.lowercased().contains(q) || String($0.pid) == q || $0.path.lowercased().contains(q) }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(6)
        for p in procs {
            hits.append(SearchHit(title: p.name, subtitle: L("Proces") + " · PID \(p.pid) · \(Fmt.percent(p.cpuPercent)) CPU · \(Fmt.bytes(p.memBytes))",
                                  icon: "list.bullet.rectangle", page: 2, filter: p.name))
        }
        // dyski
        for d in Monitor.shared.latest.disks where d.name.lowercased().contains(q) || d.bsd.lowercased().contains(q) {
            hits.append(SearchHit(title: d.name.isEmpty ? d.bsd : d.name, subtitle: L("Dysk") + " · \(d.kind) · \(Fmt.bytes(d.size, precision: 0))",
                                  icon: d.icon, page: 1, filter: d.bsd))
        }
        // interfejsy sieciowe
        for i in Monitor.shared.latest.interfaces where i.name.lowercased().contains(q) || i.addrs.lowercased().contains(q) {
            let kind = NetInfo.kind(for: i.name)
            hits.append(SearchHit(title: "\(kind.display) (\(i.name))", subtitle: L("Interfejs") + " · \(kind.type) · \(i.addrs)",
                                  icon: kind.icon, page: 1, filter: i.name))
        }
        // czujniki
        for t in Monitor.shared.latest.temps where t.name.lowercased().contains(q) {
            hits.append(SearchHit(title: PowerFreqViewController.describe(t.name),
                                  subtitle: L("Czujnik") + " · \(Fmt.temp(t.value))", icon: "thermometer.medium", page: 6, filter: t.name))
        }
        // strony aplikacji
        for row in SidebarViewController.staticRows {
            if case .item(let it) = row, it.title.lowercased().contains(q) {
                hits.append(SearchHit(title: it.title, subtitle: L("Strona aplikacji"), icon: it.icon, page: it.page, filter: ""))
            }
        }
        return Array(hits.prefix(limit))
    }
}
