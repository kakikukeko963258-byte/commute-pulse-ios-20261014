"""Development-only downloads of public Web documents; no timetable API."""
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.parse import urljoin, urlparse, parse_qs
from concurrent.futures import ThreadPoolExecutor, as_completed
from source_dom import DOM
from datetime import date
import json,time,hashlib

BASE=Path(__file__).resolve().parents[1]; RAW=BASE/'Data/raw'; RAW.mkdir(exist_ok=True)
MANIFEST=BASE/'Data/SourceManifest.json'
records=json.loads(MANIFEST.read_text(encoding='utf8')) if MANIFEST.exists() else {}
def fetch(id,url):
 path=RAW/(id+('.zip' if url.endswith('.zip') else '.csv' if url.endswith('.csv') else '.html'))
 if not path.exists():
  for attempt in range(3):
   try:
    with urlopen(Request(url,headers={'User-Agent':'CommutePulse-development-source-review/1.0'}),timeout=45) as r: b=r.read()
    path.write_bytes(b);break
   except Exception:
    if attempt==2:raise
    time.sleep(2)
 else:b=path.read_bytes()
 rec={'id':id,'url':url,'retrievedAt':date.today().isoformat(),'sha256':hashlib.sha256(b).hexdigest(),'localAuditFile':'Data/raw/'+path.name,'redistributeRaw':False}
 records[id]=rec
 return b

def run():
 for id,url in [('mlit-railway-2025','https://nlftp.mlit.go.jp/ksj/gml/data/N02/N02-25/N02-25_GML.zip'),('cao-holidays','https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv'),('tokyu-terms','https://www.tokyu.co.jp/use/'),('jreast-terms','https://www.jreast.co.jp/site/rules.html/'),('tokyu-web','https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?rrCd=00000789&stCd=00003004&updown=0')]:
  try:fetch(id,url);print('document',id,flush=True)
  except Exception as e:
   if id.endswith('terms'):print('terms recorded via browser only',id,flush=True)
   else:raise
 targets=[]
 # Shibuya inner and Tamachi outer pages include the authoritative continuous train links.
 for id,url in [('jr-shibuya-inner-weekday','https://timetables.jreast.co.jp/2610/timetable/tt0808/0808060.html'),('jr-shibuya-inner-weekend','https://timetables.jreast.co.jp/2610/timetable/tt0808/0808061.html'),('jr-tamachi-outer-weekday','https://timetables.jreast.co.jp/2610/timetable/tt0976/0976010.html'),('jr-tamachi-outer-weekend','https://timetables.jreast.co.jp/2610/timetable/tt0976/0976011.html')]:
  s=fetch(id,url).decode('utf8');d=DOM(s).root
  links=[urljoin(url,a.attrs['href']) for a in d.all('a') if '/train/' in a.attrs.get('href','')]
  for link in links:targets.append(('jr-train-'+urlparse(link).path.split('/')[-1].replace('.html',''),link))
  print('station',id,len(links),flush=True)
 s=fetch('tokyu-web','https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?rrCd=00000789&stCd=00003004&updown=0').decode('utf8')
 for a in DOM(s).root.all('a'):
  href=a.attrs.get('href','')
  if 'TrainRouteTimetable?' not in href:continue
  q=parse_qs(urlparse(href).query)
  # Weekday+Saturday. PDF confirms Saturday/Sunday/holiday timetable is shared.
  date=f"{q['year'][0]}-{int(q['month'][0]):02d}-{int(q['day'][0]):02d}"
  if date not in ['2026-10-14','2026-10-15','2026-10-17','2026-10-18']:continue
  if date=='2026-10-18' and int(q['hour'][0])>=3:continue
  id='tokyu-train-'+('weekday' if date in ['2026-10-14','2026-10-15'] else 'weekend')+'-'+q['trCd'][0]
  targets.append((id,urljoin('https://transfer.navitime.biz',href)))
 targets=list(dict(targets).items()); print('train documents',len(targets),flush=True)
 # Keep two requests in flight and pace each worker to reduce load on official sites.
 def worker(pair):
  b=fetch(*pair);time.sleep(.2);return pair[0],len(b)
 with ThreadPoolExecutor(max_workers=2) as pool:
  futures=[pool.submit(worker,t) for t in targets]
  for i,f in enumerate(as_completed(futures),1):
   id,size=f.result()
   if i%40==0:print('downloaded',i,'of',len(targets),flush=True); MANIFEST.write_text(json.dumps(records,ensure_ascii=False,indent=2),encoding='utf8')
 MANIFEST.write_text(json.dumps(records,ensure_ascii=False,indent=2),encoding='utf8')
 print('download complete',len(records),flush=True)
if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser(description='Development Web source retrieval. Source terms must be reviewed; this is not permission to collect or redistribute.')
 p.add_argument('--download',action='store_true',help='Explicitly opt into Web document retrieval after checking source terms and permissions.')
 args=p.parse_args()
 if not args.download:p.error('No network retrieval by default. Review Docs/Sources.md and source terms before --download.')
 run()
