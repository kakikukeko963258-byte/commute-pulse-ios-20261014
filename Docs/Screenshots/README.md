# 実行したアプリのスクリーンショット

[CI run 38481724740](https://github.com/kakikukeko963258-byte/commute-pulse-ios-20261014/actions/runs/38481724740)のcommit `395e7c8`を、iPhone16e／iOS26.2シミュレーターで起動して撮影したPNG。画像の編集はしていない。実GPS・実機・Widget／Live Activityの実表示の確認ではない。

模擬観測は本体と同じCommuteCoreへ投入し、撮影前にアプリが出力した判定JSONを確認した。全8シナリオを撮影し、対応するroute・direction・station・confidence・candidate・運行日の条件を検証した。詳細は[Results.json](Results.json)。

| シナリオ | 確認結果 | 画像 |
| --- | --- | --- |
| 乗車前 | 路線未判定、位置計測を促す | [idle](idle.png) |
| 出発駅の検出漏れ | 恵比寿から山手線の進捗を回復、次駅目黒 | [missedOrigin](missedOrigin.png) |
| 途中駅でGPS復帰 | 恵比寿で現在駅・次駅・進捗を補正 | [intermediateRecovery](intermediateRecovery.png) |
| 逆方向 | 左端田町、次駅高輪GW、右端渋谷 | [reverse](reverse.png) |
| 日付またぎ | 0時台の予定時刻と前営業日の候補を確認 | [midnight](midnight.png) |
| 急行 | 赤いバー、池尻大橋を飛ばして次駅渋谷 | [express](express.png) |
| GPS欠落 | 既存候補の予定時刻で進捗推定、確度低 | [gpsMissing](gpsMissing.png) |
| 複数候補 | 粗いGPSで候補を選択せず、確度低・候補複数 | [ambiguous](ambiguous.png) |

初回撮影ではMotion許可ダイアログが重なった。実計測開始までMotionを初期化せず、シミュレーションでは権限を要求しない修正後、上記の8枚を撮り直した。
