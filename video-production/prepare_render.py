from pathlib import Path
import os,subprocess,struct,math,json
ROOT=Path(__file__).parent
def vlq(x):
    a=[x&127];x>>=7
    while x:a.insert(0,(x&127)|128);x>>=7
    return bytes(a)
def compose():
    # An original, quiet 32-bar piano arrangement for the tutorial, 72 BPM.
    ppq=480;events=[]
    events.append((0,b'\xff\x51\x03'+int(60_000_000/72).to_bytes(3,'big')))
    events.append((0,bytes([0xc0,0])))
    chords=[[48,55,59,64],[45,52,55,60],[41,48,52,57],[43,50,57,62]]
    melody=[76,74,71,72,74,72,69,67,72,71,69,67,74,72,71,67]
    def note(t,p,v,l):
        events.append((round(t*ppq),bytes([0x90,p,v])));events.append((round((t+l)*ppq),bytes([0x80,p,0])))
    for bar in range(32):
        c=chords[bar%4];off=bar*4
        note(off,c[0]-12,32,3.6)
        for k,beat in enumerate([0,.75,1.5,2.25,3]):note(off+beat,c[[0,1,2,3,2][k]],38+(bar+k)%7,1.5)
        note(off+.1,melody[(bar*2)%16],47,1.7)
        note(off+2.1,melody[(bar*2+1)%16],43,1.8)
    events.sort(key=lambda x:x[0]);b=b'';clock=0
    for t,e in events:b+=vlq(t-clock)+e;clock=t
    b+=b'\x00\xff\x2f\x00'
    (ROOT/'music.mid').write_bytes(b'MThd'+struct.pack('>IHHH',6,0,1,ppq)+b'MTrk'+struct.pack('>I',len(b))+b)
    sf=Path('/usr/share/sounds/sf2/FluidR3_GM.sf2')
    subprocess.run(['fluidsynth','-ni','-R','1','-C','0','-g','.7',str(sf),str(ROOT/'music.mid'),'-F',str(ROOT/'music.wav'),'-r','48000'],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['ffmpeg','-v','error','-i',str(ROOT/'music.wav'),'-af','afade=t=in:d=2,afade=t=out:st=103:d=5','-t','108','-c:a','libmp3lame','-b:a','192k','-y',str(ROOT/'music.mp3')],check=True)
    (ROOT/'music-credit.txt').write_text('Original gentle piano arrangement for Marco Movie; GM piano rendered with FluidR3. No voice or percussion.')
if __name__=='__main__':compose()
