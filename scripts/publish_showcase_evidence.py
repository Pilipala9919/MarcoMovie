"""Publish review-only demo contact sheets to the isolated video branch."""
from pathlib import Path
import base64,json,os,sys,time,urllib.request,urllib.error,io
from PIL import Image,ImageDraw
root=Path(sys.argv[1]);label=sys.argv[2]
files=sorted(root.rglob('*.png'))
pages=[]
for start in range(0,len(files),12):
    batch=files[start:start+12];sheet=Image.new('RGB',(1200,math_h:=((len(batch)+3)//4)*380),(22,25,31));d=ImageDraw.Draw(sheet)
    for idx,f in enumerate(batch):
        im=Image.open(f).convert('RGB');im.thumbnail((290,342));x=(idx%4)*300;y=(idx//4)*380
        sheet.paste(im,(x+(300-im.width)//2,y+26));d.text((x+6,y+5),f.name[:40],fill='white')
    b=io.BytesIO();sheet.save(b,format='JPEG',quality=78);pages.append(base64.b64encode(b.getvalue()).decode())
payload={'label':label,'pages':pages,'files':[str(f.relative_to(root)) for f in files], 'text':{str(f.relative_to(root)):f.read_text(errors='replace') for f in root.rglob('*') if f.is_file() and (f.name=='events.json' or f.name.endswith('-error.txt') or f.suffix=='.xml')}}
data=json.dumps(payload,ensure_ascii=False).encode();base='https://api.github.com/repos/'+os.environ['GITHUB_REPOSITORY'];branch=os.environ['GITHUB_REF_NAME'];path='.showcase-evidence/'+label+'.json'
def req(method,url,obj=None):
    r=urllib.request.Request(url,data=json.dumps(obj).encode() if obj else None,method=method,headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','Content-Type':'application/json'})
    with urllib.request.urlopen(r,timeout=60) as s:return json.load(s)
for attempt in range(4):
    body={'message':'chore(video): save '+label+' capture review evidence','branch':branch,'content':base64.b64encode(data).decode()}
    try:body['sha']=req('GET',base+'/contents/'+path+'?ref='+urllib.parse.quote(branch))['sha']
    except urllib.error.HTTPError as e:
        if e.code!=404:raise
    try:req('PUT',base+'/contents/'+path,body);print('Published review',label,len(files));break
    except urllib.error.HTTPError as e:
        if e.code!=409 or attempt==3:raise
        time.sleep(2)
