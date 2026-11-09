from pathlib import Path
import subprocess,json,sys,math
from PIL import Image,ImageDraw,ImageFont
root=Path(__file__).parent;ed=sys.argv[1]
f=root/'delivery'/('MarcoMovie-Android-Phone-60fps.mp4' if ed=='mobile' else 'MarcoMovie-Android-TV-60fps.mp4')
meta=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',str(f)]))
v=next(s for s in meta['streams'] if s['codec_type']=='video');a=next(s for s in meta['streams'] if s['codec_type']=='audio')
duration=float(meta['format']['duration']);count=int(v['nb_read_frames'])
assert v['r_frame_rate']=='60/1' and v['avg_frame_rate']=='60/1',(v['r_frame_rate'],v['avg_frame_rate'])
assert abs(count-duration*60)<=3,(count,duration)
dec=subprocess.run(['ffmpeg','-v','error','-i',str(f),'-f','null','-'],capture_output=True)
assert dec.returncode==0 and not dec.stderr,dec.stderr.decode()
qa=root/'delivery'/'review';qa.mkdir(exist_ok=True)
plan=json.loads((root/f'plan-{ed}.json').read_text());clock=0;thumbs=[]
for i,s in enumerate(plan['scenes'],1):
    p=qa/f'{ed}-{i:02d}.jpg';t=clock+min(float(s['duration'])*.6,8);clock+=float(s['duration'])
    subprocess.run(['ffmpeg','-v','error','-ss',str(t),'-i',str(f),'-frames:v','1','-vf','scale=360:-2','-y',str(p)],check=True)
    thumbs.append((p,s['title'],t))
for k in range(0,len(thumbs),6):
    group=thumbs[k:k+6];cw=380;ch=710 if ed=='mobile' else 300
    im=Image.new('RGB',(cw*3,ch*2),(18,22,29));d=ImageDraw.Draw(im);font=ImageFont.truetype('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',20,index=2)
    for n,(p,t,sec) in enumerate(group):
        x=(n%3)*cw;y=(n//3)*ch;im.paste(Image.open(p),(x+10,y+35));d.text((x+10,y+5),f'{k+n+1:02d} {t}',font=font,fill='white')
    im.save(qa/f'{ed}-contact-{k//6+1}.jpg',quality=85)
report={'file':f.name,'duration_seconds':duration,'width':v['width'],'height':v['height'],'frames':count,'frame_rate':v['r_frame_rate'],'audio_codec':a['codec_name'],'decode_errors':False,'note':'Constant 60 fps export and editorial camera motion. Variable-frame-rate Android capture is resampled with scene-aware interframe blending; static UI holds are intentional. This is an edited tutorial, not a device-performance benchmark.'}
(root/'delivery'/f'quality-{ed}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(report)
