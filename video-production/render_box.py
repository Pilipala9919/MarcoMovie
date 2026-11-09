"""60 fps tutorial compositor. Live capture and editorial camera moves remain distinct."""
from pathlib import Path
import json, math, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).parent
OUT=ROOT/'delivery';WORK=ROOT/'edit'
for p in [OUT,WORK]:p.mkdir(exist_ok=True)
REG='/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
BOLD='/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
FPS=60
def font(n,b=False):return ImageFont.truetype(BOLD if b else REG,n,index=2)
def text(d,xy,s,n=32,c='#edf1f7',b=False,anchor=None):d.text(xy,s,font=font(n,b),fill=c,anchor=anchor)
def probe(p):return json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(p)]))
def art(ed,s,i,total):
    W,H=(1080,1920) if ed=='mobile' else (1920,1080)
    bg=Image.new('RGB',(W,H));d=ImageDraw.Draw(bg)
    for y in range(H):
        u=y/H;d.line((0,y,W,y),fill=(12+int(5*(1-u)),16+int(6*(1-u)),24+int(9*(1-u))))
    m=64 if ed=='mobile' else 72
    text(d,(m,40),'MARCO MOVIE',26,'#bed2ec',True)
    text(d,(W-m,43),'安卓手机端' if ed=='mobile' else '安卓电视端',24,'#9daabd',anchor='ra')
    d.line((m,99,W-m,99),fill='#354050',width=2)
    text(d,(m,122),f'{i:02d} / {total:02d}    使用指南',21,'#a0b6d0')
    text(d,(m,165),s['title'],44 if ed=='mobile' else 46,b=True)
    label=s.get('label','Android 模拟器实录 · 功能演示')
    text(d,(m,H-45),label,19 if ed=='mobile' else 18,'#96a3b6')
    d.line((m,H-69,W-m,H-69),fill='#354050',width=2)
    panel=Image.new('RGBA',(W,H));q=ImageDraw.Draw(panel)
    src=ROOT/s['source'] if s.get('source') else None
    rect=(0,0,0,0);crop=None
    if src:
        v=next(x for x in probe(src)['streams'] if x['codec_type']=='video');sw,sh=v['width'],v['height']
        if ed=='mobile' and sh>sw:
            crop=(sw,sh-126,0,63);sw,sh=crop[:2]
            box=(72,276,936,1298);tx,ty,fs,maxn=66,1620,30,28
        elif ed=='mobile':
            crop=(sw-126,sh,0,0);sw,sh=crop[:2]
            box=(40,410,1000,600);tx,ty,fs,maxn=66,1150,32,26
        else:box=(72,258,1340,730);tx,ty,fs,maxn=1474,300,29,12
        sc=min(box[2]/sw,box[3]/sh);w=int(sw*sc)//2*2;h=int(sh*sc)//2*2
        x=box[0]+(box[2]-w)//2;y=box[1]+(box[3]-h)//2;rect=(x,y,w,h)
        d.rounded_rectangle((x-7,y-7,x+w+7,y+h+7),radius=24,fill='#06090e',outline='#46536a',width=2)
        for k,t in enumerate(s.get('tips',[])):
            text(q,(tx,ty),f'0{k+1}',19,'#9ebfdf');ty+=32
            for a in range(0,len(t),maxn):text(q,(tx,ty),t[a:a+maxn],fs);ty+=45
            ty+=24
    else:
        ty=380 if ed=='mobile' else 330
        for k,t in enumerate(s.get('body',[])):
            text(q,(m,ty),f'0{k+1}',23,'#9ebfdf');ty+=43
            count=23 if ed=='mobile' else 30
            for a in range(0,len(t),count):text(q,(m,ty),t[a:a+count],36 if ed=='mobile' else 38);ty+=59
            ty+=42
        if (ROOT/'logo.png').exists():
            logo=Image.open(ROOT/'logo.png').convert('RGBA').resize((350,350),Image.Resampling.LANCZOS)
            panel.alpha_composite(logo,((W-350)//2,1370) if ed=='mobile' else (1480,380))
    bp=WORK/f'{ed}-{i:02d}-bg.png';pp=WORK/f'{ed}-{i:02d}-text.png';bg.save(bp);panel.save(pp)
    return W,H,bp,pp,rect,crop

def render(ed):
    plan=json.loads((ROOT/f'plan-{ed}.json').read_text());scenes=plan['scenes'];segments=[];chapters=[];clock=0
    for i,s in enumerate(scenes,1):
        dur=float(s['duration']);W,H,bg,panel,rect,crop=art(ed,s,i,len(scenes));dst=WORK/f'{ed}-{i:02d}-60fps.mp4';segments.append(dst);chapters.append((clock,s['title']));clock+=dur
        if dst.exists() and abs(float(probe(dst)['format']['duration'])-dur)<.08:continue
        cmd=['ffmpeg','-v','error','-threads','4','-filter_complex_threads','4','-loop','1','-framerate','1','-i',str(bg)]
        filters=['[0:v]fps=60[background]']
        if s.get('source'):
            cmd+=['-ss',str(s.get('start',0)),'-i',str(ROOT/s['source']),'-loop','1','-framerate','1','-i',str(panel)]
            x,y,w,h=rect;chain=f'[1:v]setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={dur},'
            if crop:chain+='crop='+':'.join(map(str,crop))+','
            stem=Path(s['source']).stem
            if stem.startswith(('21-','22-','23-','24-')) or (ed=='mobile' and stem.startswith('28-')):
                chain+='scale=1024:-2:flags=lanczos,minterpolate=fps=30:mi_mode=mci:mc_mode=obmc:me_mode=bilat:me=epzs:mb_size=16:search_param=16:scd_threshold=10,'
            # Cosmetic camera moves are generated per output frame. Recorded UI is never sped up.
            z=float(s.get('zoom',1.0));cx,cy=s.get('focus',[.5,.5])
            if z>1:
                ease=f'(1-cos(PI*min(1,max(0,(on/60-1.5)/2.8))))/2*(1-cos(PI*min(1,max(0,({dur}-1.5-on/60)/2.8))))/2'
                zz=f'1+{z-1}*({ease})'
                chain+=f"scale={w*2}:{h*2}:flags=bilinear,fps=30,framerate=fps=60:interp_start=0:interp_end=255:scene=1.0,zoompan=z='{zz}':x='max(0,min(iw-iw/zoom,iw*{cx}-iw/zoom/2))':y='max(0,min(ih-ih/zoom,ih*{cy}-ih/zoom/2))':d=1:s={w}x{h}:fps=60,"
            else:chain+=f'scale={w}:{h}:flags=bilinear,fps=30,framerate=fps=60:interp_start=0:interp_end=255:scene=1.0,'
            filters+=[chain+'setsar=1[ui]',f'[background][ui]overlay={x}:{y}:shortest=0[screen]',"[screen][2:v]overlay=x=0:y='max(0,18*(1-min(1,t/0.7))*(1-min(1,t/0.7)))'[comp]"]
        else:
            cmd+=['-loop','1','-framerate','1','-i',str(panel)]
            filters+=["[background][1:v]overlay=x=0:y='max(0,30*(1-min(1,t/1.1))*(1-min(1,t/1.1)))'[comp]"]
        filters +=[f'[comp]fade=t=in:st=0:d=0.3,fade=t=out:st={dur-.3}:d=0.3,format=yuv420p[out]']
        cmd+=['-filter_complex',';'.join(filters),'-map','[out]','-an','-t',str(dur),'-c:v','libx264','-preset','veryfast','-crf','23','-threads','4','-pix_fmt','yuv420p','-r','60','-fps_mode','cfr','-y',str(dst)]
        subprocess.run(cmd,check=True);print(ed,i,s['title'],flush=True)
    join=WORK/f'{ed}-join.txt';join.write_text('\n'.join("file '"+p.as_posix()+"'" for p in segments))
    # Join several excerpts with a long crossfade for a quiet, uninterrupted music bed.
    music=ROOT/'music.mp3';md=float(probe(music)['format']['duration']);n=math.ceil(clock/(md-8))+1
    mc=['ffmpeg','-v','error']
    for _ in range(n):mc+=['-i',str(music)]
    fs=[];cur='0:a'
    for k in range(1,n):
        out=f'a{k}';fs.append(f'[{cur}][{k}:a]acrossfade=d=8:c1=tri:c2=tri[{out}]');cur=out
    fs.append(f'[{cur}]loudnorm=I=-24:LRA=7:TP=-2,afade=t=in:d=2,afade=t=out:st={clock-3}:d=3[aout]')
    bed=WORK/f'{ed}-music.m4a';mc+=['-filter_complex',';'.join(fs),'-map','[aout]','-t',str(clock),'-c:a','aac','-b:a','192k','-ar','48000','-y',str(bed)];subprocess.run(mc,check=True)
    final=OUT/('MarcoMovie-Android-Phone-60fps.mp4' if ed=='mobile' else 'MarcoMovie-Android-TV-60fps.mp4')
    subprocess.run(['ffmpeg','-v','error','-f','concat','-safe','0','-i',str(join),'-i',str(bed),'-map','0:v','-map','1:a','-c','copy','-movflags','+faststart','-t',str(clock),'-metadata','title='+plan['title'],'-metadata','comment=Original gentle piano arrangement; Blender Foundation open film clips / CC BY 3.0. Captured Android emulator UI; editorial camera motion 60fps.','-y',str(final)],check=True)
    (OUT/f'chapters-{ed}.json').write_text(json.dumps(chapters,ensure_ascii=False,indent=2));print('DONE',str(final),clock,flush=True)
if __name__=='__main__':render(sys.argv[1])
