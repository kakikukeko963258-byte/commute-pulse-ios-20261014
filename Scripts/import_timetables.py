"""Compile previously reviewed official Web timetable documents into bundled JSON.

No API requests and no build. Download phase is explicitly development-only.
Unknown arrival times remain null and arrivalEstimated=true.
"""
from pathlib import Path
from source_dom import DOM,Node
from build_geometry import build_geometry,IDS
from urllib.parse import urlparse,parse_qs,urljoin
from datetime import date,timedelta
import json,re,hashlib,csv,io,sys
sys.stdout.reconfigure(encoding='utf8')
BASE=Path(__file__).resolve().parents[1];RAW=BASE/'Data/raw';RES=BASE/'Sources/CommuteApp/Resources'
JR_ORDER=['shibuya','ebisu','meguro','gotanda','osaki','shinagawa','takanawa_gateway','tamachi']
DT_ORDER=['sangenjaya','ikejiri_ohashi','shibuya']
def minute(text):
 h,m=map(int,text.split(':'));return h*60+m+(1440 if h<3 else 0)
def children(n,tag):return [x for x in n.children if isinstance(x,Node) and x.tag==tag]
def jsonwrite(path,data):path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
def tokyo_holidays():
 rows=list(csv.reader(io.StringIO((RAW/'cao-holidays.csv').read_bytes().decode('cp932'))))[1:]
 values=[]
 for ds,name in rows:
  y,m,d=map(int,ds.split('/'))
  if y>=2025:values.append({'date':date(y,m,d).isoformat(),'name':name})
 out={'dates':[v['date'] for v in values],'entries':values,'sourceID':'cao-holidays','sourceURL':'https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv','retrievedAt':'2026-10-14','coveredFrom':'2025-01-01','coveredTo':f'{max(int(v["date"][:4]) for v in values)}-12-31','unknownAfterCoverage':True}
 jsonwrite(RES/'Holidays.json',out);return out

def jr_service_calendar(dom):
 operating=[];covered=[]
 for table in dom.all('table','calendar-month'):
  captions=table.all('caption');match=re.search(r'(\d+)年(\d+)月',captions[0].text()) if captions else None
  if not match:continue
  year,month=map(int,match.groups())
  for cell in table.all('td'):
   value=cell.text().strip()
   if not value.isdecimal() or 'class' not in cell.attrs:continue
   ds=date(year,month,int(value)).isoformat();covered.append(ds)
   if 'ok' in cell.attrs.get('class','').split():operating.append(ds)
 assert operating and covered
 return operating,min(covered),max(covered)

def parse_jr(path,sourceid):
 d=DOM(path.read_text(encoding='utf8')).root
 table=next(t for t in d.all('table') if t.attrs.get('id')=='tbl_train')
 rows=table.all('tr');head=rows[1];trainids=[c.text().strip() for c in children(head,'td')]
 operating,start,end=jr_service_calendar(d)
 runtext=rows[2].text();daytypes=['weekday'] if '平日運転' in runtext else ['weekendHoliday'] if '土曜・休日運転' in runtext or '土曜休日運転' in runtext else ['weekday','weekendHoliday']
 # Calendar is the authoritative day list. Derive classification where wording differs.
 if all(date.fromisoformat(ds).weekday()<5 for ds in operating):daytypes=['weekday']
 columns=[[] for _ in trainids]
 for row in rows:
  if 'time' not in row.attrs.get('class','').split():continue
  heading=children(row,'th')
  if not heading:continue
  name=heading[0].text().strip();times=children(row,'td')[::2]
  for i,cell in enumerate(times):
   if i>=len(columns):continue
   published=re.findall(r'(\d{1,2}:\d{2})\s*(発|着)',cell.text())
   if not published:continue
   event={'name':name,'stationID':IDS.get(name),'column':i,'arrivalMinute':None,'departureMinute':None,'arrowNext':bool(cell.all(cls='arrow_loop_next')),'arrowPrev':bool(cell.all(cls='arrow_loop_prev'))}
   for clock,kind in published:event['departureMinute' if kind=='発' else 'arrivalMinute']=minute(clock)
   columns[i].append(event)
 flattened=[e for col in columns for e in col]
 merged=[]
 for event in flattened:
  if merged and merged[-1]['name']==event['name'] and merged[-1]['column']!=event['column']:
   previous=merged[-1]
   if previous['arrowNext'] and event['arrowPrev']:
    assert previous['arrivalMinute'] is not None and event['departureMinute'] is not None
    assert 0<=event['departureMinute']-previous['arrivalMinute']<=10
    previous['departureMinute']=event['departureMinute'];previous['throughVerified']=True;previous['endColumn']=event['column'];continue
  merged.append(event)
 groups=[];group=[];previousIndex=None;direction=None
 def flush():
  nonlocal group,previousIndex,direction
  if group:groups.append(group)
  group=[];previousIndex=None;direction=None
 for event in merged:
  stationid=event['stationID']
  if stationid not in JR_ORDER:flush();continue
  index=JR_ORDER.index(stationid)
  if previousIndex is not None:
   delta=index-previousIndex
   if abs(delta)!=1 or (direction is not None and delta!=direction):flush()
   else:direction=delta
  group.append(event);previousIndex=index
 flush();services=[]
 for g in groups:
  if len(g)<2:continue
  direction='forward' if JR_ORDER.index(g[-1]['stationID'])>JR_ORDER.index(g[0]['stationID']) else 'reverse'
  # Verify any boundary between columns; otherwise keep source-local sections separate.
  columns_used={e['column'] for e in g}|{e.get('endColumn',e['column']) for e in g}
  spans_boundary=len(columns_used)>1
  verified=not spans_boundary or any(e.get('throughVerified') for e in g)
  assert verified,'unverified source train boundary would be linked'
  stops=[]
  for e in g:
   dep=e['departureMinute'];arr=e['arrivalMinute']
   # A terminal with published arrival only has no following leg. Preserve source event kind.
   stops.append({'stationID':e['stationID'],'departureMinute':dep if dep is not None else arr,'arrivalMinute':arr,'arrivalEstimated':arr is None,'stopKind':'stop','departurePublished':dep is not None})
  services.append({'routeID':'yamanote','direction':direction,'dayTypes':daytypes,'trainType':'local','officialTrainID':' → '.join(trainids[i] for i in sorted(columns_used)),'continuity':'verified' if verified else 'boundary','validFrom':start,'validTo':end,'includeDates':operating,'excludeDates':[],'sourceIDs':[sourceid],'stops':stops,'continuityEvidence':{'sourceID':sourceid,'method':'same official train detail; arrow_loop_next and arrow_loop_prev at Osaki' if spans_boundary else 'same official train column'}})
 return services

def station_diagram(id,url,manifest):
 path=RAW/(id+'.html')
 if not path.exists():raise FileNotFoundError(f'{path}: import is offline; provide reviewed source document first and review Docs/Sources.md')
 b=path.read_bytes();manifest[id]={'id':id,'url':url,'retrievedAt':'2026-10-14','sha256':hashlib.sha256(b).hexdigest(),'localAuditFile':'Data/raw/'+path.name,'redistributeRaw':False}
 result={}
 for a in DOM(b.decode('utf8')).root.all('a'):
  href=a.attrs.get('href','')
  if 'TrainRouteTimetable?' not in href:continue
  q=parse_qs(urlparse(href).query);hour=int(q['hour'][0]);clock=hour*60+int(q['minutes'][0])+(1440 if hour<3 else 0)
  ds=date(int(q['year'][0]),int(q['month'][0]),int(q['day'][0]))-timedelta(days=1 if hour<3 else 0)
  kind='weekday' if ds.weekday()<5 else 'weekendHoliday'
  key=(q['trCd'][0],kind);result[key]={'departureMinute':clock,'sourceID':id,'date':ds.isoformat(),'kind':q['kind'][0],'url':urljoin('https://transfer.navitime.biz',href)}
 return result

def parse_tokyu(path,record,departures):
 q=parse_qs(urlparse(record['url']).query);trid=q['trCd'][0];daytype='weekday' if 'weekday' in record['id'] else 'weekendHoliday';d=DOM(path.read_text(encoding='utf8')).root
 info={}
 for li in d.all('li'):
  entries=li.all('div','stop-info')
  if not entries:continue
  n=entries[0];names=n.all('div','name');times=n.all('div','time')
  if not names or not times:continue
  name=names[0].text().strip()
  if name not in IDS:continue
  match=re.search(r'(\d{1,2}:\d{2})',times[0].text());landings=n.all('span','landing')
  if match:info[IDS[name]]={'time':minute(match.group(1)),'kind':landings[0].text().strip() if landings else ''}
 base=departures['sangenjaya'].get((trid,daytype));assert base
 train_type='express' if base['kind'].endswith('急行') and not base['kind'].endswith('準急') else 'semiExpress' if base['kind'].endswith('準急') else 'local'
 stops=[];sourceids=[record['id'],base['sourceID']]
 for stationid in DT_ORDER:
  if stationid not in info:continue # Express skips Ikejiri; its geometrical station remains displayed as pass.
  arrival=info[stationid]['time'] if info[stationid]['kind']=='着' else None
  dep=departures[stationid].get((trid,daytype))
  if dep:sourceids.append(dep['sourceID']);departure=dep['departureMinute']
  elif stationid=='shibuya' and arrival is not None:departure=arrival # Terminal proxy; departurePublished=false.
  else:raise ValueError(('Missing independently published departure',path.name,stationid,trid,daytype))
  assert arrival is None or arrival<=departure,(path.name,stationid,arrival,departure)
  stops.append({'stationID':stationid,'departureMinute':departure,'arrivalMinute':arrival,'arrivalEstimated':arrival is None,'stopKind':'stop','departurePublished':bool(dep)})
 assert len(stops)>=2,(path.name,info)
 return {'routeID':'denentoshi','direction':'forward','dayTypes':[daytype],'trainType':train_type,'officialTrainID':trid,'continuity':'verified','validFrom':'2026-03-14','validTo':None,'sourceIDs':list(dict.fromkeys(sourceids)),'stops':stops,'validityNotice':'2026-03-14改正、取得日に公式掲載の標準ダイヤ。次回改正日未公表。','skippedStationIDs':['ikejiri_ohashi'] if train_type=='express' else []}

def main():
 manifest=json.loads((BASE/'Data/SourceManifest.json').read_text(encoding='utf8'))
 geometry=build_geometry();holidays=tokyo_holidays()
 departures={
  'sangenjaya':station_diagram('tokyu-web','https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?rrCd=00000789&stCd=00003004&updown=0',manifest),
  'ikejiri_ohashi':station_diagram('tokyu-ikejiri-web','https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?stCd=00005946&rrCd=00000789&updown=0',manifest),
  'shibuya':station_diagram('tokyu-shibuya-web','https://transfer.navitime.biz/tokyu/pc/diagram/TrainDiagram?stCd=00003544&rrCd=00000774&updown=0',manifest)}
 services=[]
 for id,record in manifest.items():
  if id.startswith('jr-train-'):services.extend(parse_jr(RAW/(id+'.html'),id))
  elif id.startswith('tokyu-train-'):services.append(parse_tokyu(RAW/(id+'.html'),record,departures))
 unique={}
 for service in services:
  signature=json.dumps({k:service.get(k) for k in ['routeID','direction','dayTypes','trainType','validFrom','validTo','includeDates','stops']},ensure_ascii=False,sort_keys=True)
  key=hashlib.sha256(signature.encode()).hexdigest()[:16]
  if key in unique:unique[key]['sourceIDs']=list(dict.fromkeys(unique[key]['sourceIDs']+service['sourceIDs']))
  else:service['id']=service['routeID']+'-'+key;unique[key]=service
 # Train detail pages may repeat a partial loop beside the same verified through service.
 # Remove a strict subset only when an official train number is shared and every published
 # event agrees. A terminal arrival proxy is compared to the through service's arrival.
 retained=[]
 def is_supported_subset(short,long):
  if short['routeID']!=long['routeID'] or short['direction']!=long['direction'] or short['dayTypes']!=long['dayTypes'] or short.get('includeDates')!=long.get('includeDates'):return False
  if not set(short.get('officialTrainID','').split(' → '))&set(long.get('officialTrainID','').split(' → ')):return False
  ls={t['stationID']:t for t in long['stops']}
  for st in short['stops']:
   lt=ls.get(st['stationID'])
   if not lt:return False
   if st.get('departurePublished',True) and st['departureMinute']!=lt['departureMinute']:return False
   if st['arrivalMinute'] is not None and lt['arrivalMinute'] is not None and st['arrivalMinute']!=lt['arrivalMinute']:return False
   if not st.get('departurePublished',True) and st['arrivalMinute']!=lt['arrivalMinute']:return False
  return True
 for service in sorted(unique.values(),key=lambda s:-len(s['stops'])):
  larger=next((s for s in retained if is_supported_subset(service,s)),None)
  if larger:larger['sourceIDs']=list(dict.fromkeys(larger['sourceIDs']+service['sourceIDs']))
  else:retained.append(service)
 services=sorted(retained,key=lambda s:(s['routeID'],s['direction'],s['dayTypes'],s['stops'][0]['departureMinute']))
 dataset={'schemaVersion':1,'timeZone':'Asia/Tokyo','serviceDayStartMinute':180,'stations':geometry['stations'],'routes':geometry['routes'],'services':services,'holidays':{'dates':holidays['dates'],'coveredFrom':holidays['coveredFrom'],'coveredTo':holidays['coveredTo'],'sourceID':holidays['sourceID'],'retrievedAt':holidays['retrievedAt']},'metadata':{'retrievedAt':'2026-10-14','plannedTimetableOnly':True,'realTimeDelayData':False,'arrivalPolicy':'Published arrival retained. If absent use published departure as estimated arrival. Terminal arrival-only proxy is flagged departurePublished=false.','holidayCoveredTo':holidays['coveredTo'],'geometrySourceID':'mlit-railway-2025','rawAuditFilesAreLocalOnly':True}}
 # Audit only the target facts; original documents and images remain local and untracked.
 extras=[('tokyu-sangenjaya-pdf','tokyu-sangenjaya.pdf','https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt03_sangen-jaya_1.pdf'),('tokyu-ikejiri-pdf','tokyu-ikejiri.pdf','https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt02_ikejiri-ohashi_1.pdf'),('tokyu-shibuya-pdf','tokyu-shibuya.pdf','https://www.tokyu.co.jp/railway/timetable/pdf/202603_dt01_shibuya_1.pdf')]
 for id,filename,url in extras:
  path=RAW/filename
  if path.exists():manifest[id]={'id':id,'url':url,'retrievedAt':'2026-10-14','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'localAuditFile':'Data/raw/'+filename,'redistributeRaw':False,'effectiveFrom':'2026-03-14','effectiveTo':None}
 for id,record in manifest.items():
  if id.startswith('jr-'):
   record['termsURL']='https://www.jreast.co.jp/site/rules.html/';record['reusePermission']='notObtained';record['publicationBasis']='JR時刻表2026年10月号'
  elif id.startswith('tokyu-'):
   record['termsURL']='https://transfer.navitime.biz/tokyu/pc/disclaimer/DisclaimerInformation' if 'train' in id or 'web' in id else 'https://www.tokyu.co.jp/use/'
   record['reusePermission']='notObtained';record['effectiveFrom']='2026-03-14';record['effectiveTo']=None
  elif id=='mlit-railway-2025':record.update({'license':'CC BY 4.0','sourceAsOf':'2025-12-31','attribution':geometry['attribution'],'termsURL':'https://nlftp.mlit.go.jp/ksj/other/agreement.html'})
  elif id=='cao-holidays':record.update({'coverageFrom':holidays['coveredFrom'],'coverageTo':holidays['coveredTo'],'attribution':'内閣府「国民の祝日」公表CSVを加工','termsURL':'https://www.cao.go.jp/others/rules.html'})
  referenced=[s for s in services if id in s['sourceIDs']]
  if referenced:
   record['effectiveFrom']=min(s['validFrom'] for s in referenced if s.get('validFrom'))
   record['effectiveTo']=max(s['validTo'] for s in referenced if s.get('validTo')) if all(s.get('validTo') for s in referenced) else None
 jsonwrite(RES/'Timetable.json',dataset);jsonwrite(BASE/'Data/SourceManifest.json',manifest);jsonwrite(RES/'SourceManifest.json',manifest)
 print('Compiled services',len(services));print('Counts',__import__('collections').Counter((s['routeID'],s['direction'],','.join(s['dayTypes'])) for s in services))
if __name__=='__main__':main()
