# 設計

SwiftUI本体、WidgetKit拡張、ActivityKitの表示は共有DisplayStateを使う。位置観測と同梱データの処理はFoundationのみのCommuteCoreに集約し、CLLocationとシミュレーションは同じTravelObservationを投入する。

## 自動推定

駅、線路形状への距離、進行方向、速度、Core Motionの活動分類、駅通過履歴、運行日の時刻表で候補を比較する。Core Motionのautomotiveは電車の証明にならない。渋谷の位置だけでは路線を決めず、途中駅からの観測でも復帰する。加速度は本体で短い窓のRMSに集計し、電車と断定する分類器にはしない。センサー情報は端末外に送信しない。

地下の観測欠落は直前の候補を予定時刻で投影する。未観測の初回にGPSがなければ、路線と乗車列車は自動的には選べない。複数候補は維持し、任意の列車に確定しない。大崎を跨ぐ候補は公式の継続運転の証拠があるデータのみ利用する。

## 時間と表示

駅間の各バーはProgressView(timerInterval:countsDown:)を用いる。急行の通過駅がある区間のバー時刻は停車駅間の時間を表示上で配分するため、通過駅の正確な時刻を意味しない。App・Widget・Live Activityの描画に本体の毎秒タイマーは使わない。

Widgetには候補の停車境界から作ったTimelineEntryを渡す。Widget reloadは意味が変わる観測を中心に抑制し、OSの予算と実行判断に従う。Live Activityには後続区間の時刻も含め、最後の更新後も予定のバーが時間で進む。次駅・候補の文字情報はActivity.updateが必要で、更新が来なければstaleDate後に「最終更新の次駅」と表示する。サーバー、APNs、定期的なバックグラウンド起動は使わない。

本体の15秒タイマーはフォアグラウンドでの推定再評価に限定する。背景の観測はCore Locationの許可とiOSの実行判断に依存する。アプリの強制終了や位置許可の拒否後も更新を続ける保証はしない。

シミュレーションは観測ごとに仮想時計を進めるため、全画面で「シミュレーション」と表示し、バーはその仮想時刻の進捗値を描画する。通常版のシステム時間連動バーと区別する。Widgetへの模擬状態共有もOSのreload制約に従う。

## 大きさと署名

本体と大型ホームWidgetは16ptの均等余白、ロック画面は12ptの均等余白。全駅を等幅で横に並べ、各駅名を縦書きにする。「高輪GW」は「高」「輪」「GW」の3行。コンパクト版は通常文字サイズで約150pt以内を目標とし、実機のDynamic Typeとロック画面で未検証。Dynamic Islandは最小構成。

App Groupsは両ターゲットへ設定する。設定値のコンテナを優先し、署名プロファイルに実際に記録された非ワイルドカードgroupを調べる。本体の書込・読取、Widgetからの読取receipt、CIの署名情報を別の証拠として扱う。無料Apple Accountという理由だけで可否を断定しない。

## Windowsからの配布

project.ymlをXcodeGenの設計図として保存する。macOS runnerでXcodeプロジェクトを生成し、Xcodeで未署名のdevice archiveを作り、PayloadをIPA化する。AltStoreで本体と拡張機能を再署名する。Workflowはworkflow_dispatchだけで、pushでは実行されない。ビルドはユーザーの指示後に手動実行する。実行結果はDocs/Build.mdに記録する。

Apple一次資料:

- [時間連動ProgressView](https://developer.apple.com/documentation/swiftui/progressview/init(timerinterval:countsdown:))
- [Widgetの更新制約](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [GitHub macOS runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
