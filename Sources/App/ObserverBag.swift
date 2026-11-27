// ObserverBag.swift - automatyczne wyrejestrowywanie blokowych obserwatorów NotificationCenter w deinit
import Foundation

final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func observe(_ name: Notification.Name, object: Any? = nil, queue: OperationQueue? = .main,
                 using block: @escaping (Notification) -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: queue, using: block))
    }

    func removeAll() {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}
