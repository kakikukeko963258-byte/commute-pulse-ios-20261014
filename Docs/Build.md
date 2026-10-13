# CI ビルドと IPA

Windows で編集したソースを GitHub に push し、GitHub Actions の macOS runner と Xcode でビルドします。Workflow は `workflow_dispatch` による手動実行専用で、push からは起動しません。手動実行は利用者の指示がある場合に行います。

## 初回成功 run

[GitHub Actions run 38479248227](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38479248227)（commit `84b2ffb`）で、以下を確認しました。

- Runner: `macos-15`
- Xcode: 16.4、build 16F6
- iOS Simulator SDK: 18.5
- `swift test`: 17 tests executed、0 failures
- `xcodebuild archive`: `ARCHIVE_SUCCEEDED`
- IPA: `CommutePulse-AltStore.ipa`、691,527 bytes
- IPA の `Payload` にアプリ本体とWidget Extensionがあり、両方に実行可能Mach-Oを確認
- 両ターゲットの Info.plist に設定された App Group identifier が一致

この結果は、ビルド・テスト・IPA構造の確認です。Info.plist の設定一致は、署名済みentitlementsやApp Group共有containerの実行成功を証明しません。IPAは未署名で、AltStoreによる再署名とiPhoneへのインストールが必要です。

## 後続run

初回のdelegate actor-isolationとorientation warningsはcommit6b571a1で修正し、run38480050090でarchiveとSimulator buildが成功しました。初回の撮影画像にはMotion許可ダイアログが重なっていたため、Motionを実計測開始まで初期化しない修正後に撮り直しました。

## 最新の成功 run

[run38481724740](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38481724740)（commit `395e7c8`）:

- macos-15、Xcode16.4 (16F6)、iOS18.5 SDK
- XCTest18件、失敗0
- device archiveとSimulator buildが成功。両ビルドログにcompiler warning/errorなし
- IPA699,394 bytes。appとWidget Extensionの実行可能Mach-O、同梱1,591サービス、両Info.plistのApp Group一致を確認
- SHA-256: `b6cec0cfffb7b589414f95ff6300ca40e2cc0dd36c2301d29cdc34f96f687da6`
- iPhone16e／iOS26.2シミュレーターで8シナリオを撮影。全8件でアプリの出力した判定状態を自動照合
- Motion許可ダイアログなし、縦駅名・高輪GW・進捗バーに欠けなしを画像で確認

[最新Artifact](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38481724740/artifacts/11857816700)にIPA・ビルドログ・署名要求設定・PNG・判定JSON・Simulator inventoryを保存しています。[撮影画像](Screenshots/README.md)は実行したアプリの未編集画像で、実GPSの測定結果ではありません。

追加した回帰テストでは、180mなど粗いGPSでは複数候補を選択せず、単一候補でも確度を低くすることを確認しました。最終の撮影でも候補複数のchosenServiceIDが未設定のままであることを確認しています。

## IPAの取得と再署名

1. 完了したActions runでcommitと結論を確認します。
2. そのrunのArtifactから `CommutePulse-AltStore.ipa` を取得します。
3. [AltStore手順](AltStore.md)に従ってiPhoneへsideloadします。
4. IPA内のアプリ本体とWidget Extensionについて、AltStore再署名後のentitlementsとprovisioning profileを別々に確認します。
5. iPhone上でApp Group共有、Widget読取、Live Activity表示を実際に確認します。

初回runのIPAは再署名前です。Apple Accountの種類だけでApp Groupsの利用可否を断定せず、両ターゲットの実際の署名、profileの許可内容、共有containerの読み書きで診断します。
