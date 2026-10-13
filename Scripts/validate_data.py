"""Offline integrity, coverage, and provenance checks. Optional --raw verifies local source files."""
from pathlib import Path
from datetime import date
from collections import Counter
from source_dom import DOM,Node
from urllib.parse import urlparse,parse_qs
import json,re,hashlib,sys,argparse,math
BASE=Path(__file__).resolve().parents[1];RES=BASE/'Sources/CommuteApp/Resources'
def read(p):return json.loads(p.read_text(encoding='utf8'))
def cells(row,tag):return [n for n in row.children if isinstance(n,Node) and n.tag==tag]
def validate(raw=False):
 d=read(RES/'Timetable.json');m=read(BASE/'Data/SourceManifest.json');h=read(RES/'Holidays.json');g=read(RES/'NetworkGeometry.json')
 assert d['schemaVersion']==1 and d['timeZone']=='Asia/Tokyo' and d['serviceDayStartMinute']==180
 assert d['metadata']['plannedTimetableOnly'] is True and d['metadata']['realTimeDelayData'] is False
 assert len(d['stations'])==10;stations={s['id']:s for s in d['stations']};routes={r['id']:r for r in d['routes']}
 assert stations['takanawa_gateway']['displayName']=='高輪GW'
 assert d['routes']==g['routes'] and d['holidays']['dates']==h['dates']
 assert d['holidays'].get('coveredFrom')==h['coveredFrom'] and d['holidays'].get('coveredTo')==h['coveredTo']
 assert '2026-10-12' in h['dates'] and '2026-11-03' in h['dates'] and '2026-09-22' in h['dates']
 assert h['coveredTo']=='2027-12-31',h['coveredTo']
 for route in routes.values():
  assert len(route['segments'])==len(route['stationIDs'])-1
  for seg,a,b in zip(route['segments'],route['stationIDs'],route['stationIDs'][1:]):
   assert (seg['fromStationID'],seg['toStationID'])==(a,b)
   assert len(seg['coordinates'])>3 and seg['sourceID'] in m
   for lat,lon in seg['coordinates']:assert 35.5<lat<35.8 and 139.5<lon<139.9
 identifiers=set();counts=Counter();cross_osaki=0;published_arrivals=0;fallback_arrivals=0
 for s in d['services']:
  assert s['id'] not in identifiers;identifiers.add(s['id']);assert s['routeID'] in routes
  assert s['direction'] in ['forward','reverse'] and s['trainType'] in ['local','express','semiExpress']
  assert s['dayTypes'] and set(s['dayTypes'])<={'weekday','weekendHoliday'}
  assert s['sourceIDs'] and all(id in m for id in s['sourceIDs'])
  assert len(s['stops'])>=2
  order=routes[s['routeID']]['stationIDs'];indices=[order.index(t['stationID']) for t in s['stops']]
  assert indices==sorted(set(indices),reverse=s['direction']=='reverse'),s['id']
  last=-1
  for t in s['stops']:
   dep=t['departureMinute'];arr=t.get('arrivalMinute')
   assert isinstance(dep,int) and 180<=dep<1800 and dep>=last,(s['id'],t,last)
   if arr is None:assert t['arrivalEstimated'] is True;fallback_arrivals+=1
   else:assert isinstance(arr,int) and last<=arr<=dep and t['arrivalEstimated'] is False;published_arrivals+=1
   if t.get('departurePublished') is False:assert t is s['stops'][-1] and arr==dep
   last=dep
  if s['trainType']=='express' and s['routeID']=='denentoshi':assert 'ikejiri_ohashi' not in [t['stationID'] for t in s['stops']]
  for key in ['includeDates','excludeDates']:
   for ds in s.get(key,[]):date.fromisoformat(ds)
  if s.get('validFrom'):date.fromisoformat(s['validFrom'])
  if s.get('validTo'):date.fromisoformat(s['validTo'])
  if s['routeID']=='yamanote':
   crosses=min(indices)<order.index('osaki')<max(indices)
   if crosses:
    cross_osaki+=1;assert s['continuity']=='verified'
    evidence=s['continuityEvidence'];assert evidence['sourceID'] in s['sourceIDs'] and 'arrow_loop_next and arrow_loop_prev' in evidence['method']
   assert s.get('includeDates') and s.get('validFrom') and s.get('validTo')
  counts[(s['routeID'],s['direction'],','.join(s['dayTypes']))]+=1
 # Ensure every operating-hours anchor in the official station Web documents is represented.
 coverage=[]
 if raw:
  checked=0
  for record in m.values():
   if not record.get('localAuditFile'):continue
   path=BASE/record['localAuditFile']
   assert path.exists(),path
   assert hashlib.sha256(path.read_bytes()).hexdigest()==record['sha256'],path
   checked+=1
  expected_jr=[('jr-shibuya-inner-weekday','shibuya','forward','2026-10-14'),('jr-shibuya-inner-weekend','shibuya','forward','2026-10-17'),('jr-tamachi-outer-weekday','tamachi','reverse','2026-10-14'),('jr-tamachi-outer-weekend','tamachi','reverse','2026-10-17')]
  for src,sid,direction,ds in expected_jr:
   dom=DOM((BASE/m[src]['localAuditFile']).read_text(encoding='utf8')).root;expected=[]
   for tr in dom.all('tr'):
    th=cells(tr,'th') or cells(tr,'td')
    if not th:continue
    hh=re.search(r'^(\d+)時',th[0].text().strip())
    if not hh:continue
    hr=int(hh.group(1))
    for a in tr.all('a'):
     value=re.match(r'^(\d{1,2})(?:●)?$',a.text().strip())
     if '/train/' in a.attrs.get('href','') and value:expected.append(hr*60+int(value.group(1))+(1440 if hr<3 else 0))
   actual={t['departureMinute'] for s in d['services'] if s['routeID']=='yamanote' and s['direction']==direction and ds in s['includeDates'] for t in s['stops'] if t['stationID']==sid and t.get('departurePublished',True)}
   assert expected and not(set(expected)-actual),(src,sorted(set(expected)-actual))
   coverage.append({'sourceID':src,'date':ds,'stationID':sid,'confirmedDepartures':len(expected),'missing':0,'firstMinute':min(expected),'lastMinute':max(expected)})
  dom=DOM((BASE/m['tokyu-web']['localAuditFile']).read_text(encoding='utf8')).root
  expected={'weekday':set(),'weekendHoliday':set()}
  for a in dom.all('a'):
   href=a.attrs.get('href','')
   if 'TrainRouteTimetable?' not in href:continue
   q=parse_qs(urlparse(href).query);hr=int(q['hour'][0]);ds=date(int(q['year'][0]),int(q['month'][0]),int(q['day'][0]))
   if hr<3:ds=ds-__import__('datetime').timedelta(days=1)
   kind='weekday' if ds.weekday()<5 else 'weekendHoliday';expected[kind].add(hr*60+int(q['minutes'][0])+(1440 if hr<3 else 0))
  for kind,times in expected.items():
   actual={s['stops'][0]['departureMinute'] for s in d['services'] if s['routeID']=='denentoshi' and kind in s['dayTypes']}
   assert actual==times,(kind,sorted(times-actual),sorted(actual-times))
   coverage.append({'sourceID':'tokyu-web','dayType':kind,'stationID':'sangenjaya','confirmedDepartures':len(times),'missing':0,'firstMinute':min(times),'lastMinute':max(times)})
  # Independent witness checks for every asserted Osaki cross-column continuation.
  for s in d['services']:
   ev=s.get('continuityEvidence',{})
   if 'arrow_loop_next and arrow_loop_prev' not in ev.get('method',''):continue
   text=(BASE/m[ev['sourceID']]['localAuditFile']).read_text(encoding='utf8');dom=DOM(text).root
   assert any('大崎' in row.text() and row.all(cls='arrow_loop_next') and row.all(cls='arrow_loop_prev') for row in dom.all('tr')),s['id']
 else:checked=None
 result={'validatedAt':'2026-10-14','serviceCount':len(d['services']),'stationCount':len(stations),'sourceCount':len(m),'geometryVertices':sum(len(s['coordinates']) for r in routes.values() for s in r['segments']),'crossOsakiVerifiedServices':cross_osaki,'publishedArrivalRecords':published_arrivals,'estimatedArrivalFallbackRecords':fallback_arrivals,'holidayCoveredTo':h['coveredTo'],'rawHashesChecked':checked,'counts':[{'routeID':a,'direction':b,'dayTypes':c,'count':n} for (a,b,c),n in counts.items()],'sourceCoverage':coverage,'buildExecuted':False}
 return result
if __name__=='__main__':
 sys.stdout.reconfigure(encoding='utf8');p=argparse.ArgumentParser();p.add_argument('--raw',action='store_true');a=p.parse_args();result=validate(a.raw)
 if a.raw:(BASE/'Data/ValidationReport.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
 print(json.dumps(result,ensure_ascii=False,indent=2))
