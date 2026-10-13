# データ成果物

- `SourceManifest.json`: 原資料の URL、取得日、SHA-256、適用期間、利用条件へのリンク。同じ内容をアプリ Resources に同梱する。
- `GeometryAudit.json`: 国土交通省の実路線形状を加工した各駅間の頂点数・距離。
- `ValidationReport.json`: ローカル原本照合を含むオフライン検証結果。
- `raw/`: ローカル監査用の原本 HTML/PDF/ZIP/CSV。Git 対象外で公開・アプリへの同梱は行わない。

アプリが使う独自 JSON は `Sources/CommuteApp/Resources/` の `Timetable.json`、`NetworkGeometry.json`、`Holidays.json`。通常利用でネットワークへ時刻表を取りに行く処理はない。

時刻表原資料の転載・二次利用許諾を取得したとは表明しない。独自 JSON 化が許諾や適法性を保証するものではない。原資料の条件および公式画像ロゴを採用できなかった制約は [出典資料](../Docs/Sources.md) を参照。

`Scripts/import_timetables.py` / `Scripts/build_geometry.py` / `Scripts/validate_data.py` は Python 3.11 以降の標準ライブラリのみを使用する。`source_dom.py` が HTML の検証・抽出を補助する。IPA のビルドは一切行わない。
