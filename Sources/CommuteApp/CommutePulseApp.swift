import SwiftUI
import CommuteCore

@main struct CommutePulseApp: App {
    @StateObject private var controller = CommuteController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            CommuteScreen(controller: controller)
                .onChange(of: scenePhase, initial: true) { _, value in
                    controller.setForeground(value == .active)
                }
        }
    }
}

private struct CommuteScreen: View {
    @ObservedObject var controller: CommuteController
    @State private var scenario = DebugScenario.missedOrigin
    @State private var showDiagnostic = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RouteProgressView(state: controller.display)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    Text("進捗は位置と同梱時刻表による推定です。遅延情報は取得しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(controller.status).font(.callout)
                    HStack {
                        Button(controller.isMeasuring ? "計測を停止" : "通学計測を開始") {
                            controller.isMeasuring ? controller.stop() : controller.start()
                        }.buttonStyle(.borderedProminent)
                        if controller.display.isSimulated {
                            Button("通常版へ") { controller.start() }.buttonStyle(.bordered)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ロック画面").font(.headline)
                        HStack {
                            Button("Live Activity開始") { controller.startLiveActivity() }
                            Button("終了") { controller.endLiveActivity() }
                        }.buttonStyle(.bordered)
                        Text(controller.liveStatus).font(.footnote)
                        Text("開始要求の成功とロック画面への実表示は別です。端末のロック画面で確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("バックグラウンド位置情報の許可を依頼") { controller.authorizeBackground() }
                            .font(.footnote)
                    }
                    if !controller.snapshot.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("列車候補 \(controller.snapshot.candidates.count)件").font(.headline)
                            ForEach(controller.snapshot.candidates.prefix(5)) { candidate in
                                HStack {
                                    Text(candidate.serviceID).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.2f", candidate.score))
                                        .font(.caption.monospacedDigit())
                                }
                            }
                            Text("スコアは判定の比較値です。正解率や遅延を示しません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("シミュレーションで同じ判定処理を検証") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("実位置計測を止め、模擬観測を共通エンジンへ入力します。")
                                .font(.caption).foregroundStyle(.orange)
                            Picker("シナリオ", selection: $scenario) {
                                ForEach(DebugScenario.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu)
                            HStack {
                                Button("読込") { controller.loadDebug(scenario) }
                                Button("次の観測 (\(controller.debugRemaining))") { controller.stepDebug() }
                                    .disabled(controller.debugRemaining == 0)
                            }.buttonStyle(.bordered)
                            if controller.display.isSimulated {
                                Text("模擬観測: " + controller.snapshot.date.formatted(date: .numeric, time: .standard))
                                    .font(.caption.monospacedDigit())
                            }
                        }.padding(.top, 8)
                    }
                    Button("署名・Widget共有診断") {
                        controller.refreshDiagnostic(); showDiagnostic = true
                    }
                    NavigationLink("データ出典・適用期間") { SourcesScreen(dataset: controller.dataset) }
                    Text("位置・移動・加速度を端末内で処理します。通常利用で通信やAPIキーは必要ありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }
            .navigationTitle("通学の進み具合")
            .sheet(isPresented: $showDiagnostic) { DiagnosticScreen(controller: controller) }
        }
    }
}

private struct DiagnosticScreen: View {
    @ObservedObject var controller: CommuteController
    var body: some View {
        NavigationStack {
            List {
                if let diagnostic = controller.diagnostic {
                    LabeledContent("設定group", value: diagnostic.configuredGroup)
                    LabeledContent("選択group", value: diagnostic.selectedGroup ?? "なし")
                    LabeledContent("Container", value: diagnostic.containerAvailable ? "取得成功" : "取得失敗")
                    LabeledContent("本体の書込・読取", value: diagnostic.writeReadSucceeded ? "成功" : "未成功")
                    Section("プロファイル内の許可group") {
                        ForEach(diagnostic.permittedGroups, id: \.self) { Text($0).font(.caption) }
                        Text("実行ファイルの署名済entitlementsの証明にはなりません。").font(.caption)
                    }
                    if let date = diagnostic.extensionReadAt {
                        LabeledContent("Widget読取時刻") { Text(date, style: .time) }
                    } else { Text("Widgetからの読取記録がまだありません") }
                    if let date = diagnostic.extensionPublishedAt {
                        LabeledContent("Widgetが読んだデータ") { Text(date, style: .time) }
                    }
                    Text(diagnostic.message).font(.footnote)
                }
                Text(controller.sharingStatus)
                Button("診断を再取得") { controller.refreshDiagnostic() }
                Text("無料Apple Accountかどうかだけで判断せず、AltStoreで再署名した本体と拡張機能の署名・プロファイル・共有記録を確認してください。")
                    .font(.footnote)
            }.navigationTitle("共有の診断")
        }
    }
}

private struct SourcesScreen: View {
    let dataset: TimetableDataset?
    private var sourceSummary: [SourceRecord] {
        guard let url = Bundle.main.url(forResource: "SourceManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return [] }
        let ids = ["tokyu-web", "jr-shibuya-inner-weekday", "jr-tamachi-outer-weekday",
                   "mlit-railway-2025", "cao-holidays", "tokyu-terms"]
        return ids.compactMap { id in
            guard let record = object[id], let text = record["url"] as? String,
                  let url = URL(string: text) else { return nil }
            return SourceRecord(id: id, url: url, date: record["retrievedAt"] as? String ?? "未記録")
        }
    }
    private var holidayRange: String {
        guard let url = Bundle.main.url(forResource: "Holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "祝日の収録範囲を読めません" }
        return "祝日: " + (object["coveredFrom"] as? String ?? "未公表") + " ～ "
            + (object["coveredTo"] as? String ?? "未公表")
    }
    private func validity(_ routeID: String) -> String {
        let services = dataset?.services.filter { $0.routeID == routeID } ?? []
        let first = services.compactMap(\.validFrom).min() ?? "開始未公表"
        let last = services.compactMap(\.validTo).max() ?? "終了未公表"
        return first + " ～ " + last
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("同梱予定時刻・到着は推定").font(.headline)
                Text("適用終了が公表されていないデータには有効期限を推測して設定しません。運行改正時は同梱データの更新が必要です。")
                Text("DT/JYは文字で独自に描画しています。公式ロゴ画像の転載ではありません。")
                Text("田園都市線: " + validity("denentoshi")).font(.footnote)
                Text("山手線の収録運行日: " + validity("yamanote")).font(.footnote)
                Text("列車ごとの運行日で候補を絞ります。収録期間後はデータ更新が必要です。").font(.caption)
                Text(holidayRange).font(.footnote)
                ForEach(sourceSummary) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Link(source.id, destination: source.url)
                        Text("取得日: " + source.date).font(.caption)
                        Text(source.url.absoluteString).font(.caption).textSelection(.enabled)
                    }
                }
                Text("国土数値情報 鉄道データ（国土交通省、CC BY 4.0）を抽出・加工。内閣府の祝日CSVを加工。時刻表データの公衆再配布許諾を取得したとは表明しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.navigationTitle("データ出典")
    }
}

private struct SourceRecord: Identifiable {
    var id: String
    var url: URL
    var date: String
}
