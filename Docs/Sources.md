# 同梱データの出典と利用条件

取得日: **2026-10-14（日本時間）**。通常利用時は同梱 JSON だけを読み、鉄道 API、API キー、Web 取得、JSON の手動読み込みを必要としない。

## 時刻表

対象区間の駅・時刻・列車種別・運行日を独自の JSON 構造へ記録した。原本の HTML、PDF、画面レイアウト、公式画像・ロゴは公開リポジトリおよびアプリへ含めない。`Data/raw/` はローカル監査用で Git 対象外。原本の取得 URL と SHA-256 を `Data/SourceManifest.json` に残す。

### 東急 田園都市線

- [公式 各駅時刻表（PDF 版）](https://www.tokyu.co.jp/railway/timetable/): **2026-03-14 改正**。
- [三軒茶屋 渋谷方面 PDF](https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt03_sangen-jaya_1.pdf)、[池尻大橋 渋谷方面 PDF](https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt02_ikejiri-ohashi_1.pdf)、[渋谷 押上方面 PDF](https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt01_shibuya_1.pdf)。PDF の三軒茶屋発車表・急行/準急凡例を目視確認した。
- [公式 三軒茶屋駅](https://www.tokyu.co.jp/area/sangen-jaya/station/)の「渋谷方面」からリンクされる [東急電鉄 Web 時刻表](https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?rrCd=00000789&stCd=00003004&updown=0)。運営の説明は [ご利用にあたって](https://transfer.navitime.biz/tokyu/pc/disclaimer/DisclaimerInformation)。東急電鉄提供情報をナビタイムジャパンが更新する公式委託サービスである。
- 上記 Web の各列車詳細 `TrainRouteTimetable` に記載された**到着時刻**を収録した。三軒茶屋・池尻大橋・渋谷の発車時刻は各駅の `TrainDiagram` に記載された同じ `trCd` で照合し、別列車を時刻の近さだけで連結しない。
- 平日、土休日の標準ダイヤ。Saturday と Sunday/Holiday は PDF の一つの「土曜日・休日」表に対応する。0 時台は前営業日の 24 時台として保存する。
- 三軒茶屋 → 池尻大橋 → 渋谷。急行は池尻大橋を通過するため、列車の停車時刻を作らない。駅一覧では通過駅として残す。
- 適用開始: 2026-03-14。**終了日は公式未公表**。そのため `validTo=null`、取得後の臨時変更・将来改正への追従は保証しない。

### JR 東日本 山手線

- [渋谷駅公式時刻表](https://timetables.jreast.co.jp/timetable/list0808.html)、[田町駅公式時刻表](https://timetables.jreast.co.jp/timetable/list0976.html)。旧 `www.jreast-timetable.jp` は現在 `timetables.jreast.co.jp` へ転送される。
- [2026 年 10 月 内回り 平日](https://timetables.jreast.co.jp/2610/timetable-v/630u1.html)、[土休日](https://timetables.jreast.co.jp/2610/timetable-v/630u2.html)、[外回り 平日](https://timetables.jreast.co.jp/2610/timetable-v/630d1.html)、[土休日](https://timetables.jreast.co.jp/2610/timetable-v/630d2.html)。同サイトは交通新聞社「JR 時刻表」2026 年 10 月号に基づくと説明している。
- 駅発車表からリンクされる公式の `train/...html` 列車詳細を使用する。列車番号、時刻、太字の運行カレンダーを記録する。カレンダーで確認できた日付を `includeDates`、確認範囲を `validFrom/validTo` に保存する。範囲外の日付の運転を推測で保証しない。
- **大崎の継続は、同じ公式列車詳細の `arrow_loop_next` と `arrow_loop_prev` の双方が大崎の着/発欄にある場合に限る**。例: [614G → 714G の公式詳細](https://timetables.jreast.co.jp/2610/train/010/014471.html)は、大崎 07:14 着 → 07:15 発の環状継続を表示する。このような列車番号変更を含む継続根拠を `continuityEvidence` に記録した。終着や確認できない接続を時間の近さで連結しない。
- 渋谷 → 恵比寿 → 目黒 → 五反田 → 大崎 → 品川 → 高輪ゲートウェイ → 田町（内回り）と、田町からの逆順（外回り）を保存する。表示名だけ「高輪GW」とする。
- 発車時刻しか公表されていない駅は `arrivalMinute=null` / `arrivalEstimated=true`。画面の到着表示は発車時刻を**推定の代用値**として使う。公表された大崎の着時刻は保存する。終着の着時刻しかない場合、次区間は作らず `departurePublished=false` を記録する。

## 利用条件・権利の扱い

このリポジトリは原本や事業者の表現・デザインを再配布せず、ユーザーが指定した対象区間の事実情報を独自のデータ構造に記録する。**鉄道事業者や情報提供者から、公衆再配布の許諾を取得したとは表明しない。独自 JSON 化だけをもって再配布許諾や適法性を保証しない。**

- [東急公式サイト利用条件 §3](https://www.tokyu.co.jp/use/)は、私的使用または法律で認められる範囲を超えたコンテンツ利用に事前許諾を要求する。
- [東急公式委託サービス利用条件](https://transfer.navitime.biz/tokyu/pc/disclaimer/DisclaimerInformation)は、データ・画像・ロゴ等の複製・頒布・公衆送信等、および自動収集を禁止事項に掲げる。調査中にこの条項を確認した後、追加取得を停止した。今後の再調査・データ更新はこの条件を確認し、必要な許諾を得て実施する。
- [JR 東日本サイト利用条件 §2/§3](https://www.jreast.co.jp/site/rules.html/)は画像・ロゴ・文章等の転載・二次利用や無許可の商標利用を制限する。時刻表サイトの注意書きも時刻表データの無断転載・複写、電磁的媒体等への加工を禁止すると記載する。
- アプリ独自ソースコードの MIT ライセンスは、原資料や鉄道時刻表データに新たな利用許諾を与えない。`Data/` と同梱の `Timetable.json` について、原資料の条件と出典を別途確認すること。

### 公式路線記号・ロゴ

- 路線記号 DT の根拠: [東急 公式駅ナンバリング資料](https://www.tokyu.co.jp/company/news/pdf/120126-1.pdf)、[公式路線ページ](https://www.tokyu.co.jp/railway/dt/)。
- 路線記号 JY の根拠: [JR 東日本 首都圏エリア駅ナンバリング導入資料](https://www.jreast.co.jp/press/2016/20160402.pdf)。
- **公式画像の再利用許諾は確認できなかった**ため、公式画像ロゴは同梱しない。DT / JY の文字情報をアプリ独自の書式で表示する。公式ロゴ使用の要件には制約が残る。

## 実線路形状

[国土交通省 国土数値情報「鉄道データ」2025 年度](https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N02-2025.html)、データ基準日 **2025-12-31**、取得日 **2026-10-14**。原典は国土地理院の電子地形図等。個別ページは **CC BY 4.0** と明示する。[サイト利用規約](https://nlftp.mlit.go.jp/ksj/other/agreement.html)の出典・加工表示も参照する。

`N02-25_GML.zip` 内の `RailroadSection.geojson` と `Station.geojson` から対象区間を抽出した。国土数値情報をもとに CommutePulse が作成・加工したデータであり、国が作成したアプリ用データではない。駅の線形の中央を駅座標とし、実路線の折れ線を最短経路で切り出す。単純な駅間直線で代用しない。田園都市線は 42 点、山手線は 144 点（駅間ごとに共有端点を含む）。山手線の品川以東はデータの法的路線名「東海道線」の JR 線路形状を使う。

測量精度・複線のどちらの線路か・番線・地下高度まで判定するデータではない。並走路線や道路と誤認する可能性を他の観測と確度表示で扱う。

## 祝日

[内閣府「国民の祝日」](https://www8.cao.go.jp/chosei/shukujitsu/gaiyou.html)、[公式 CSV](https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv)を加工し、2025 年以降の公表済み祝日・振替休日を `Holidays.json` と `Timetable.holidays` に保存する。収録範囲は JSON の `coveredFrom/coveredTo` に明記し、未公表年の春分・秋分などを計算で確定しない。祝日カレンダーの収録終了後はデータ期限を画面に表示する。

## 更新手順と監査

1. 各出典の利用条件と再利用・取得の可否を再確認する。公式時刻表の改正日と運行日カレンダーを確認する。
2. 許される方法で対象区間の時刻を新しい `Data/raw/` 原資料へ保存する。原本はコミットしない。`SourceManifest.json` の URL・取得日・SHA-256・適用期間を更新する。
3. `python Scripts/import_timetables.py` でローカル原資料から独自 JSON を再生成する。JSON に公式画像やレイアウトを含めない。Python 標準ライブラリだけで処理し、通常利用時の取得処理を持たない。
4. `python Scripts/validate_data.py --raw` でハッシュ、各公表時刻との対応、全営業時間の発車表、大崎継続根拠、祝日、実線路形状を検証する。公開 clone では `--raw` を省略し同梱 JSON の整合性を検証する。
5. Xcode/IPA ビルドは、ユーザーの指示があるまで実行しない。

このデータは**予定時刻**であり、リアルタイムの列車位置・遅延・運休情報ではない。
