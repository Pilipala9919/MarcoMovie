from pathlib import Path
import subprocess,json,hashlib,shutil,sys
from PIL import Image,ImageDraw,ImageFont
R=Path('.'); O=R/'short-final'; O.mkdir(exist_ok=True); W=R/'short-work'; W.mkdir(exist_ok=True)
PLANS={"mobile":[[54,70,8],[75,95,11],[99,119,11],[123,144,10],[148,156,5],[160,172,8],[176,187,7],[191,207,10],[211,222,8],[239,249,6],[253,262,6],[282,296,8],[300,312,7],[316,328,7]],"tv":[[54,74,12],[96,104,6],[108,128,12],[132,144,8],[148,161,8],[165,175,7],[179,192,8],[196,210,9],[214,224,7],[258,269,7],[273,287,9],[291,305,9]]}
def run(c): subprocess.run(c,check=True)
def probe(p):return json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(p)]))
font='/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
fontb='/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
for ed,shots in PLANS.items():
 src=Path('phone/MarcoMovie-Android-Phone-60fps.mp4' if ed=='mobile' else 'tv/MarcoMovie-Android-TV-60fps.mp4')
 dims=(1080,1920) if ed=='mobile' else (1920,1080)
 w,h=dims;m=64 if ed=='mobile' else 72
 segments=[];chapters=[];clock=0
 for i,(a,b,dur) in enumerate(shots):
  out=W/f'{ed}-{i:02}.mp4';segments.append(out);chapters.append({'start':clock,'source_start':a,'source_end':b,'duration':dur});clock+=dur
  # Replace old long-form numbering; preserve all original titles and focus animation.
  label=W/f'{ed}-{i:02}.png';im=Image.new('RGB',(440,48),(16,21,31));dr=ImageDraw.Draw(im)
  dr.text((0,4),f'{i+1:02d} / {len(shots):02d}   精简使用展示',font=ImageFont.truetype(font,21,index=2),fill='#a0b6d0');im.save(label)
  filt=f'[0:v]trim=duration={b-a},setpts=(PTS-STARTPTS)*{dur/(b-a)},fps=60[v];[v][1:v]overlay={m}:115,format=yuv420p[out]'
  run(['ffmpeg','-v','error','-ss',str(a),'-i',str(src),'-i',str(label),'-filter_complex_threads','2','-filter_complex',filt,'-map','[out]','-an','-t',str(dur),'-c:v','libx264','-preset','fast','-crf','21','-threads','3','-r','60','-fps_mode','cfr','-y',str(out)])
  print(ed,i+1,clock,flush=True)
 # Short, readable end card. No setup/import instructions.
 im=Image.new('RGB',dims,'#10151f');dr=ImageDraw.Draw(im)
 lines=[('MARCO MOVIE',60,'#edf1f7'),('安卓手机端' if ed=='mobile' else '安卓电视端',42,'#a0b6d0'),('轻松找到，继续观看',38,'#edf1f7'),('舒缓钢琴 · 无人声',24,'#a0b6d0'),('开放电影演示：Blender Foundation · CC BY 3.0',18,'#a0b6d0')]
 ys=[h*.30,h*.40,h*.49,h*.64,h*.71]
 for (s,sz,col),y in zip(lines,ys):dr.text((w/2,y),s,font=ImageFont.truetype(fontb if sz==60 else font,sz,index=2),fill=col,anchor='mt')
 card=W/f'{ed}-end.png';im.save(card);end=W/f'{ed}-end.mp4';segments.append(end)
 run(['ffmpeg','-v','error','-loop','1','-framerate','60','-i',str(card),'-t','3','-vf','fade=t=in:d=0.15,fade=t=out:st=2.65:d=0.35,format=yuv420p','-an','-c:v','libx264','-preset','fast','-crf','21','-threads','3','-y',str(end)])
 clock+=3
 cat=W/f'{ed}-concat.txt';cat.write_text('\n'.join("file '"+p.resolve().as_posix()+"'" for p in segments))
 dest=O/('MarcoMovie-手机端-紧凑版-1分55秒.mp4' if ed=='mobile' else 'MarcoMovie-电视端-紧凑版-1分45秒.mp4')
 # Keep the instrumental track at original tempo, independent of the accelerated picture.
 run(['ffmpeg','-v','error','-f','concat','-safe','0','-i',str(cat),'-i',str(src),'-map','0:v:0','-map','1:a:0','-c:v','copy','-af',f'afade=t=in:d=0.6,afade=t=out:st={clock-2}:d=2','-c:a','aac','-b:a','192k','-t',str(clock),'-movflags','+faststart','-y',str(dest)])
 p=probe(dest);v=next(s for s in p['streams'] if s['codec_type']=='video')
 assert float(p['format']['duration'])<120 and int(v['nb_frames'])==clock*60 and v['avg_frame_rate']=='60/1'
 run(['ffmpeg','-v','error','-xerror','-i',str(dest),'-map','0:v','-map','0:a','-f','null','-'])
 quality={'file':dest.name,'seconds':clock,'frames':int(v['nb_frames']),'fps':v['avg_frame_rate'],'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'size':dest.stat().st_size,'decode':'passed','chapters':chapters}
 (O/f'{ed}-质量检查.json').write_text(json.dumps(quality,ensure_ascii=False,indent=2))
 # Contact sheets for editorial inspection, not part of final package.
 sheet=Image.new('RGB',(1200,((len(shots)+3)//4)*240),'#10151f');dd=ImageDraw.Draw(sheet)
 for i,c in enumerate(chapters):
  jpg=W/f'{ed}-qa-{i}.jpg'
  run(['ffmpeg','-v','error','-ss',str(c['start']+c['duration']/2),'-i',str(dest),'-frames:v','1','-vf','scale=290:210:force_original_aspect_ratio=decrease','-y',str(jpg)])
  f=Image.open(jpg);x=(i%4)*300;y=(i//4)*240;sheet.paste(f,(x,y+25));dd.text((x,y),f"{i+1:02} | {c['start']}s",fill='white')
 sheet.save(W/f'{ed}-review.jpg',quality=90)
 print('DONE',json.dumps(quality,ensure_ascii=False),flush=True)
shutil.copy('phone/CREDITS.txt',O/'素材与音乐说明.txt')
(O/'使用说明.txt').write_text('Marco Movie 紧凑版使用展示\n手机端：1分55秒，1080×1920，60fps。\n电视端：1分45秒，1920×1080，60fps。\n已删除配置链接导入、直播源导入、长片头、重复说明。\n重点功能剪辑；保留原有缩放聚焦，舒缓钢琴保持原速、无人声。\n录屏经过插帧和剪辑，不是原生设备性能测试。\n',encoding='utf-8')
shutil.make_archive('MarcoMovie-两端紧凑版-2分钟以内','zip',O)
