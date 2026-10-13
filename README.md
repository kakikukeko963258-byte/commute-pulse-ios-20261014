# CommutePulse — 通学リアルタイム進捗

Swift / SwiftUI / WidgetKit / ActivityKit / Core Location / Core Motionで新規作成したiPhoneアプリ。位置と同梱予定時刻を使って乗車路線・列車候補・進捗を端末内で推定する。通常利用で通信、APIキー、時刻表JSONの手動読込は不要。

**macOS CIで18テスト、IPA archive、Simulator build、8シナリオの画面・判定確認が成功しました。AltStoreでの再署名・iPhone実機検証は未実施です。Workflowは手動実行専用で、pushでは起動しません。**

[最新のIPAとスクリーンショットのArtifact](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38481724740/artifacts/11857816700) / [8シナリオの撮影画像](Docs/Screenshots/README.md) / [ビルド記録](Docs/Build.md)

## 対象と表示

- 田園都市線: 三軒茶屋 → 池尻大橋 → 渋谷（急行・準急・各駅停車）。
- 山手線: 渋谷 → 恵比寿 → 目黒 → 五反田 → 大崎 → 品川 → 高輪GW → 田町、および逆方向。
- 本体、大型ホームWidget、ロック画面Live Activityで現在の路線を表示。全駅名は縦書き、高輪GWは「高／輪／GW」の3行。
- 次駅、方面、推定到着時刻、確度、乗車前・乗換中・到着後を表示。急行は明るい赤、通常は路線ごとの緑。
- 公式ロゴ画像は含まない。利用条件を確認した上でDT/JY文字を独自描画する。

## 推定と更新

実線路の形状、位置精度、速度、方向、活動分類、駅履歴、予定時刻を共通判定エンジンへ入力する。automotiveだけで電車と判断しない。出発の検出漏れがあっても途中駅から再評価する。候補が複数なら確定せず、地下では直前の観測と予定時刻で推定する。初回から位置がなく路線の根拠がない場合には未判定と表示する。

通常版のバーは駅間のProgressView(timerInterval:countsDown:)で進む。Widgetの停車境界Timelineと、Live Activityの文字情報更新を別に扱う。Activity更新が途切れた次駅は「最終更新」として示し、予定バーの進行と区別する。OSの背景実行やWidget更新の頻度は保証しない。シミュレーションは同じエンジンを使い、仮想時刻の進捗を全画面で明示する。

同梱時刻表は**予定時刻**で、リアルタイム遅延ではない。公表到着時刻がない場合は発車時刻を代用し、推定と記録する。大崎の継続は公式の接続情報がある列車だけを接続する。出典・取得日・適用期間・原本ハッシュを保持する。

## Windowsでの確認

新規フォルダ内で次のコマンドはデータと構成の検証だけを行う。コンパイルやネットワークアクセスは行わない。

```powershell
python Scripts/validate_repository.py
```

構成:

| パス | 内容 |
| --- | --- |
| Sources/CommuteCore | Foundation共通エンジン、幾何、運行日、Codableモデル |
| Sources/CommuteApp | SwiftUI本体、センサー、デバッグ、共有・Activity更新 |
| Sources/CommuteWidgets | 大型ホームWidgetとLive Activity |
| Sources/Shared | 時間連動表示、共有保存、署名・共有診断 |
| Sources/CommuteApp/Resources | 同梱時刻表・線路形状・祝日・出典 |
| Data | 出典記録とデータ監査。原本rawはGit除外 |
| Tests/CommuteCoreTests | 判定のXCTest18件（最新CIで全件成功） |
| project.yml | XcodeGenのプロジェクト定義 |
| .github/workflows/build-ipa.yml | 手動実行専用のmacOS/Xcode→IPA Workflow |

## 初回CIビルドとIPA

2026-10-14の[初回CI run](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38479248227)（commit `84b2ffb`）では、macos-15 / Xcode 16.4 (16F6) / iOS 18.5 SDKでSwift tests 17件が成功し、`xcodebuild archive` が `ARCHIVE_SUCCEEDED` になりました。ArtifactのIPAは691,527 bytesで、PayloadにアプリとWidget Extensionが含まれ、両方に実行可能Mach-Oがあることを確認しました。Info.plist上のApp Group設定も両ターゲットで一致しています。

最新の[run38481724740](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38481724740)（commit395e7c8）で18テストが通過し、IPA699,394 bytesと8シナリオの撮影画像・判定JSONを取得しました。シミュレーターはiPhone16e／iOS26.2です。

IPAは未署名です。AltStoreで再署名してiPhoneへインストールしてください。再署名後の実行ファイルentitlements、共有container、Widget読取、Live Activityの実表示は未確認です。

未署名IPAのため、App Groupsの設定があることと再署名後に使えることは別。無料Apple Accountという理由だけで可否を断定せず、両ターゲットの署名、プロファイル、コンテナ書込・Widget読取記録を診断する。Live Activityの開始要求成功と実表示も分けて確認する。

- [設計](Docs/Architecture.md) / [推定エンジン](Docs/Inference.md)
- [時刻表・線路・祝日・利用条件](Docs/Sources.md)
- [AltStore・共有診断](Docs/AltStore.md)
- [CIビルド・IPA](Docs/Build.md)
- [検証結果と実機チェックリスト](Docs/Validation.md)
- [プライバシー](Docs/Privacy.md)

アプリのソースはMIT。公式データや資料にはMITを適用しない。画像・HTML・PDF原本は公開せず、事業者のデータ再配布許諾を得たとは表明しない。線路と祝日の条件、および時刻表の出典条件はSources.mdに記録する。
