"""Derive corridor polylines from MLIT N02-25 GeoJSON (CC BY 4.0)."""
from pathlib import Path
import zipfile,json,math,heapq
BASE=Path(__file__).resolve().parents[1]
IDS={'三軒茶屋':'sangenjaya','池尻大橋':'ikejiri_ohashi','渋谷':'shibuya','恵比寿':'ebisu','目黒':'meguro','五反田':'gotanda','大崎':'osaki','品川':'shinagawa','高輪ゲートウェイ':'takanawa_gateway','田町':'tamachi'}
ROUTES={'denentoshi':('DT','田園都市線',['三軒茶屋','池尻大橋','渋谷']), 'yamanote':('JY','山手線',['渋谷','恵比寿','目黒','五反田','大崎','品川','高輪ゲートウェイ','田町'])}
def dist(a,b):return math.hypot((a[0]-b[0])*90500,(a[1]-b[1])*111200)
def midpoint(coords):
 lengths=[dist(a,b) for a,b in zip(coords,coords[1:])]; half=sum(lengths)/2; walked=0
 for a,b,length in zip(coords,coords[1:],lengths):
  if walked+length>=half:
   f=(half-walked)/length;return (a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f)
  walked+=length
 return tuple(coords[0])
def build_geometry():
 z=zipfile.ZipFile(BASE/'Data/raw/mlit-railway-2025.zip')
 rail=json.loads(z.read('N02-25_GML/UTF-8/N02-25_RailroadSection.geojson'))['features']
 station=json.loads(z.read('N02-25_GML/UTF-8/N02-25_Station.geojson'))['features']
 definitions={};routes=[];audit=[]
 for rid,(symbol,name,names) in ROUTES.items():
  def wanted(f):
   p=f['properties'];return p['N02_003']=='田園都市線' if rid=='denentoshi' else p['N02_004']=='東日本旅客鉄道' and p['N02_003'] in ['山手線','東海道線']
  centers={}
  for n in names:
   matches=[f for f in station if wanted(f) and f['properties'].get('N02_005')==n]
   assert matches,(rid,n)
   # Prefer Yamate legal route up to Osaki; station placement elsewhere follows JR Tokaido corridor.
   if rid=='yamanote':matches.sort(key=lambda f:f['properties']['N02_003']!='山手線')
   c=midpoint(matches[0]['geometry']['coordinates']);centers[n]=c
   definitions[IDS[n]]={'id':IDS[n],'name':n,'displayName':'高輪GW' if n=='高輪ゲートウェイ' else n,'latitude':round(c[1],8),'longitude':round(c[0],8)}
  # The bounding box is deliberately wider than the requested stations to retain curved tracks.
  features=[f for f in rail+station if wanted(f) and f['geometry']['type']=='LineString' and any(139.64<x<139.76 and 35.60<y<35.67 for x,y in f['geometry']['coordinates'])]
  graph={}
  def key(p):return tuple(round(v,6) for v in p)
  for f in features:
   coords=[key(p) for p in f['geometry']['coordinates']]
   for a,b in zip(coords,coords[1:]):
    graph.setdefault(a,{})[b]=dist(a,b);graph.setdefault(b,{})[a]=dist(a,b)
  # MLIT source joins are normally exact. Snap tiny sub-metre coordinate precision differences only.
  nodes=list(graph)
  for i,a in enumerate(nodes):
   for b in nodes[i+1:]:
    if dist(a,b)<1.2:graph[a][b]=dist(a,b);graph[b][a]=dist(a,b)
  # Insert station centre in its source polyline segment, preserving the curved route.
  for c in centers.values():
   edge=None;nearest=float('inf')
   for a in list(graph):
    for b in list(graph[a]):
     dx=(b[0]-a[0])*90500;dy=(b[1]-a[1])*111200
     t=max(0,min(1,(((c[0]-a[0])*90500)*dx+((c[1]-a[1])*111200)*dy)/(dx*dx+dy*dy))) if dx*dx+dy*dy else 0
     p=(a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t);distance=dist(c,p)
     if distance<nearest:edge=(a,b);nearest=distance
   assert edge and nearest<1.2,(rid,'station not on source route',nearest)
   a,b=edge;graph.setdefault(c,{})[a]=dist(c,a);graph[c][b]=dist(c,b);graph[a][c]=dist(a,c);graph[b][c]=dist(b,c)
  segments=[]
  for origin,destination in zip(names,names[1:]):
   a=centers[origin];b=centers[destination];q=[(0,a)];cost={a:0};previous={}
   while q:
    c,n=heapq.heappop(q)
    if n==b:break
    if c>cost[n]:continue
    for nxt,length in graph[n].items():
     nc=c+length
     if nc<cost.get(nxt,float('inf')):cost[nxt]=nc;previous[nxt]=n;heapq.heappush(q,(nc,nxt))
   assert b in cost,(rid,origin,destination,'disconnected source geometry')
   path=[b]
   while path[-1]!=a:path.append(previous[path[-1]])
   path.reverse()
   dedup=[path[0]]
   for p in path[1:]:
    if dist(p,dedup[-1])>.1:dedup.append(p)
   assert len(dedup)>3,(rid,origin,destination,'source unexpectedly straight')
   segments.append({'fromStationID':IDS[origin],'toStationID':IDS[destination],'coordinates':[[round(y,8),round(x,8)] for x,y in dedup],'sourceID':'mlit-railway-2025'})
   audit.append({'routeID':rid,'from':IDS[origin],'to':IDS[destination],'vertices':len(dedup),'metres':round(sum(dist(a,b) for a,b in zip(dedup,dedup[1:])),1),'stationSnapMetres':[round(dist(a,centers[origin]),1),round(dist(b,centers[destination]),1)]})
  routes.append({'id':rid,'symbol':symbol,'name':name,'stationIDs':[IDS[n] for n in names],'segments':segments})
 out={'stations':list(definitions.values()),'routes':routes,'sourceID':'mlit-railway-2025','attribution':'国土交通省 国土数値情報 鉄道データ（2025年度）、CC BY 4.0。対象区間を抽出・駅中心点で切り出して加工。','sourceURL':'https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N02-2025.html','sourceAsOf':'2025-12-31','retrievedAt':'2026-10-14','precisionNotice':'地図縮尺相当の路線中心形状。複線の個別線路、番線、地下高度は識別しない。'}
 (BASE/'Data/GeometryAudit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf8')
 (BASE/'Sources/CommuteApp/Resources/NetworkGeometry.json').write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf8')
 return out
if __name__=='__main__':
 import sys;sys.stdout.reconfigure(encoding='utf8');d=build_geometry();print('geometry',len(d['stations']),[(r['id'],sum(len(s['coordinates']) for s in r['segments'])) for r in d['routes']])
