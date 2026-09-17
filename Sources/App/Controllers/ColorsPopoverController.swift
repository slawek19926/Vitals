// ColorsPopoverController.swift - panel „Kolory” jak w TMOG: motyw aplikacji, tryb wyświetlacza, tekst VFD,
// suwaki nasycenia i poświaty (bloom) oraz przełącznik HDR.
import AppKit

final class ColorsPopoverController: NSViewController {
    static let shared = ColorsPopoverController()
    private let popover = NSPopover()

    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let vfdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let satSlider = NSSlider()
    private let bloomSlider = NSSlider()
    private let satValue = Label.make("", size: 12, weight: .semibold)
    private let bloomValue = Label.make("", size: 12, weight: .semibold)
    private let hdrSwitch = NSSwitch()
    private let hdrNote = Label.make("", size: 10.5, dim: true)

    private init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    /// Pokazuje panel przy podanym widoku (przycisk „Kolory” w pasku bocznym)
    func show(relativeTo view: NSView) {
        if popover.isShown { popover.close(); return }
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = true
        _ = view   // wymuś wczytanie widoku przed synchronizacją
        syncFromTheme()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = Label.make(L("Kolory"), size: 17, weight: .semibold)

        themePopup.addItems(withTitles: AppTheme.allCases.map { $0.title })
        themePopup.target = self; themePopup.action = #selector(themeChanged)
        displayPopup.addItems(withTitles: DisplayMode.allCases.map { $0.title })
        displayPopup.target = self; displayPopup.action = #selector(displayChanged)
        vfdPopup.addItems(withTitles: VFDText.allCases.map { $0.title })
        vfdPopup.target = self; vfdPopup.action = #selector(vfdChanged)
        for p in [themePopup, displayPopup, vfdPopup] { p.font = Fonts.ui(12.5); p.controlSize = .regular }

        func slider(_ s: NSSlider, action: Selector) {
            s.minValue = 0
            s.maxValue = Double(ThemeManager.sliderMax)
            s.numberOfTickMarks = ThemeManager.sliderMax + 1
            s.allowsTickMarkValuesOnly = true
            s.tickMarkPosition = .below
            s.isContinuous = true
            s.target = self
            s.action = action
        }
        slider(satSlider, action: #selector(satChanged))
        slider(bloomSlider, action: #selector(bloomChanged))

        hdrSwitch.target = self; hdrSwitch.action = #selector(hdrChanged)
        hdrSwitch.isEnabled = ThemeManager.shared.edrAvailable

        let rows = vstack([
            row("Motyw aplikacji", themePopup),
            row("Wyświetlacz", displayPopup),
            row("Tekst VFD", vfdPopup),
            separator(),
            sliderBlock(icon: "drop.fill", title: "Nasycenie", value: satValue, slider: satSlider),
            separator(),
            sliderBlock(icon: "sparkles", title: L("Poświata"), value: bloomValue, slider: bloomSlider),
            separator(),
            row("HDR", hdrSwitch, icon: "sun.max.fill"),
            hdrNote,
        ], spacing: 10)
        hdrNote.lineBreakMode = .byWordWrapping
        hdrNote.maximumNumberOfLines = 2

        let stack = vstack([title, rows], spacing: 12)
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for v in rows.arrangedSubviews { v.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        stack.pin(to: root, insets: NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18))
        root.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view = root
    }

    private func row(_ title: String, _ control: NSView, icon: String? = nil) -> NSView {
        var items: [NSView] = []
        if let icon {
            let iv = symbol(icon, size: 14, weight: .medium, color: P.textDim)
            iv.size(width: 20)
            items.append(iv)
        }
        items.append(Label.make(title, size: 13))
        items.append(spacer())
        items.append(control)
        return hstack(items, spacing: 8)
    }

    private func sliderBlock(icon: String, title: String, value: NSTextField, slider: NSSlider) -> NSView {
        let iv = symbol(icon, size: 14, weight: .medium, color: P.textDim)
        iv.size(width: 20)
        value.alignment = .right
        let head = hstack([iv, Label.make(title, size: 13), spacer(), value], spacing: 8)
        let block = vstack([head, slider], spacing: 6)
        head.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        slider.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func syncFromTheme() {
        let t = ThemeManager.shared
        themePopup.selectItem(at: t.appTheme.rawValue)
        displayPopup.selectItem(at: t.display.rawValue)
        vfdPopup.selectItem(at: t.vfdText.rawValue)
        satSlider.integerValue = t.saturation
        bloomSlider.integerValue = t.bloom
        hdrSwitch.state = t.hdr && t.edrAvailable ? .on : .off
        hdrSwitch.isEnabled = t.edrAvailable
        satValue.stringValue = "\(t.saturation) / \(ThemeManager.sliderMax)"
        bloomValue.stringValue = "\(t.bloom) / \(ThemeManager.sliderMax)"
        hdrNote.stringValue = t.edrAvailable
            ? String(format: L("Poświata wykresów wychodzi poza zakres SDR (zapas jasności ekranu %.1f×)."), t.edrHeadroom)
            : L("Ten ekran nie zgłasza rozszerzonego zakresu dynamiki.")
        satValue.textColor = P.text; bloomValue.textColor = P.text; hdrNote.textColor = P.textDim
    }

    @objc private func themeChanged() { ThemeManager.shared.setAppTheme(AppTheme(rawValue: themePopup.indexOfSelectedItem) ?? .system); syncFromTheme() }
    @objc private func displayChanged() { ThemeManager.shared.setDisplay(DisplayMode(rawValue: displayPopup.indexOfSelectedItem) ?? .color); syncFromTheme() }
    @objc private func vfdChanged() { ThemeManager.shared.setVFDText(VFDText(rawValue: vfdPopup.indexOfSelectedItem) ?? .automatic); syncFromTheme() }
    @objc private func satChanged() { ThemeManager.shared.setSaturation(satSlider.integerValue); syncFromTheme() }
    @objc private func bloomChanged() { ThemeManager.shared.setBloom(bloomSlider.integerValue); syncFromTheme() }
    @objc private func hdrChanged() { ThemeManager.shared.setHDR(hdrSwitch.state == .on); syncFromTheme() }
}
