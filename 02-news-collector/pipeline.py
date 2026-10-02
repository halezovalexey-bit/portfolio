"""Official-source collection, persistence and quiet file-only digest."""
import datetime as dt, pathlib, json, sqlite3, hashlib, html, os, subprocess, time, concurrent.futures, contextlib, xml.etree.ElementTree as ET, re
from collector import parse_date, canonical, UTC
from urllib.parse import urlsplit
RULES={
 'rates': r'\b(interest rates?|monetary policy|fomc|bank rate|rate decision|policy rates?|discount rate|quantitative tightening|quantitative easing|balance sheet|asset purchase)\b',
 'inflation': r'\b(inflation|consumer price|producer price|cpi|pce|personal income|personal consumption|outlays)\b',
 'labor': r'\b(employment|unemployment|nonfarm|payrolls?|labour market|labor market|jobless|job openings|wages?)\b',
 'growth': r'\b(gdp|gross domestic product|economic growth|economic outlook|economic conditions|industrial production|retail sales|trade balance|international trade|durable goods|recession)\b',
 'geopolitics': r'\b(sanctions?|war|ceasefire|military conflict|tariffs?|geopolitical)\b',
 'metals': r'\b(gold|silver|precious metals?|bullion|metal demand|mine supply)\b'
}
RU_RULES={
 'rates':r'процентн\w*\s+ставк|ключев\w*\s+ставк|денежно.кредитн|фрс|ецб|банк англии',
 'inflation':r'инфляци|потребительск\w*\s+цен|индекс\w*\s+цен',
 'labor':r'безработиц|рынок труда|занятост',
 'growth':r'\bввп\b|экономическ\w*\s+рост|промышленн\w*\s+производств|розничн\w*\s+продаж',
 'geopolitics':r'санкци|пошлин|геополит|перемири|военн\w*\s+конфликт',
 'metals':r'золот|серебр|драгоценн\w*\s+металл',
 'energy':r'нефт|газ\w*|энергет|oil\b|natural gas|opec|brent|lng\b'
}
def atomic(path,data):
 path=pathlib.Path(path);tmp=path.with_name(path.name+'.tmp');tmp.write_text(data,encoding='utf-8');os.replace(tmp,path)
def fingerprint(text):return hashlib.sha256(text.encode('utf-8')).hexdigest()
@contextlib.contextmanager
def job_lock(root):
 root.mkdir(parents=True,exist_ok=True)
 with (root/'collector.lock').open('a+b') as f:
  f.seek(0);f.write(b'0');f.flush();f.seek(0)
  if os.name=='nt':
   import msvcrt
   try:msvcrt.locking(f.fileno(),msvcrt.LK_NBLCK,1)
   except OSError:raise RuntimeError('Collector already running')
  else:
   import fcntl
   fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
  try:yield
  finally:
   f.seek(0)
   if os.name=='nt':msvcrt.locking(f.fileno(),msvcrt.LK_UNLCK,1)
   else:fcntl.flock(f,fcntl.LOCK_UN)
def fetch(source):
 # OS-trust-store curl, HTTPS-only. No insecure flags or policy changes.
 for attempt in range(2):
  p=subprocess.run(['curl','-fL','-sS','--proto','=https','--proto-redir','=https','--connect-timeout','10','--max-time','25','--max-filesize','5242880','--user-agent','MarketNewsCollector/1.0 (personal research; 15 minute polling)',source['url']],capture_output=True,timeout=30)
  if not p.returncode:return p.stdout
  error=p.stderr.decode('utf-8','replace').strip()
  if attempt or '403' in error or '404' in error:raise RuntimeError(error)
  time.sleep(2)
def parse_feed(data,source):
 root=ET.fromstring(data);atom='{http://www.w3.org/2005/Atom}'
 if root.tag=='rss':nodes=root.findall('./channel/item');prefix=''
 elif root.tag==atom+'feed':nodes=root.findall(atom+'entry');prefix=atom
 else:raise ValueError('Response is not RSS/Atom')
 if not nodes:raise ValueError('Empty feed: coverage unverified')
 result=[]
 for item in nodes[:500]:
  text=lambda tag: ''.join(item.find(prefix+tag).itertext()).strip() if item.find(prefix+tag) is not None else ''
  link=text('link') if not prefix else next((n.get('href','') for n in item.findall(atom+'link') if n.get('rel','alternate')=='alternate'),'')
  date=text('pubDate') if not prefix else text('published')
  title=html.unescape(text('title'));description=html.unescape(text('description') if not prefix else text('summary'))
  result.append({'title':title,'url':link,'published_raw':date,'published_utc':parse_date(date),'publication_basis':'RSS pubDate' if not prefix else 'Atom published','summary_original':re.sub('<[^>]+>',' ',description).strip(),'raw_item_xml':ET.tostring(item,encoding='unicode'),'event_utc':None,'event_date_basis':'unknown; publication is not event date'})
 return result
def classify(article,source):
 text=article['title']+' '+article['summary_original']
 categories=[k for k in dict.fromkeys([*RULES,*RU_RULES]) if re.search('(?:'+RULES.get(k,'(?!)')+')|(?:'+RU_RULES.get(k,'(?!)')+')',text,re.I)]
 # Russian wires cover local news too: require a market/global anchor, never country alone.
 if source.get('authority')=='secondary' or source.get('currency')=='RUB':
  market=bool(re.search(r'фрс|ецб|сша|европ|еврозон|доллар|\bевро\b|санкци|пошлин|экспорт|импорт|opec|опек|brent|миров|глобал|бирж|цен\w*\s+на\s+(?:нефт|газ|золот|серебр)|ключев\w*\s+ставк|центробанк|банк россии|federal reserve|ecb|sanctions|tariff|global|market',text,re.I))
  if not market:categories=[]
 if 'metals' in categories and re.search(r'памятн\w*\s+(?:серебр\w*\s+|золот\w*\s+)?монет|commemorative coin|ювелир|украшени|медал',text,re.I) and not re.search(r'миров\w*\s+(?:цен|спрос)|global (?:price|demand)|mine supply|добыч',text,re.I):categories.remove('metals')
 rumor=bool(re.search(r'\b(rumou?r|unconfirmed|reportedly|anonymous)\b|слух|неподтвержден|неподтверждён|аноним|осведомленн\w*\s+источник|осведомлённ\w*\s+источник',text,re.I));currency=source['currency']
 instruments=['EURUSD','GBPUSD','XAUUSD','XAGUSD'] if currency in ['USD','RUB'] or any(x in categories for x in ['geopolitics','metals','energy']) else ['EURUSD'] if currency=='EUR' else ['GBPUSD']
 score=min(100,40+20*bool(categories)+15*('rates' in categories or 'inflation' in categories)+5*('labor' in categories)-20*rumor)
 return {'categories':categories,'instruments':instruments,'score':score,'method':'MYCODING keyword rules v1; lexical relevance, not semantic proof','directness':'official first-party publication' if source.get('authority')=='primary' else 'secondary wire reporting; original source and independence unverified','confidence':'source authority recorded; claims and market impact unverified','rumor':rumor,'currency_direction':'unknown; no forecast or trading signal','interpretation':'Potential relevance by listed keywords only; surprise/consensus not measured.'}
def event_key(article,source):
 title=' '.join(re.findall(r'\w+',article['title'].lower()))
 return fingerprint(source['currency']+'|'+article['published_utc'][:10]+'|'+title)
def database(path):
 db=sqlite3.connect(path);db.row_factory=sqlite3.Row
 db.executescript('''PRAGMA journal_mode=WAL;
 CREATE TABLE IF NOT EXISTS articles(id TEXT PRIMARY KEY, canonical TEXT NOT NULL, semantic TEXT NOT NULL, event_id TEXT NOT NULL, published TEXT NOT NULL, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(canonical,semantic));
 CREATE TABLE IF NOT EXISTS observations(article_id TEXT,source_id TEXT,fetch_utc TEXT,feed_url TEXT,PRIMARY KEY(article_id,source_id));
 CREATE TABLE IF NOT EXISTS quarantine(id TEXT PRIMARY KEY,fetch_utc TEXT,source_id TEXT,reason TEXT,payload TEXT);
 CREATE TABLE IF NOT EXISTS source_state(id TEXT PRIMARY KEY,payload TEXT);
 CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY AUTOINCREMENT,fetch_utc TEXT,payload TEXT);
 ''')
 return db
def collect(root,sources,now=None,fetcher=fetch,calendar_fetcher=None):
 root=pathlib.Path(root);now=now or dt.datetime.now(UTC);stamp=now.isoformat()
 with job_lock(root):
  db=database(root/'news.sqlite3');states=[];excluded=[];new_events=set();revisions=0;quarantined=0;ignored=0
  def retrieve(source):
   fetched=dt.datetime.now(UTC).isoformat() if fetcher is fetch else stamp
   try:
    raw=fetcher(source);items=parse_feed(raw,source);return source,raw,items,None,fetched
   except Exception as e:return source,None,[],str(e),fetched
  with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:results=list(executor.map(retrieve,sources))
  for source,raw,items,error,fetched in results:
   previous=db.execute('SELECT payload FROM source_state WHERE id=?',(source['id'],)).fetchone();state=json.loads(previous[0]) if previous else {}
   oldcut=state.get('cutoff_utc');state.update(id=source['id'],name=source['name'],url=source['url'],authority=source['authority'],last_attempt_utc=fetched,status='error' if error else 'ok',error=error,parsed_entries=len(items),accepted=0,quarantined=0)
   if not error:
    rawroot=root/'raw';rawroot.mkdir(exist_ok=True);rawname=source['id']+'_'+fingerprint(raw.decode('utf-8','replace'))[:16]+'.xml';(rawroot/rawname).write_bytes(raw)
    floor=max(now-dt.timedelta(days=7),dt.datetime.fromisoformat(oldcut)-dt.timedelta(hours=48)) if oldcut else now-dt.timedelta(days=7)
    for article in items:
     article.update(source_id=source['id'],source_name=source['name'],source_authority=source['authority'],feed_url=source['url'],fetch_utc=fetched,raw_feed='raw/'+rawname)
     reason=None
     if not article['published_utc']:reason='missing_or_invalid_publication_timezone'
     elif dt.datetime.fromisoformat(article['published_utc'])>now:reason='future_publication'
     elif urlsplit(article['url']).scheme not in ['https','http'] or not urlsplit(article['url']).netloc:reason='invalid_article_url'
     elif not article['title']:reason='missing_title'
     if reason:
      ident=fingerprint(source['id']+'|'+article['raw_item_xml']);db.execute('INSERT OR REPLACE INTO quarantine VALUES(?,?,?,?,?)',(ident,fetched,source['id'],reason,json.dumps(article,ensure_ascii=False)));quarantined+=1;state['quarantined']+=1;continue
     date=dt.datetime.fromisoformat(article['published_utc'])
     if date<now-dt.timedelta(days=7):ignored+=1;continue
     assessment=classify(article,source)
     if not assessment['categories']:
      ignored+=1;excluded.append({'source_id':source['id'],'url':article['url'],'published_utc':article['published_utc'],'title':article['title'],'reason':'no supported market category/global relevance anchor'});continue
     url=canonical(article['url']);semantic=fingerprint(' '.join(re.findall(r'\w+',article['title'].lower())))
     existing=db.execute('SELECT id FROM articles WHERE canonical=? AND semantic=?',(url,semantic)).fetchone()
     prior_url=db.execute('SELECT event_id FROM articles WHERE canonical=? ORDER BY first_seen DESC LIMIT 1',(url,)).fetchone()
     event=prior_url['event_id'] if prior_url else event_key(article,source);known=db.execute('SELECT id FROM articles WHERE event_id=?',(event,)).fetchone()
     article.update(id=fingerprint(url+'|'+semantic)[:24],canonical_url=url,event_id=event,assessment=assessment,freshness='fresh' if now-date<=dt.timedelta(hours=48) else 'persistent_context',date_precision='second',source_fact=article['title'])
     if not existing:
      revised=bool(db.execute('SELECT id FROM articles WHERE canonical=?',(url,)).fetchone());article['headline_revision']=revised
      db.execute('INSERT INTO articles VALUES(?,?,?,?,?,?,?,?)',(article['id'],url,semantic,event,article['published_utc'],fetched,fetched,json.dumps(article,ensure_ascii=False)));revisions+=int(revised)
      if not known and article['freshness']=='fresh' and date>=floor:new_events.add(event)
     else:article['id']=existing['id'];db.execute('UPDATE articles SET last_seen=? WHERE id=?',(fetched,existing['id']))
     db.execute('INSERT OR REPLACE INTO observations VALUES(?,?,?,?)',(article['id'],source['id'],fetched,source['url']));state['accepted']+=1
    state.update(last_success_utc=fetched,cutoff_utc=stamp,overlap_hours=48)
   states.append(state);db.execute('INSERT OR REPLACE INTO source_state VALUES(?,?)',(source['id'],json.dumps(state,ensure_ascii=False)))
  retention=(now-dt.timedelta(days=30)).isoformat();db.execute('DELETE FROM articles WHERE published<?',(retention,));db.execute('DELETE FROM articles WHERE id NOT IN (SELECT id FROM articles ORDER BY published DESC LIMIT 10000)');db.execute('DELETE FROM observations WHERE article_id NOT IN (SELECT id FROM articles)');db.execute('DELETE FROM quarantine WHERE fetch_utc<?',(retention,));db.execute('DELETE FROM quarantine WHERE id NOT IN (SELECT id FROM quarantine ORDER BY fetch_utc DESC LIMIT 1000)');db.execute('DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY id DESC LIMIT 1000)')
  stored_recent=db.execute('SELECT payload FROM articles WHERE published>=? ORDER BY published DESC,first_seen DESC',((now-dt.timedelta(days=7)).isoformat(),)).fetchall();events={};recent=[]
  source_map={s['id']:s for s in sources}
  for row in stored_recent:
   a=json.loads(row[0]);source=source_map.get(a['source_id'])
   if source is None:continue
   a['assessment']=classify(a,source)
   if a['assessment']['categories']:recent.append((json.dumps(a,ensure_ascii=False),))
   else:excluded.append({'source_id':a['source_id'],'url':a['url'],'published_utc':a['published_utc'],'title':a['title'],'reason':'archived; excluded by current relevance rules'})
  for row in recent:
   article=json.loads(row[0]);date=dt.datetime.fromisoformat(article['published_utc']);article['freshness']='fresh' if now-date<=dt.timedelta(hours=48) else 'persistent_context';article['age_hours']=round((now-date).total_seconds()/3600,2)
   if article['event_id'] in events:events[article['event_id']].setdefault('corroboration',[]).append({'id':article['id'],'source':article['source_name'],'url':article['url']})
   else:events[article['event_id']]=article
  articles=sorted(events.values(),key=lambda a:(a['assessment']['score'],a['published_utc']),reverse=True);fresh=[a for a in articles if a['freshness']=='fresh'];context=[a for a in articles if a['freshness']=='persistent_context']
  counts={'fetch_utc':stamp,'new':len(new_events),'headline_revisions':revisions,'fresh':min(200,len(fresh)),'context':min(200,len(context)),'fresh_total':len(fresh),'context_total':len(context),'quarantined':quarantined,'ignored':ignored,'sources_ok':sum(s['status']=='ok' for s in states),'sources_total':len(states),'primary_institutions_ok':len({s['name'].replace(' speeches','') for s in states if s['status']=='ok' and s['authority']=='primary'}),'source_failures':sum(s['status']=='error' for s in states)}
  db.execute('INSERT INTO runs(fetch_utc,payload) VALUES(?,?)',(stamp,json.dumps(counts)));db.commit()
  data={'contract':{'instruments':['EURUSD','GBPUSD','XAUUSD','XAGUSD'],'fresh_hours':48,'persistent_context_days':7,'automatic_trade_control':False,'ranking':'MYCODING explicit keyword rules; not LLM proof'},'counts':counts,'sources':states,'fresh':fresh[:200],'persistent_context':context[:200],'coverage_gaps':['BLS may be access-blocked; errors mean unknown coverage.','No comprehensive foreign geopolitics/metals wire coverage; RU Interfax/TASS limited RSS windows, original attribution and independence require review.','RSS limited windows: not a guaranteed complete archive or economic calendar.','Publication dates are not event dates; event_utc unknown unless explicitly sourced.']}
  atomic(root/'latest.json',json.dumps(data,ensure_ascii=False,indent=2));atomic(root/'status.json',json.dumps({'counts':counts,'sources':states},ensure_ascii=False,indent=2))
  lines=['# Новости для EURUSD / GBPUSD / XAUUSD / XAGUSD',f'Сбор: {stamp} (UTC). Новых событий: {counts["new"]}; свежих: {len(fresh)}; контекст: {len(context)}.',f'Охват: {counts["sources_ok"]}/{len(states)} лент; карантин за запуск: {quarantined}.','Только информирование. Советник, сигналы и сделки не изменяются. Направление цены неизвестно.','## Источники и ошибки']
  for s in states:lines.append(f'- {s["name"]}: **{s["status"]}**; элементов {s["parsed_entries"]}; отбор {s["accepted"]}; последняя успешная проверка {s.get("last_success_utc","нет")}; ошибка: {s["error"] or "нет"}. [Лента]({s["url"]})')
  for heading,group in [('Свежие публикации — до 48 часов',fresh),('Постоянный контекст — 48 часов–7 дней; НЕ новые новости',context)]:
   lines+=['## '+heading]
   if not group:lines.append('Нет отобранных публикаций; при ошибках источников полнота неизвестна.')
   for a in group[:200]:
    lines+=[f'### [{a["title"]}]({a["url"]})',f'ID `{a["id"]}` · {a["source_name"]} · публикация {a["published_utc"]} UTC · возраст {a["age_hours"]} ч.',f'Факт источника (оригинал без выдуманного перевода): {a["source_fact"]}',f'Правила MYCODING: {", ".join(a["assessment"]["categories"])}; релевантность {a["assessment"]["score"]}/100; инструменты {", ".join(a["assessment"]["instruments"])}.','Интерпретация: потенциальная связь по ключевым словам, не прогноз. Авторитет источника записан отдельно; заявленные факты и влияние на рынок требуют проверки. Дата события неизвестна.',f'Слух по словам: {a["assessment"]["rumor"]}; изменение заголовка: {a.get("headline_revision",False)}.']
  lines+=['## Ограничения']+['- '+g for g in data['coverage_gaps']];md='\n\n'.join(lines)+'\n';atomic(root/'latest.md',md)
  atomic(root/'latest.html','<!doctype html><html lang="ru"><meta charset="utf-8"><title>Market news</title><style>body{background:#111827;color:#e5e7eb;font:15px/1.5 system-ui;max-width:1200px;margin:30px auto;padding:20px}pre{white-space:pre-wrap}a{color:#93c5fd}</style><h1>Новости рынка — первоисточники</h1><pre>'+re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)',r'<a href="\2">\1</a>',html.escape(md))+'</pre></html>')
  rawfiles=sorted((root/'raw').glob('*.xml'),key=lambda p:p.stat().st_mtime,reverse=True) if (root/'raw').exists() else []
  for p in rawfiles[100:]:p.unlink()
  with (root/'journal.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(counts)+'\n')
  journal=(root/'journal.jsonl').read_text(encoding='utf-8').splitlines()
  if len(journal)>1000:atomic(root/'journal.jsonl','\n'.join(journal[-1000:])+'\n')
  def interface_event(a,active):
   categories=a['assessment']['categories']
   return {'id':a['id'],'event_id':a['event_id'],'semantic_dedup_key':a['event_id'],'dedup_method':'canonical URL + normalized headline; exact title/day/currency event grouping, not semantic proof','headline':a['title'],'source_id':a['source_id'],'published_utc':a['published_utc'],'publication_basis':a['publication_basis'],'event_utc':a['event_utc'],'scheduled_event_utc':None,'event_time_basis':'unknown; cannot drive calendar windows','first_observed_utc':db.execute('SELECT first_seen FROM articles WHERE id=?',(a['id'],)).fetchone()[0],'valid_until_utc':(dt.datetime.fromisoformat(a['published_utc'])+dt.timedelta(hours=48 if active else 168)).isoformat(),'new_this_refresh':a['event_id'] in new_events if active else False,'active':active,'persistent_context':not active,'affected_instruments':a['assessment']['instruments'],'categories':categories,'materiality_score':a['assessment']['score'],'materiality_flags':{'policy':'rates' in categories,'inflation':'inflation' in categories,'labor':'labor' in categories,'growth':'growth' in categories,'geopolitics':'geopolitics' in categories,'metals':'metals' in categories,'potential_high_impact':a['assessment']['score']>=75},'source_authority':a['source_authority'],'directness':a['assessment']['directness'],'confidence':a['assessment']['confidence'],'rumor':a['assessment']['rumor'],'source_facts':{'title_original':a['title'],'summary_original':a['summary_original']},'impact_interpretation':a['assessment']['interpretation'],'direction':'unknown','evidence_urls':list(dict.fromkeys([a['url']]+[x['url'] for x in a.get('corroboration',[])]))}
  machine={'schema':'hermes.market_news_state','schema_version':'1.0.0','fetched_utc':stamp,'expires_utc':(now+dt.timedelta(minutes=45)).isoformat(),'generation_id':fingerprint(stamp+json.dumps(counts))[:24],'status':'ok' if counts['source_failures']==0 else 'degraded' if counts['sources_ok'] else 'error','validity':{'maximum_snapshot_age_seconds':2700,'fresh_publication_hours':48,'persistent_context_days':7,'calendar_complete':False,'event_time_required_for_calendar_window':True,'direction_prediction':False},'instruments':['EURUSD','GBPUSD','XAUUSD','XAGUSD'],'source_health':states,'counts':counts,'active_events':[interface_event(a,True) for a in fresh[:200]],'persistent_context':[interface_event(a,False) for a in context[:200]],'coverage_gaps':data['coverage_gaps']}
  from comparison import compare
  from comparison_report import render
  # Keep every distinct canonical source, but only its latest headline revision.
  comparison_articles=[];comparison_urls=set()
  for row in recent:
   a=json.loads(row[0]);url=a.get('canonical_url',a['url'])
   if url not in comparison_urls:comparison_articles.append(a);comparison_urls.add(url)
  comparison=compare(comparison_articles,states)
  comparison['fetched_utc']=stamp
  comparison['generation_id']=machine['generation_id']
  comparison['coverage_gaps']+=data['coverage_gaps']
  comparison['excluded']=excluded
  by_article={e['article_id']:g for g in comparison['groups'] for e in g['evidence']}
  comparison_md,comparison_html=render(comparison,excluded,articles)
  atomic(root/'latest_comparison.json',json.dumps(comparison,ensure_ascii=False,indent=2))
  atomic(root/'latest_comparison.md',comparison_md)
  atomic(root/'latest_comparison.html',comparison_html)
  machine['comparison']=comparison
  machine['snapshot_complete']=True
  for event in machine['active_events']+machine['persistent_context']:
   g=by_article[event['id']]
   event.update(comparison_id=g['id'],comparison_status=g['status'],needs_review=g['needs_review'],comparison_eligible=g['eligible_active'])
  # Calendar is a separate versioned contract. Preserve legacy v1 false/null fields.
  if fetcher is fetch or calendar_fetcher is not None:
   from calendar_extension import collect_extension,fetch_http
   calendar=collect_extension(root,fetcher=calendar_fetcher or fetch_http,with_bls=fetcher is fetch)
   machine['calendar_context']={'schema':'hermes.economic_calendar_state','schema_version':'1.0.0','path':'calendar_state.json','generation_id':calendar['generation_id'],'complete':calendar['coverage']['complete']}
  # Commit machine interface LAST; readers reject expired/missing/unsupported snapshots.
  atomic(root/'news_state.json',json.dumps(machine,ensure_ascii=False,indent=2))
  db.close();return counts
