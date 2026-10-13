import Foundation
import Combine
import WidgetKit
import CommuteCore

@MainActor final class CommuteController: ObservableObject {
    @Published private(set) var snapshot = ProgressSnapshot.empty()
    @Published private(set) var display = DisplayState.empty()
    @Published private(set) var status = "開始ボタンで位置計測を開始します"
    @Published private(set) var liveStatus = "未開始"
    @Published private(set) var sharingStatus = ""
    @Published private(set) var isMeasuring = false
    @Published private(set) var dataset: TimetableDataset?
    @Published private(set) var diagnostic: GroupDiagnostic?
    @Published private(set) var debugRemaining = 0
    private var engine: CommuteEngine?
    private let sensors = SensorClient()
    private let live = LiveActivityClient()
    private var clock: Timer?
    private var debugObservations: [TravelObservation] = []
    private var lastSignature = ""
    private var lastReload = Date.distantPast
    private var lastPublish = Date.distantPast
    private var foreground = true
    private var screenshotConfigured = false

    init() {
        do {
            guard let url = Bundle.main.url(forResource: "Timetable", withExtension: "json") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let data = try Data(contentsOf: url)
            let loaded = try TimetableDataset.load(from: data)
            dataset = loaded
            engine = CommuteEngine(timetable: loaded)
        } catch { status = "同梱データを読めません: \(error.localizedDescription)" }
        sensors.onObservation = { [weak self] observation in self?.ingest(observation) }
        sensors.onStatus = { [weak self] message in self?.status = message }
        live.onStatus = { [weak self] message in self?.liveStatus = message }
        refreshDiagnostic()
    }

    func start() {
        guard let dataset else { return }
        live.end(display: display)
        debugObservations = []; debugRemaining = 0
        engine = CommuteEngine(timetable: dataset)
        snapshot = .empty(); display = .empty()
        lastSignature = ""
        isMeasuring = true
        publish(force: true)
        sensors.start()
        configureForegroundClock()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        configureForegroundClock()
        if value && isMeasuring { advanceClock() }
    }

    private func configureForegroundClock() {
        clock?.invalidate(); clock = nil
        guard foreground, isMeasuring else { return }
        // Foreground reevaluation only. ProgressView owns time animation in all surfaces.
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceClock() }
        }
    }

    func stop() {
        sensors.stop(); clock?.invalidate(); clock = nil; isMeasuring = false
        live.end(display: display)
        if let dataset { engine = CommuteEngine(timetable: dataset) }
        snapshot = .empty(); display = .empty()
        lastSignature = ""
        publish(force: true)
        status = "停止しました"
    }

    func authorizeBackground() { sensors.requestBackgroundAuthorization() }
    func startLiveActivity() { live.start(display: display) }
    func endLiveActivity() { live.end(display: display) }
    func refreshDiagnostic() { diagnostic = SharedStore.diagnostic() }

    private func ingest(_ observation: TravelObservation) {
        guard var engine else { return }
        snapshot = engine.ingest(observation)
        self.engine = engine
        publish()
    }

    private func advanceClock() {
        guard !snapshot.isSimulated, var engine else { return }
        snapshot = engine.advance(to: .now)
        self.engine = engine
        publish()
    }

    private func publish(force: Bool = false) {
        guard let dataset, let engine else { return }
        let future = engine.projectedTimeline(until: snapshot.date.addingTimeInterval(45 * 60), maxEntries: 48)
        display = DisplayAdapter.make(snapshot, dataset: dataset, future: future)
        let signature = [snapshot.routeID ?? "", snapshot.phase.rawValue,
                         snapshot.nextStationID ?? "", snapshot.confidence.rawValue,
                         snapshot.chosenServiceID ?? "", snapshot.candidates.map(\.id).joined(separator: ","),
                         String(snapshot.isSimulated), String(snapshot.segmentStart?.timeIntervalSince1970 ?? 0)]
            .joined(separator: "|")
        // Refresh the horizon occasionally even when the semantic state is unchanged.
        guard force || signature != lastSignature || Date.now.timeIntervalSince(lastPublish) >= 5 * 60 else { return }
        lastSignature = signature
        lastPublish = .now
        let entries = future.map { ScheduledDisplay(date: $0.date,
            state: DisplayAdapter.make($0.snapshot, dataset: dataset, future: future)) }
        do {
            try SharedStore.write(SnapshotEnvelope(current: display, timeline: entries,
                validUntil: snapshot.date.addingTimeInterval(45 * 60)))
            sharingStatus = "共有ファイルの保存成功"
        } catch { sharingStatus = "共有保存失敗・Widgetの署名診断を確認してください" }
        if force || Date.now.timeIntervalSince(lastReload) > 30 {
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
            lastReload = .now
        }
        live.update(display: display)
    }

    func loadDebug(_ scenario: DebugScenario) {
        guard let dataset else { return }
        sensors.stop(); clock?.invalidate(); clock = nil; isMeasuring = false
        live.end(display: display)
        engine = CommuteEngine(timetable: dataset)
        debugObservations = DebugPlayback.observations(for: scenario, dataset: dataset)
        debugRemaining = debugObservations.count
        snapshot = .empty(); display = .empty()
        snapshot.isSimulated = true
        snapshot.notice = "シミュレーション・" + scenario.rawValue
        lastSignature = ""
        status = "シミュレーション: " + scenario.rawValue
        if debugObservations.isEmpty { status += "（同梱データに適合する列車がありません）" }
        publish(force: true)
        stepDebug()
    }

    func stepDebug() {
        guard !debugObservations.isEmpty else { return }
        ingest(debugObservations.removeFirst())
        debugRemaining = debugObservations.count
    }

    /// Simulator captures use the same public debugging path and engine.
    /// Production builds do not consume automation launch arguments.
    func configureScreenshotIfRequested() {
        #if DEBUG
        guard !screenshotConfigured else { return }
        screenshotConfigured = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--screenshot-scenario"), index + 1 < arguments.count else { return }
        let key = arguments[index + 1]
        let scenarios: [String: DebugScenario] = [
            "missedOrigin": .missedOrigin, "intermediateRecovery": .intermediateRecovery,
            "reverse": .reverse, "midnight": .midnight, "express": .express,
            "gpsMissing": .gpsMissing, "ambiguous": .ambiguous, "road": .road
        ]
        guard let scenario = scenarios[key] else {
            writeScreenshotReport(scenario: key)
            return
        }
        loadDebug(scenario)
        var steps = 4
        if let i = arguments.firstIndex(of: "--screenshot-steps"), i + 1 < arguments.count {
            steps = min(30, max(0, Int(arguments[i + 1]) ?? 4))
        }
        for _ in 0..<steps { stepDebug() }
        writeScreenshotReport(scenario: key)
        #endif
    }

    #if DEBUG
    private func writeScreenshotReport(scenario: String) {
        struct Report: Codable {
            let scenario: String
            let snapshot: ProgressSnapshot
            let display: DisplayState
            let status: String
        }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Report(scenario: scenario, snapshot: snapshot, display: display, status: status)) {
            try? data.write(to: directory.appendingPathComponent("screenshot-state.json"), options: .atomic)
        }
    }
    #endif
}
