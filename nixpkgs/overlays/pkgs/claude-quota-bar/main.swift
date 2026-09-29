// Menu bar gauge comparing Claude spend this month against the organization
// quota, next to how much of the month's work days have passed.
//
// Spend comes from the endpoint Claude Code's /usage uses, authenticated with
// the OAuth token Claude Code keeps in the login keychain. The token is only
// read, never refreshed: rotating it here would race Claude Code's own refresh.

import AppKit

private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
private let keychainService = "Claude Code-credentials"
private let refreshInterval: TimeInterval = 5 * 60
// Spend within a work day is spread over these hours when pacing the day bar.
private let workDayStartHour = 9
private let workDayEndHour = 17
// How far spend may run ahead of the work-day bar before it is highlighted.
private let warnAhead = 0.05
private let alarmAhead = 0.15

// MARK: - Model

struct Spend: Codable {
  var used: Double
  var limit: Double?
  var currency: String
  var fetchedAt: Date

  var fraction: Double? {
    guard let limit, limit > 0 else { return nil }
    return used / limit
  }
}

enum QuotaError: LocalizedError {
  case noCredentials
  case tokenExpired
  case http(Int)
  case badResponse

  var errorDescription: String? {
    switch self {
    case .noCredentials: return "No Claude Code login found in the keychain"
    case .tokenExpired: return "Claude Code token expired; open Claude Code to refresh it"
    case .http(let status): return "Usage request failed (HTTP \(status))"
    case .badResponse: return "Usage response had no spend data"
    }
  }
}

struct Period {
  var start: Date
  var end: Date
  var workDays: Int
  var workDaysElapsed: Double

  var workFraction: Double { workDays > 0 ? workDaysElapsed / Double(workDays) : 0 }
  var remaining: TimeInterval { max(0, end.timeIntervalSinceNow) }

  // Calendar month in local time, counting Monday-Friday as work days. Each
  // work day fills linearly across the configured work hours.
  static func current(now: Date = Date(), calendar: Calendar = .current) -> Period {
    let month = calendar.dateInterval(of: .month, for: now)!
    var workDays = 0
    var elapsed = 0.0
    var day = month.start
    while day < month.end {
      if !calendar.isDateInWeekend(day) {
        workDays += 1
        let open = calendar.date(bySettingHour: workDayStartHour, minute: 0, second: 0, of: day)!
        let close = calendar.date(bySettingHour: workDayEndHour, minute: 0, second: 0, of: day)!
        let progress = now.timeIntervalSince(open) / close.timeIntervalSince(open)
        elapsed += min(1, max(0, progress))
      }
      day = calendar.date(byAdding: .day, value: 1, to: day)!
    }
    return Period(start: month.start, end: month.end, workDays: workDays, workDaysElapsed: elapsed)
  }
}

// MARK: - Fetching

private func readAccessToken() throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
  process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
  let stdout = Pipe()
  process.standardOutput = stdout
  process.standardError = FileHandle.nullDevice
  try process.run()
  var data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  if process.terminationStatus != 0 {
    // Claude Code falls back to a plaintext file when no keychain is usable.
    let file = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/.credentials.json")
    guard let fileData = try? Data(contentsOf: file) else { throw QuotaError.noCredentials }
    data = fileData
  }
  guard
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let oauth = root["claudeAiOauth"] as? [String: Any],
    let token = oauth["accessToken"] as? String
  else { throw QuotaError.noCredentials }
  if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
    Date(timeIntervalSince1970: expiresAt / 1000) < Date()
  {
    throw QuotaError.tokenExpired
  }
  return token
}

private func money(_ value: Any?) -> (amount: Double, currency: String)? {
  guard
    let value = value as? [String: Any],
    let minor = (value["amount_minor"] as? NSNumber)?.doubleValue
  else { return nil }
  let exponent = (value["exponent"] as? NSNumber)?.doubleValue ?? 2
  return (minor / pow(10, exponent), value["currency"] as? String ?? "USD")
}

func parseSpend(_ data: Data, fetchedAt: Date = Date()) throws -> Spend {
  guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw QuotaError.badResponse
  }
  if let spend = root["spend"] as? [String: Any], let used = money(spend["used"]) {
    return Spend(
      used: used.amount, limit: money(spend["limit"])?.amount,
      currency: used.currency, fetchedAt: fetchedAt)
  }
  if let extra = root["extra_usage"] as? [String: Any],
    let used = (extra["used_credits"] as? NSNumber)?.doubleValue
  {
    let scale = pow(10, (extra["decimal_places"] as? NSNumber)?.doubleValue ?? 2)
    let limit = (extra["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale }
    return Spend(
      used: used / scale, limit: limit,
      currency: extra["currency"] as? String ?? "USD", fetchedAt: fetchedAt)
  }
  throw QuotaError.badResponse
}

func fetchSpend(completion: @escaping (Result<Spend, Error>) -> Void) {
  DispatchQueue.global(qos: .utility).async {
    let token: String
    do {
      token = try readAccessToken()
    } catch {
      completion(.failure(error))
      return
    }
    var request = URLRequest(url: usageURL, timeoutInterval: 30)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-quota-bar/1.0", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200, let data else {
        completion(.failure(QuotaError.http(status)))
        return
      }
      completion(Result { try parseSpend(data) })
    }.resume()
  }
}

// MARK: - Formatting

private func formatMoney(_ amount: Double, currency: String, fractionDigits: Int) -> String {
  let formatter = NumberFormatter()
  formatter.numberStyle = .currency
  formatter.currencyCode = currency
  formatter.minimumFractionDigits = fractionDigits
  formatter.maximumFractionDigits = fractionDigits
  return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.*f", fractionDigits, amount)
}

private func formatDuration(_ interval: TimeInterval) -> String {
  let minutes = Int(interval / 60)
  let (days, hours, mins) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
  if days > 0 { return "\(days)d \(hours)h" }
  if hours > 0 { return "\(hours)h \(mins)m" }
  return "\(mins)m"
}

private func percent(_ fraction: Double) -> String {
  String(format: "%.1f%%", fraction * 100)
}

// MARK: - Rendering

struct Gauge {
  var spend: Spend?
  var period: Period
  var stale: Bool

  var spendText: String {
    guard let spend else { return "Claude: no data" }
    let used = formatMoney(spend.used, currency: spend.currency, fractionDigits: 0)
    guard let limit = spend.limit else { return "\(used) / no cap" }
    return "\(used) / \(formatMoney(limit, currency: spend.currency, fractionDigits: 0))"
  }

  var timeText: String { "\(formatDuration(period.remaining)) left" }

  // Positive when spend is running ahead of the work days that have passed.
  var ahead: Double? { spend?.fraction.map { $0 - period.workFraction } }

  var spendColor: NSColor {
    guard let fraction = spend?.fraction, let ahead else { return .labelColor }
    if fraction >= 1 || ahead > alarmAhead { return .systemRed }
    if ahead > warnAhead { return .systemOrange }
    return .labelColor
  }
}

func renderGauge(_ gauge: Gauge, height: CGFloat, appearance: NSAppearance) -> NSImage {
  let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
  let textColor: NSColor = gauge.stale ? .secondaryLabelColor : .labelColor
  let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
  let lines = [
    NSAttributedString(string: gauge.spendText, attributes: attributes),
    NSAttributedString(string: gauge.timeText, attributes: attributes),
  ]
  let barWidth: CGFloat = 30
  let barHeight: CGFloat = 4
  let gap: CGFloat = 4
  let rowOffset: CGFloat = 5
  let textWidth = lines.map { ceil($0.size().width) }.max() ?? 0
  let size = NSSize(width: barWidth + gap + textWidth, height: height)
  let rows: [(fraction: Double, color: NSColor, text: NSAttributedString, center: CGFloat)] = [
    (gauge.spend?.fraction ?? 0, gauge.spendColor, lines[0], height / 2 + rowOffset),
    (gauge.period.workFraction, .labelColor, lines[1], height / 2 - rowOffset),
  ]

  return NSImage(size: size, flipped: false) { _ in
    appearance.performAsCurrentDrawingAppearance {
      for row in rows {
        let track = NSRect(x: 0, y: row.center - barHeight / 2, width: barWidth, height: barHeight)
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        let filled = min(1, max(0, row.fraction)) * barWidth
        if filled > 0 {
          var fill = track
          fill.size.width = max(filled, barHeight)
          (gauge.stale ? row.color.withAlphaComponent(0.5) : row.color).setFill()
          NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
        let textHeight = row.text.size().height
        row.text.draw(at: NSPoint(x: barWidth + gap, y: row.center - textHeight / 2))
      }
    }
    return true
  }
}

// MARK: - App

private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("claude-quota-bar/spend.json")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private var spend: Spend?
  private var lastError: Error?
  private var timers: [Timer] = []
  private var appearanceObservation: NSKeyValueObservation?

  func applicationDidFinishLaunching(_ notification: Notification) {
    spend = loadCachedSpend()
    menu.delegate = self
    item.menu = menu
    appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
      self?.redraw()
    }
    // The fetch timer keeps spend current; the minute timer advances the day bar.
    timers = [
      Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
        self?.refresh()
      },
      Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.redraw() },
    ]
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    redraw()
    refresh()
  }

  private var gauge: Gauge {
    let period = Period.current()
    // Spend from an earlier month says nothing about this one.
    let spend = self.spend.flatMap { $0.fetchedAt >= period.start ? $0 : nil }
    let stale = lastError != nil || spend.map { -$0.fetchedAt.timeIntervalSinceNow > 3 * refreshInterval } ?? true
    return Gauge(spend: spend, period: period, stale: stale)
  }

  private func redraw() {
    guard let button = item.button else { return }
    let gauge = self.gauge
    button.image = renderGauge(
      gauge, height: NSStatusBar.system.thickness, appearance: button.effectiveAppearance)
    button.toolTip = "Claude spend vs. work days this month"
  }

  @objc private func refresh() {
    fetchSpend { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let spend):
          self.spend = spend
          self.lastError = nil
          self.saveCachedSpend(spend)
        case .failure(let error):
          self.lastError = error
          NSLog("claude-quota-bar: %@", error.localizedDescription)
        }
        self.redraw()
      }
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let gauge = self.gauge
    let period = gauge.period
    func info(_ title: String) {
      let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      entry.isEnabled = false
      menu.addItem(entry)
    }

    if let spend = gauge.spend {
      let used = formatMoney(spend.used, currency: spend.currency, fractionDigits: 2)
      if let limit = spend.limit, let fraction = spend.fraction {
        info("Spent \(used) of \(formatMoney(limit, currency: spend.currency, fractionDigits: 2)) (\(percent(fraction)))")
        info("Remaining \(formatMoney(max(0, limit - spend.used), currency: spend.currency, fractionDigits: 2))")
      } else {
        info("Spent \(used) (no quota set)")
      }
    } else {
      info("No spend data yet")
    }
    info(String(format: "Work days %.1f of %d elapsed (%@)", period.workDaysElapsed, period.workDays, percent(period.workFraction)))
    let monthEnd = period.end.formatted(date: .abbreviated, time: .omitted)
    info("Period resets in \(formatDuration(period.remaining)) (\(monthEnd))")
    if let spend = gauge.spend, let ahead = gauge.ahead, period.workFraction > 0 {
      let pace = ahead > 0 ? "\(percent(ahead)) ahead of" : "\(percent(-ahead)) behind"
      info("Spend is \(pace) work-day pace")
      let projected = formatMoney(spend.used / period.workFraction, currency: spend.currency, fractionDigits: 0)
      info("At this pace: \(projected) by month end")
    }

    menu.addItem(.separator())
    if let lastError {
      info("⚠︎ \(lastError.localizedDescription)")
    }
    if let spend = gauge.spend {
      info("Updated \(spend.fetchedAt.formatted(date: .omitted, time: .shortened))")
    }
    menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Open Claude Usage…", action: #selector(openUsagePage), keyEquivalent: "u").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  @objc private func openUsagePage() {
    NSWorkspace.shared.open(usagePageURL)
  }

  private func loadCachedSpend() -> Spend? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode(Spend.self, from: data)
  }

  private func saveCachedSpend(_ spend: Spend) {
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(spend).write(to: cacheURL, options: .atomic)
  }
}

// MARK: - Entry point

// Headless modes for checking the numbers and the drawing without a menu bar.
//   --print         fetch once and print the gauge values
//   --render FILE   fetch once and write the gauge in light and dark as a PNG
private func runOnce(_ body: @escaping (Gauge) -> Void) -> Never {
  fetchSpend { result in
    switch result {
    case .success(let spend):
      body(Gauge(spend: spend, period: Period.current(), stale: false))
      exit(0)
    case .failure(let error):
      FileHandle.standardError.write(Data("claude-quota-bar: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  dispatchMain()
}

private func writePreview(_ gauge: Gauge, to path: String) {
  let scale: CGFloat = 4
  let height: CGFloat = 24
  let names: [NSAppearance.Name] = [.aqua, .darkAqua]
  let images = names.map { renderGauge(gauge, height: height, appearance: NSAppearance(named: $0)!) }
  let width = (images.map(\.size.width).max() ?? 0) + 16
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * 2 * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = NSSize(width: width, height: height * 2)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  for (index, image) in images.enumerated() {
    let y = CGFloat(1 - index) * height
    (index == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.15, alpha: 1)).setFill()
    NSRect(x: 0, y: y, width: width, height: height).fill()
    image.draw(at: NSPoint(x: 8, y: y), from: .zero, operation: .sourceOver, fraction: 1)
  }
  NSGraphicsContext.restoreGraphicsState()
  try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
if arguments.contains("--print") {
  runOnce { gauge in
    print(gauge.spendText)
    print(gauge.timeText)
    print(String(format: "spend %@, work days %@", percent(gauge.spend?.fraction ?? 0), percent(gauge.period.workFraction)))
  }
} else if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
  runOnce { gauge in writePreview(gauge, to: arguments[index + 1]) }
} else {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
