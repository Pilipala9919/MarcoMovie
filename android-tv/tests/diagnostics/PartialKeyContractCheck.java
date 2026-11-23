package com.pilipala.marcomovie;

/** Run on the cloud host JVM. These checks are an oracle contract, never native acceptance. */
public final class PartialKeyContractCheck {
    static int checks;
    static PartialKeyContract.State at(int index, int start, int end, int cards) {
        PartialKeyContract.State s = new PartialKeyContract.State();
        s.index=index; s.start=start; s.end=end; s.cards=cards; s.rows=(cards+4)/5;
        s.items=500; s.page=1; s.columns=5; s.attached=s.shown=s.visible=s.enabled=s.active=s.ready=true;
        s.pending=cards<end-start; s.focusId=100+index; s.nextId=s.focusId; s.nextIndex=index;
        return s;
    }
    static void expect(boolean ok, String label) {
        if(!ok) throw new AssertionError(label); checks++; System.out.println("PASS "+label);
    }
    public static void main(String[] args) {
        PartialKeyContract.State a=at(0,0,360,7), b=at(360,360,500,2);
        a.nextId=105; a.nextIndex=5;
        expect("PREMATURE_WINDOW_ADVANCE".equals(PartialKeyContract.downViolation(a,b)),
                "focus callback jumps 0 to 360 before unseen rows: reject");
        expect("partial_focus_prefetch_boundary".equals(PartialKeyContract.witnessKind(a)),
                "native input to partial prefetch row is a witness");
        a=at(10,0,360,11); b=at(10,0,360,12);
        expect(PartialKeyContract.downViolation(a,b)==null,"uncreated next row can retain focus temporarily");
        expect("partial_tail_self".equals(PartialKeyContract.witnessKind(a)),"self-edge witness");
        b=at(360,360,500,5);
        expect("PREMATURE_WINDOW_ADVANCE".equals(PartialKeyContract.downViolation(a,b)),"partial self edge cannot skip window");
        a=at(355,0,360,360);
        expect(PartialKeyContract.downViolation(a,b)==null,"logical last row can advance to contiguous next window");
        b=at(380,360,500,25);
        expect("SKIPPED_FOCUS_ROW".equals(PartialKeyContract.downViolation(a,b)),"legal window advance cannot skip focus rows");
        b=at(720,720,1000,5); b.items=1000;
        expect("SKIPPED_WINDOW".equals(PartialKeyContract.downViolation(a,b)),"multiple windows cannot be skipped");
        a=at(100,0,360,120); b=at(95,0,360,125);
        expect("DOWN_MOVED_FOCUS_BACKWARDS".equals(PartialKeyContract.downViolation(a,b)),"down cannot reverse focus");
        b=at(105,0,360,125); b.items=499;
        expect("DATASET_SHRANK".equals(PartialKeyContract.downViolation(a,b)),"dataset loss rejected");
        a=at(1995,1800,2001,201); b=at(2000,1800,2001,201); a.items=b.items=2001;
        expect(PartialKeyContract.downViolation(a,b)==null,"partial final row with 2001st item accepted");
        a=at(2000,1800,2001,201); a.items=2001;
        expect(PartialKeyContract.downViolation(a,b)==null,"tail can retain focus");
        a=at(5,0,360,10); a.visible=false;
        expect(!PartialKeyContract.partialKeyWitness(a),"offscreen focus is not a partial native witness");
        a.visible=true; a.attached=false;
        expect(!PartialKeyContract.partialKeyWitness(a),"detached focus not a witness");
        a.attached=true; a.busy=true;
        expect(!PartialKeyContract.partialKeyWitness(a),"busy loading is separate from active render witness");
        a.busy=false; a.pending=false;
        expect(!PartialKeyContract.partialKeyWitness(a),"already finished render not a partial witness");
        for(int n=0;n<2000;n+=5) {
            int start=(n/360)*360, end=Math.min(2001,start+360);
            a=at(n,start,end,end-start); a.items=2001;
            int next=n+5, nextStart=(next/360)*360, nextEnd=Math.min(2001,nextStart+360);
            b=at(next,nextStart,nextEnd,nextEnd-nextStart); b.items=2001;
            if(PartialKeyContract.downViolation(a,b)!=null) throw new AssertionError("valid row "+n);
        }
        expect(true,"all 400 contiguous first-column moves across 2001 entries accepted");
        System.out.println("CHECKS="+checks+"; NATIVE_ASSERTIONS=0");
    }
}
