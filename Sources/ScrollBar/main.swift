import AppKit
import QuartzCore
import ServiceManagement

// MARK: - Stock Quote

struct StockQuote {
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double

    var isUp: Bool { changePercent >= 0 }

    var formatted: String {
        let sign = isUp ? "+" : ""
        return "\(name) \(String(format: "%.2f", price)) (\(sign)\(String(format: "%.2f", changePercent))%)"
    }
}

// MARK: - Symbol Groups

enum SymbolGroup: String, CaseIterable {
    case all = "All"
    case korean = "Korean Markets"
    case us = "US Markets"
    case currency = "Currency"
    case watchlist = "Watchlist"

    var symbolKeys: [String] {
        switch self {
        case .all:       return MarketDataManager.shared.symbols.map { $0.0 }
        case .korean:    return ["^KS11", "^KQ11"]
        case .us:        return ["^DJI", "^IXIC", "^GSPC"]
        case .currency:  return ["USDKRW=X", "JPYKRW=X"]
        case .watchlist: return ["475830.KQ", "005935.KS", "032830.KS", "069500.KS", "NVDA", "CVX", "KO", "LLY"]
        }
    }
}

// MARK: - Color Tag for LED segments

enum LEDColor {
    case red, blue, white, amber

    var onColor: NSColor {
        switch self {
        case .red:   return NSColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1.0)
        case .blue:  return NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
        case .white: return NSColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1.0)
        case .amber: return NSColor(red: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        }
    }

    var dimColor: NSColor {
        switch self {
        case .red:   return NSColor(red: 0.15, green: 0.02, blue: 0.02, alpha: 1.0)
        case .blue:  return NSColor(red: 0.02, green: 0.05, blue: 0.15, alpha: 1.0)
        case .white: return NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        case .amber: return NSColor(red: 0.15, green: 0.08, blue: 0.0, alpha: 1.0)
        }
    }
}

struct ColoredSegment {
    let text: String
    let color: LEDColor
}

// MARK: - Market Data Manager

class MarketDataManager {
    static let shared = MarketDataManager()

    // (Yahoo symbol, display name)
    let symbols: [(String, String)] = [
        ("^KS11", "KOSPI"),
        ("^KQ11", "KOSDAQ"),
        ("^DJI", "DOW"),
        ("^IXIC", "NASDAQ"),
        ("^GSPC", "S&P500"),
        ("USDKRW=X", "USD/KRW"),
        ("JPYKRW=X", "JPY/KRW"),
        ("475830.KQ", "Orum"),
        ("005935.KS", "SamsungElecPF"),
        ("032830.KS", "SamsungLife"),
        ("069500.KS", "KODEX200"),
        ("NVDA", "NVIDIA"),
        ("CVX", "Chevron"),
        ("KO", "Coca-Cola"),
        ("LLY", "Eli Lilly"),
    ]

    var quotes: [StockQuote] = []
    var onUpdate: (([StockQuote]) -> Void)?
    private var refreshTimer: Timer?

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        Task {
            let symbolList = symbols.map { $0.0 }.joined(separator: ",")
            let urlStr = "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(symbolList)"
            guard let url = URL(string: urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr) else { return }

            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["quoteResponse"] as? [String: Any],
                      let results = response["result"] as? [[String: Any]] else {
                    print("Parse error: unexpected JSON structure")
                    await self.refreshViaChart()
                    return
                }

                var newQuotes: [StockQuote] = []
                for result in results {
                    let symbol = result["symbol"] as? String ?? ""
                    let displayName = self.symbols.first(where: { $0.0 == symbol })?.1 ?? symbol
                    let price = result["regularMarketPrice"] as? Double ?? 0
                    let changePct = result["regularMarketChangePercent"] as? Double ?? 0
                    newQuotes.append(StockQuote(symbol: symbol, name: displayName, price: price, changePercent: changePct))
                }

                await MainActor.run {
                    self.quotes = newQuotes
                    self.onUpdate?(newQuotes)
                }
            } catch {
                print("Market data error: \(error.localizedDescription)")
                await self.refreshViaChart()
            }
        }
    }

    private func refreshViaChart() async {
        var newQuotes: [StockQuote] = []
        for (symbol, name) in symbols {
            do {
                let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
                let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d"
                guard let url = URL(string: urlStr) else { continue }

                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chart = json["chart"] as? [String: Any],
                      let results = chart["result"] as? [[String: Any]],
                      let first = results.first,
                      let meta = first["meta"] as? [String: Any] else { continue }

                let price = meta["regularMarketPrice"] as? Double ?? 0
                let prevClose = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
                let changePct = prevClose > 0 ? ((price - prevClose) / prevClose) * 100 : 0

                newQuotes.append(StockQuote(symbol: symbol, name: name, price: price, changePercent: changePct))
            } catch {
                print("Chart API error (\(symbol)): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            if !newQuotes.isEmpty {
                self.quotes = newQuotes
                self.onUpdate?(newQuotes)
            }
        }
    }

    /// Filter quotes by symbol group
    func quotes(for group: SymbolGroup) -> [StockQuote] {
        let keys = group.symbolKeys
        return quotes.filter { keys.contains($0.symbol) }
    }
}

// MARK: - LED Dot Matrix Renderer (with color)

struct DotPixel {
    let isOn: Bool
    let color: LEDColor
}

class DotMatrixRenderer {
    let dotRows: Int
    let dotSize: CGFloat
    let dotGap: CGFloat
    let font: NSFont

    init(dotRows: Int = 16, dotSize: CGFloat = 0.55, dotGap: CGFloat = 1.0) {
        self.dotRows = dotRows
        self.dotSize = dotSize
        self.dotGap = dotGap
        let fontSize = CGFloat(dotRows)
        self.font = NSFont(name: "HelveticaNeue-Light", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .light)
    }

    var cellSize: CGFloat { dotSize + dotGap }
    var totalHeight: CGFloat { CGFloat(dotRows) * cellSize }

    func rasterize(_ segments: [ColoredSegment]) -> (grid: [[DotPixel]], cols: Int) {
        let fullText = segments.map { $0.text }.joined()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let totalSize = (fullText as NSString).size(withAttributes: attrs)
        let totalWidth = Int(ceil(totalSize.width))

        guard totalWidth > 0 else { return ([], 0) }

        var colColors = [LEDColor](repeating: .amber, count: totalWidth)
        var currentX: CGFloat = 0
        for seg in segments {
            let segWidth = (seg.text as NSString).size(withAttributes: attrs).width
            let startCol = Int(currentX)
            let endCol = min(totalWidth, Int(ceil(currentX + segWidth)))
            for col in startCol..<endCol {
                colColors[col] = seg.color
            }
            currentX += segWidth
        }

        let bitmapWidth = totalWidth
        let bitmapHeight = dotRows
        guard let context = CGContext(
            data: nil,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return ([], 0) }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        let rect = CGRect(x: 0, y: -1, width: bitmapWidth, height: bitmapHeight + 2)
        let whiteAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        (fullText as NSString).draw(in: rect, withAttributes: whiteAttrs)
        NSGraphicsContext.current = nil

        guard let data = context.data else { return ([], 0) }
        let ptr = data.bindMemory(to: UInt8.self, capacity: bitmapWidth * bitmapHeight * 4)

        var grid = [[DotPixel]](
            repeating: [DotPixel](repeating: DotPixel(isOn: false, color: .amber), count: bitmapWidth),
            count: bitmapHeight
        )
        for y in 0..<bitmapHeight {
            for x in 0..<bitmapWidth {
                let offset = ((bitmapHeight - 1 - y) * bitmapWidth + x) * 4
                let r = ptr[offset]
                let isOn = r > 80
                let color = colColors[x]
                grid[y][x] = DotPixel(isOn: isOn, color: color)
            }
        }
        return (grid, bitmapWidth)
    }
}

// MARK: - Ticker View (LED Dot Matrix with Color)

class TickerView: NSView {
    private(set) var segments: [ColoredSegment] = [ColoredSegment(text: "  Loading market data...  ", color: .amber)]
    private var speed: CGFloat = 60
    private let renderer = DotMatrixRenderer()

    private var dotGrid: [[DotPixel]] = []
    private var gridCols: Int = 0
    private var scrollOffset: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var lastTimestamp: Double = 0

    private let bgColor = NSColor(red: 0.01, green: 0.01, blue: 0.015, alpha: 1.0)
    private let gridColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        rasterize()
        startDisplayLink()
    }

    func updateSegments(_ newSegments: [ColoredSegment]) {
        segments = newSegments
        rasterize()
        scrollOffset = bounds.width
    }

    func updateSpeed(_ newSpeed: CGFloat) {
        speed = newSpeed
    }

    private func rasterize() {
        let result = renderer.rasterize(segments)
        dotGrid = result.grid
        gridCols = result.cols
    }

    private func startDisplayLink() {
        scrollOffset = bounds.width
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let dl = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, inNow, _, _, _, userInfo -> CVReturn in
            let view = Unmanaged<TickerView>.fromOpaque(userInfo!).takeUnretainedValue()
            let now = Double(inNow.pointee.videoTime) / Double(inNow.pointee.videoTimeScale)
            DispatchQueue.main.async {
                view.tick(now)
            }
            return kCVReturnSuccess
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, callback, ptr)
        CVDisplayLinkStart(dl)
        displayLink = dl
    }

    private func tick(_ now: Double) {
        if lastTimestamp > 0 {
            let dt = min(now - lastTimestamp, 0.05)
            scrollOffset -= speed * CGFloat(dt)
            let totalWidth = CGFloat(gridCols) * renderer.cellSize
            if scrollOffset < -totalWidth {
                scrollOffset = bounds.width
            }
        }
        lastTimestamp = now
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cellSize = renderer.cellSize
        let dotSize = renderer.dotSize
        let rows = renderer.dotRows

        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        let totalH = CGFloat(rows) * cellSize
        let yOffset = (bounds.height - totalH) / 2

        let startCol = max(0, Int(floor(-scrollOffset / cellSize)))
        let endCol = min(gridCols, Int(ceil((bounds.width - scrollOffset) / cellSize)) + 1)

        for row in 0..<rows {
            let y = yOffset + CGFloat(row) * cellSize
            for col in startCol..<endCol {
                let x = scrollOffset + CGFloat(col) * cellSize
                guard x + dotSize > 0, x < bounds.width else { continue }

                let pixel: DotPixel
                if row < dotGrid.count && col < dotGrid[row].count {
                    pixel = dotGrid[row][col]
                } else {
                    pixel = DotPixel(isOn: false, color: .amber)
                }

                let dotRect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                let ledColor = pixel.color

                if pixel.isOn {
                    let glow2Rect = dotRect.insetBy(dx: -1.2, dy: -1.2)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.15).cgColor)
                    ctx.fillEllipse(in: glow2Rect)
                    let glowRect = dotRect.insetBy(dx: -0.5, dy: -0.5)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.4).cgColor)
                    ctx.fillEllipse(in: glowRect)
                    ctx.setFillColor(ledColor.onColor.cgColor)
                    ctx.fillEllipse(in: dotRect)
                    let centerRect = dotRect.insetBy(dx: dotSize * 0.2, dy: dotSize * 0.2)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.7).blended(withFraction: 0.5, of: .white)!.cgColor)
                    ctx.fillEllipse(in: centerRect)
                } else {
                    ctx.setFillColor(gridColor.cgColor)
                    ctx.fillEllipse(in: dotRect)
                }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    deinit {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
        }
    }
}

// MARK: - Monitor Ticker Window (for secondary screens)

class MonitorTickerWindow: NSPanel {
    let tickerView: TickerView
    var symbolGroups: Set<SymbolGroup>
    let screen_: NSScreen
    private var tickerWidth: CGFloat

    var combinedSymbolKeys: [String] {
        if symbolGroups.contains(.all) {
            return MarketDataManager.shared.symbols.map { $0.0 }
        }
        var keys: [String] = []
        // Maintain consistent ordering
        for group in SymbolGroup.allCases where group != .all && symbolGroups.contains(group) {
            for key in group.symbolKeys where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    init(screen: NSScreen, groups: Set<SymbolGroup>, width: CGFloat = 0) {
        self.screen_ = screen
        self.symbolGroups = groups

        // Match the real menu bar height
        let menuBarHeight = NSStatusBar.system.thickness
        let tickerHeight = menuBarHeight

        // Default width: 40% of screen, centered horizontally
        let w = width > 0 ? width : screen.frame.width * 0.4
        self.tickerWidth = w
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - menuBarHeight

        let frame = NSRect(x: x, y: y, width: w, height: tickerHeight)
        tickerView = TickerView(frame: NSRect(origin: .zero, size: frame.size))

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.backgroundColor = NSColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1.0)
        self.isOpaque = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.isMovableByWindowBackground = false

        tickerView.autoresizingMask = [.width, .height]
        tickerView.wantsLayer = true
        tickerView.layer?.cornerRadius = 3
        tickerView.layer?.masksToBounds = true
        contentView = tickerView
    }

    func updateWithQuotes(_ allQuotes: [StockQuote]) {
        let keys = combinedSymbolKeys
        let filtered = allQuotes.filter { keys.contains($0.symbol) }
        let segments = Self.buildSegments(from: filtered)
        tickerView.updateSegments(segments)
    }

    func updateWidth(_ width: CGFloat) {
        tickerWidth = width
        let menuBarHeight = NSStatusBar.system.thickness
        let x = screen_.frame.midX - width / 2
        let y = screen_.frame.maxY - menuBarHeight
        setFrame(NSRect(x: x, y: y, width: width, height: menuBarHeight), display: true)
    }

    static func buildSegments(from quotes: [StockQuote]) -> [ColoredSegment] {
        if quotes.isEmpty {
            return [ColoredSegment(text: "  No data  ", color: .amber)]
        }

        var segments: [ColoredSegment] = []
        let sep = "    "

        for (i, q) in quotes.enumerated() {
            let color: LEDColor = q.isUp ? .red : .blue
            let sign = q.isUp ? "+" : ""
            segments.append(ColoredSegment(text: "\(q.name) ", color: .white))
            let priceStr = String(format: "%.2f", q.price)
            let changeStr = "(\(sign)\(String(format: "%.2f", q.changePercent))%)"
            segments.append(ColoredSegment(text: "\(priceStr) \(changeStr)", color: color))
            if i < quotes.count - 1 {
                segments.append(ColoredSegment(text: sep, color: .amber))
            }
        }
        segments.append(ColoredSegment(text: "          ", color: .amber))
        return segments
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var currentWidth: CGFloat = 700
    private var currentSpeed: CGFloat = 60

    // All ticker windows (including primary)
    private var primaryWindow: MonitorTickerWindow?
    private var secondaryWindows: [MonitorTickerWindow] = []
    private var screenObserver: Any?

    private var allTickerWindows: [MonitorTickerWindow] {
        var windows: [MonitorTickerWindow] = []
        if let pw = primaryWindow { windows.append(pw) }
        windows.append(contentsOf: secondaryWindows)
        return windows
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Small icon-only status item for menu access
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = "📊"
        }
        statusItem.menu = buildMenu()

        // Create primary screen ticker window
        if let mainScreen = NSScreen.main {
            let pw = MonitorTickerWindow(screen: mainScreen, groups: [.korean, .us, .currency], width: currentWidth)
            pw.orderFront(nil)
            primaryWindow = pw
        }

        // Auto-enable all secondary screens
        createSecondaryWindows()

        // Start market data
        MarketDataManager.shared.onUpdate = { [weak self] quotes in
            self?.updateAllWindows(quotes: quotes)
        }
        MarketDataManager.shared.start()

        // Observe screen changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Speed submenu
        let speedMenu = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speedSubmenu = NSMenu()
        for (label, spd) in [("Slow", 30), ("Normal", 60), ("Fast", 100), ("Turbo", 160)] {
            let item = NSMenuItem(title: label, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = spd
            item.state = spd == 60 ? .on : .off
            speedSubmenu.addItem(item)
        }
        speedMenu.submenu = speedSubmenu
        menu.addItem(speedMenu)

        // Width submenu (expanded range + custom)
        let widthMenu = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        let widthSubmenu = NSMenu()
        let widthOptions: [(String, Int)] = [
            ("Compact (200)", 200),
            ("Small (300)", 300),
            ("Normal (350)", 350),
            ("Wide (450)", 450),
            ("Extra Wide (550)", 550),
            ("Full (700)", 700),
        ]
        for (label, w) in widthOptions {
            let item = NSMenuItem(title: label, action: #selector(setWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = w
            item.state = w == Int(currentWidth) ? .on : .off
            widthSubmenu.addItem(item)
        }
        widthSubmenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(title: "Custom...", action: #selector(setCustomWidth), keyEquivalent: "")
        customItem.target = self
        widthSubmenu.addItem(customItem)
        widthMenu.submenu = widthSubmenu
        menu.addItem(widthMenu)

        menu.addItem(NSMenuItem.separator())

        // Monitors submenu
        let monitorsMenu = NSMenuItem(title: "Monitors", action: nil, keyEquivalent: "")
        monitorsMenu.submenu = buildMonitorSubmenu()
        monitorsMenu.tag = 9000
        menu.addItem(monitorsMenu)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        if Bundle.main.bundleIdentifier != nil {
            let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = launchAtLogin ? .on : .off
            menu.addItem(loginItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(title: "Quit ScrollBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    private func buildMonitorSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let screens = NSScreen.screens

        // Primary screen
        let primaryScreen = NSScreen.main ?? screens[0]
        let primaryEnabled = primaryWindow != nil

        let primaryToggle = NSMenuItem(
            title: "\(primaryScreen.localizedName) (Primary)",
            action: #selector(togglePrimaryTicker(_:)),
            keyEquivalent: ""
        )
        primaryToggle.target = self
        primaryToggle.state = primaryEnabled ? .on : .off
        submenu.addItem(primaryToggle)

        // Primary content group (multi-select)
        if primaryEnabled, let pw = primaryWindow {
            let groupMenu = NSMenuItem(title: "  Content", action: nil, keyEquivalent: "")
            let groupSubmenu = NSMenu()
            for group in SymbolGroup.allCases {
                let gItem = NSMenuItem(title: group.rawValue, action: #selector(togglePrimaryGroup(_:)), keyEquivalent: "")
                gItem.target = self
                gItem.representedObject = group.rawValue as NSString
                gItem.state = pw.symbolGroups.contains(group) ? .on : .off
                groupSubmenu.addItem(gItem)
            }
            groupMenu.submenu = groupSubmenu
            submenu.addItem(groupMenu)
        }

        // Secondary screens
        if screens.count > 1 {
            submenu.addItem(NSMenuItem.separator())

            for (i, screen) in screens.enumerated() {
                if screen == primaryScreen { continue }

                let existing = secondaryWindows.first { $0.screen_ == screen }
                let isEnabled = existing != nil

                let toggleItem = NSMenuItem(
                    title: "\(screen.localizedName) (Display \(i + 1))",
                    action: #selector(toggleSecondaryTicker(_:)),
                    keyEquivalent: ""
                )
                toggleItem.target = self
                toggleItem.tag = i
                toggleItem.state = isEnabled ? .on : .off
                submenu.addItem(toggleItem)

                if isEnabled, let existing = existing {
                    let groupMenu = NSMenuItem(title: "  Content", action: nil, keyEquivalent: "")
                    let groupSubmenu = NSMenu()
                    for group in SymbolGroup.allCases {
                        let gItem = NSMenuItem(
                            title: group.rawValue,
                            action: #selector(toggleSecondaryGroup(_:)),
                            keyEquivalent: ""
                        )
                        gItem.target = self
                        gItem.tag = i
                        gItem.representedObject = group.rawValue as NSString
                        gItem.state = existing.symbolGroups.contains(group) ? .on : .off
                        groupSubmenu.addItem(gItem)
                    }
                    groupMenu.submenu = groupSubmenu
                    submenu.addItem(groupMenu)
                }
            }
        }

        return submenu
    }

    private func rebuildMonitorMenu() {
        guard let menu = statusItem.menu else { return }
        for item in menu.items where item.tag == 9000 {
            item.submenu = buildMonitorSubmenu()
            break
        }
    }

    private func handleScreenChange() {
        // Reposition primary window if screen changed
        if let pw = primaryWindow, let mainScreen = NSScreen.main {
            if pw.screen_ != mainScreen {
                pw.orderOut(nil)
                let newPW = MonitorTickerWindow(screen: mainScreen, groups: pw.symbolGroups, width: currentWidth)
                newPW.tickerView.updateSpeed(currentSpeed)
                newPW.updateWithQuotes(MarketDataManager.shared.quotes)
                newPW.orderFront(nil)
                primaryWindow = newPW
            }
        }

        // Remove secondary windows whose screens are gone
        let currentScreens = NSScreen.screens
        secondaryWindows.removeAll { window in
            if !currentScreens.contains(window.screen_) {
                window.orderOut(nil)
                return true
            }
            return false
        }

        // Auto-enable any new secondary screens
        createSecondaryWindows()

        rebuildMonitorMenu()
    }

    private func createSecondaryWindows() {
        let screens = NSScreen.screens
        let primaryScreen = NSScreen.main ?? screens[0]
        for (_, screen) in screens.enumerated() {
            if screen == primaryScreen { continue }
            if secondaryWindows.contains(where: { $0.screen_ == screen }) { continue }

            let window = MonitorTickerWindow(screen: screen, groups: [.watchlist], width: currentWidth)
            window.tickerView.updateSpeed(currentSpeed)
            window.updateWithQuotes(MarketDataManager.shared.quotes)
            window.orderFront(nil)
            secondaryWindows.append(window)
        }
    }

    // MARK: - Ticker Updates

    private func updateAllWindows(quotes: [StockQuote]) {
        for window in allTickerWindows {
            window.updateWithQuotes(quotes)
        }
    }

    // MARK: - Actions

    private var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
        sender.state = launchAtLogin ? .on : .off
    }

    @objc private func refreshData() {
        MarketDataManager.shared.refresh()
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        currentSpeed = CGFloat(sender.tag)
        for w in allTickerWindows {
            w.tickerView.updateSpeed(currentSpeed)
        }
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { item in
            if item.action == #selector(setWidth(_:)) { item.state = .off }
        }
        sender.state = .on
        currentWidth = CGFloat(sender.tag)
        // Apply to all windows
        for w in allTickerWindows {
            w.updateWidth(currentWidth)
        }
    }

    @objc private func setCustomWidth() {
        let alert = NSAlert()
        alert.messageText = "Custom Width"
        alert.informativeText = "Enter width in pixels (100-800):"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.stringValue = "\(Int(currentWidth))"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let value = Int(input.stringValue), value >= 100, value <= 800 {
                currentWidth = CGFloat(value)
                for w in allTickerWindows {
                    w.updateWidth(currentWidth)
                }
                // Uncheck all preset items
                if let widthSubmenu = statusItem.menu?.items.first(where: { $0.title == "Width" })?.submenu {
                    widthSubmenu.items.forEach { item in
                        if item.action == #selector(setWidth(_:)) { item.state = .off }
                    }
                }
            }
        }
    }

    @objc private func togglePrimaryTicker(_ sender: NSMenuItem) {
        if let pw = primaryWindow {
            pw.orderOut(nil)
            primaryWindow = nil
        } else if let mainScreen = NSScreen.main {
            let pw = MonitorTickerWindow(screen: mainScreen, groups: [.korean, .us, .currency], width: currentWidth)
            pw.tickerView.updateSpeed(currentSpeed)
            pw.updateWithQuotes(MarketDataManager.shared.quotes)
            pw.orderFront(nil)
            primaryWindow = pw
        }
        rebuildMonitorMenu()
    }

    @objc private func togglePrimaryGroup(_ sender: NSMenuItem) {
        guard let groupName = sender.representedObject as? String,
              let group = SymbolGroup(rawValue: groupName),
              let pw = primaryWindow else { return }

        if group == .all {
            // "All" toggles exclusively
            pw.symbolGroups = [.all]
        } else {
            pw.symbolGroups.remove(.all)
            if pw.symbolGroups.contains(group) {
                pw.symbolGroups.remove(group)
                if pw.symbolGroups.isEmpty { pw.symbolGroups = [.all] }
            } else {
                pw.symbolGroups.insert(group)
            }
        }
        pw.updateWithQuotes(MarketDataManager.shared.quotes)
        rebuildMonitorMenu()
    }

    @objc private func toggleSecondaryTicker(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        let screenIndex = sender.tag
        guard screenIndex < screens.count else { return }
        let screen = screens[screenIndex]

        if let idx = secondaryWindows.firstIndex(where: { $0.screen_ == screen }) {
            secondaryWindows[idx].orderOut(nil)
            secondaryWindows.remove(at: idx)
        } else {
            // Default group varies by screen index
            let groupList: [SymbolGroup] = [.korean, .us, .currency, .watchlist]
            let defaultGroup = groupList[(screenIndex) % groupList.count]

            let window = MonitorTickerWindow(screen: screen, groups: [defaultGroup], width: currentWidth)
            window.tickerView.updateSpeed(currentSpeed)
            window.updateWithQuotes(MarketDataManager.shared.quotes)
            window.orderFront(nil)
            secondaryWindows.append(window)
        }
        rebuildMonitorMenu()
    }

    @objc private func toggleSecondaryGroup(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        let screenIndex = sender.tag
        guard screenIndex < screens.count else { return }
        let screen = screens[screenIndex]
        guard let groupName = sender.representedObject as? String,
              let group = SymbolGroup(rawValue: groupName) else { return }

        if let window = secondaryWindows.first(where: { $0.screen_ == screen }) {
            if group == .all {
                window.symbolGroups = [.all]
            } else {
                window.symbolGroups.remove(.all)
                if window.symbolGroups.contains(group) {
                    window.symbolGroups.remove(group)
                    if window.symbolGroups.isEmpty { window.symbolGroups = [.all] }
                } else {
                    window.symbolGroups.insert(group)
                }
            }
            window.updateWithQuotes(MarketDataManager.shared.quotes)
        }
        rebuildMonitorMenu()
    }
}

// MARK: - App Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
