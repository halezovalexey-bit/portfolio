"""Isolated official market news collector. No MT5, orders, signals or secrets."""
import datetime as dt, email.utils, re
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
UTC=dt.timezone.utc

def parse_date(value):
 try:
  try: date=email.utils.parsedate_to_datetime(value)
  except (ValueError,TypeError): date=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
  if date.tzinfo is None:return None
  return date.astimezone(UTC).isoformat()
 except (ValueError,TypeError,AttributeError):return None

def canonical(url):
 s=urlsplit(url)
 return urlunsplit((s.scheme.lower(),s.netloc.lower(),s.path,urlencode(sorted((k,v) for k,v in parse_qsl(s.query) if not k.lower().startswith('utm_') and k.lower() not in ['fbclid','gclid'])),''))

def collect(*args,**kwargs):
 from pipeline import collect as run
 return run(*args,**kwargs)

if __name__=='__main__':
 import pathlib,json,sys,traceback
 root=pathlib.Path(__file__).resolve().parent
 try:
  result=collect(root,json.loads((root/'sources.json').read_text(encoding='utf-8')))
  print(json.dumps(result,ensure_ascii=False));sys.exit(0 if result['sources_ok'] else 1)
 except Exception:
  with (root/'fatal.log').open('a',encoding='utf-8') as log:traceback.print_exc(file=log)
  raise
