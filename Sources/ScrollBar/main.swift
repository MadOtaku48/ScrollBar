import AppKit
import QuartzCore
import ServiceManagement

// MARK: - Stock Quote

struct StockQuote {
    let name: String
    let price: Double
    let changePercent: Double

    var isUp: Bool { changePercent >= 0 }

    var formatted: String {
        let sign = isUp ? "+" : ""
        return "\(name) \(String(format: "%.2f", price)) (\(sign)\(String(format: "%.2f", changePercent))%)"
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
        ("475830.KQ", "OrmThera"),
    ]

    var quotes: [StockQuote] = []
    var onUpdate: (([StockQuote]) -> Void)?
    private var refreshTimer: Timer?

    func start() {
        refresh()
        // Refresh every 60 seconds
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
                    // Try v8 chart API as fallback
                    await self.refreshViaChart()
                    return
                }

                var newQuotes: [StockQuote] = []
                for result in results {
                    let symbol = result["symbol"] as? String ?? ""
                    let displayName = self.symbols.first(where: { $0.0 == symbol })?.1 ?? symbol
                    let price = result["regularMarketPrice"] as? Double ?? 0
                    let changePct = result["regularMarketChangePercent"] as? Double ?? 0
                    newQuotes.append(StockQuote(name: displayName, price: price, changePercent: changePct))
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

    // Fallback: fetch each symbol via v8 chart API
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

                newQuotes.append(StockQuote(name: name, price: price, changePercent: changePct))
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

    init(dotRows: Int = 16, dotSize: CGFloat = 0.85, dotGap: CGFloat = 0.45) {
        self.dotRows = dotRows
        self.dotSize = dotSize
        self.dotGap = dotGap
        let fontSize = CGFloat(dotRows)
        self.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    }

    var cellSize: CGFloat { dotSize + dotGap }
    var totalHeight: CGFloat { CGFloat(dotRows) * cellSize }

    /// Render colored segments into a 2D grid with color info
    func rasterize(_ segments: [ColoredSegment]) -> (grid: [[DotPixel]], cols: Int) {
        // First, calculate total text and build color map
        let fullText = segments.map { $0.text }.joined()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let totalSize = (fullText as NSString).size(withAttributes: attrs)
        let totalWidth = Int(ceil(totalSize.width))

        guard totalWidth > 0 else { return ([], 0) }

        // Build column-to-color map by measuring each segment's width
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

        // Render full text to bitmap
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
    private let gridColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0) // subtle grid dots

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
                    // Outer glow (soft bloom)
                    let glow2Rect = dotRect.insetBy(dx: -1.2, dy: -1.2)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.15).cgColor)
                    ctx.fillEllipse(in: glow2Rect)
                    // Inner glow
                    let glowRect = dotRect.insetBy(dx: -0.5, dy: -0.5)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.4).cgColor)
                    ctx.fillEllipse(in: glowRect)
                    // Bright LED dot
                    ctx.setFillColor(ledColor.onColor.cgColor)
                    ctx.fillEllipse(in: dotRect)
                    // Hot center highlight
                    let centerRect = dotRect.insetBy(dx: dotSize * 0.2, dy: dotSize * 0.2)
                    ctx.setFillColor(ledColor.onColor.withAlphaComponent(0.7).blended(withFraction: 0.5, of: .white)!.cgColor)
                    ctx.fillEllipse(in: centerRect)
                } else {
                    // Unlit LED - visible dark dot (like real LED matrix grid)
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tickerView: TickerView!
    private let tickerWidth: CGFloat = 350

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: tickerWidth)

        guard let button = statusItem.button else { return }

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1.0).cgColor
        button.layer?.cornerRadius = 3

        tickerView = TickerView(frame: button.bounds)
        tickerView.autoresizingMask = [.width, .height]
        button.addSubview(tickerView)

        // Build menu
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

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

        let widthMenu = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        let widthSubmenu = NSMenu()
        for (label, w) in [("Normal (350)", 350), ("Wide (450)", 450), ("Extra Wide (550)", 550)] {
            let item = NSMenuItem(title: label, action: #selector(setWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = w
            item.state = w == 350 ? .on : .off
            widthSubmenu.addItem(item)
        }
        widthMenu.submenu = widthSubmenu
        menu.addItem(widthMenu)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login (only works when running as .app bundle)
        if Bundle.main.bundleIdentifier != nil {
            let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = launchAtLogin ? .on : .off
            menu.addItem(loginItem)

            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(title: "Quit ScrollBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Start market data
        MarketDataManager.shared.onUpdate = { [weak self] quotes in
            self?.updateTicker(quotes: quotes)
        }
        MarketDataManager.shared.start()
    }

    private func updateTicker(quotes: [StockQuote]) {
        if quotes.isEmpty {
            tickerView.updateSegments([ColoredSegment(text: "  No data available  ", color: .amber)])
            return
        }

        var segments: [ColoredSegment] = []
        let sep = "    "

        for (i, q) in quotes.enumerated() {
            let color: LEDColor = q.isUp ? .red : .blue
            let sign = q.isUp ? "+" : ""
            // Name in white
            segments.append(ColoredSegment(text: "\(q.name) ", color: .white))
            // Price + change in color
            let priceStr = String(format: "%.2f", q.price)
            let changeStr = "(\(sign)\(String(format: "%.2f", q.changePercent))%)"
            segments.append(ColoredSegment(text: "\(priceStr) \(changeStr)", color: color))

            if i < quotes.count - 1 {
                segments.append(ColoredSegment(text: sep, color: .amber))
            }
        }
        // Trailing space for smooth loop
        segments.append(ColoredSegment(text: "          ", color: .amber))

        tickerView.updateSegments(segments)
    }

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
        tickerView.updateSpeed(CGFloat(sender.tag))
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        statusItem.length = CGFloat(sender.tag)
        tickerView.frame = statusItem.button!.bounds
    }
}

// MARK: - App Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
