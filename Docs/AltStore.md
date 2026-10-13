# AltStore でのインストール

CommutePulse の IPA は、Windows で開発したソースを GitHub に push し、GitHub Actions の macOS runner と Xcode でビルドして Artifact として取得する運用を前提にします。ローカル Mac は前提にしません。Workflow は手動実行し、実行後に対象 run の Artifact から IPA をダウンロードします。現時点で IPA の作成・署名・インストールは未検証です。

## インストール手順

1. GitHub の Actions で対象の手動実行を選び、完了した run と commit を確認します。
2. その run の Artifact から IPA をダウンロードし、Artifact が想定したアプリ・拡張機能の成果物であることを確認します。
3. AltStore の通常の手順で IPA を iPhone に sideload します。[AltStore公式Windows導入手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)を参照し、AltServer・端末の開発者モードなどを準備します。AltStore、AltServer、iOS のバージョンに応じた操作方法は、公式案内を確認してください。
4. iPhone でアプリを起動し、位置情報権限、Widget、Live Activity を個別に確認します。インストール成功だけで各機能の動作成功とは判断しません。
5. 署名の更新はAltStore/AltServerの手順で再署名します。ソースが変わらない限りIPAの再ビルドは必要ありません。ソース更新時は指示後にActionsから新しい未署名IPAを取得してAltStoreへ渡します。

## App Groups / 署名の診断

App Groups の利用可否を Apple Account の種類だけで決めつけないでください。失敗時は、ビルドに含まれた実際の署名情報と各ターゲットの設定を照合します。

- IPA 内のアプリ本体と Widget Extension（または Live Activity を含む Extension）の両方について、埋め込まれた provisioning profile と署名済み entitlements を調べる。
- 両ターゲットの application-identifier、com.apple.security.application-groups、Team ID、および profile の許可 entitlements を照合する。
- アプリと Extension で App Group の識別子が一致していること、各 provisioning profile が必要な識別子を許可していることを確認する。
- 実行時に各ターゲットから共有コンテナを取得できるか確認し、ログにターゲット名、要求した group identifier、取得可否を記録する。コンテナ URL やユーザーデータそのものはログに出さない。
- codesign や profile の診断出力は、どのターゲットのどの IPA に対するものか明記して保存する。片方のターゲットの結果だけで両方を正常と判断しない。

App Groups の署名が成立しても、Live Activity の実表示が保証されるわけではありません。Activity.request の成功ログは要求が受理されたことを示すだけです。端末の設定、OS の制限、許可状態を含めてロック画面と Dynamic Island の表示を実機で確かめてください。Widget の更新要求も即時反映を保証しません。

## 問題が起きたとき

- インストール時の拒否: IPA、署名、provisioning profile、有効期限、対象端末条件を確認する。
- アプリは起動するが共有データが見えない: アプリ本体と Extension の署名済み entitlements、profile、Team ID、group identifier、各ターゲットのコンテナ取得ログを比較する。
- Activity の要求は成功するが表示されない: Live Activity の端末設定、許可状態、OS 状態を確認し、要求成功と UI 表示の記録を分ける。
- Artifact が見つからない: Actions run の完了状態と Artifact の保存・有効期限を確認し、必要なら手動で workflow を再実行する。

診断ログを共有する場合は、Apple Account の識別情報、端末固有情報、位置情報、共有コンテナ内のデータを含めないようにしてください。

## 実際の署名確認の境界

CI では codesign の実行ファイル entitlements をターゲットごとに検査し、AltStore で署名・インストールした後も外部から取得できる署名情報で確認します。provisioning profile に許可された group があることだけでは、実際の実行ファイル entitlements や共有コンテナ利用の成功を証明しません。実機ではアプリが設定済み App Group の container に書き込み、Extension が同じ group から読み取った記録をアプリ上で確認できることまで検証します。これらは現時点で未確認です。
