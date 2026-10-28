package com.pilipala.marcomovie;

import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Bounded CPU-softened artwork, available on Android 6 without a GPU blur API. */
final class ImmersivePoster extends FrameLayout {
    final MainActivity a;final Art image;final Backdrop backdrop;int revision;
    ImmersivePoster(MainActivity host,String tag){
        super(host);a=host;setTag(tag);backdrop=new Backdrop();
        TextView placeholder=a.text("暂无封面",14,MainActivity.MUTED);placeholder.setGravity(Gravity.CENTER);addView(placeholder,new LayoutParams(-1,-1));
        image=new Art();image.setScaleType(ImageView.ScaleType.FIT_CENTER);addView(image,new LayoutParams(-1,-1));
    }
    void load(String address){a.poster(address,image);}
    void soften(Bitmap bitmap){
        final int token=++revision;final int generation=a.generation;
        if(bitmap==null){backdrop.bitmap=null;backdrop.invalidate();return;}
        a.artwork.execute(()->{
            // Never alter or recycle the shared image-cache bitmap.
            Bitmap small=Bitmap.createScaledBitmap(bitmap,48,72,true);int[] pixels=new int[48*72];small.getPixels(pixels,0,48,0,0,48,72);if(small!=bitmap)small.recycle();
            for(int pass=0;pass<3;pass++){int[] next=new int[pixels.length];for(int y=0;y<72;y++)for(int x=0;x<48;x++){int red=0,green=0,blue=0,count=0;for(int dy=-3;dy<=3;dy++)for(int dx=-3;dx<=3;dx++){int c=pixels[Math.max(0,Math.min(71,y+dy))*48+Math.max(0,Math.min(47,x+dx))];red+=Color.red(c);green+=Color.green(c);blue+=Color.blue(c);count++;}next[y*48+x]=Color.rgb(red/count,green/count,blue/count);}pixels=next;}
            Bitmap blurred=Bitmap.createBitmap(pixels,48,72,Bitmap.Config.ARGB_8888);
            a.ui.post(()->{if(token!=revision||generation!=a.generation||a.isFinishing()){blurred.recycle();return;}backdrop.bitmap=blurred;backdrop.invalidate();});
        });
    }
    final class Art extends ImageView {
        final Paint mask=new Paint(3);
        Art(){super(a);}
        @Override public void setImageBitmap(Bitmap b){super.setImageBitmap(b);soften(b);}
        @Override protected void onDraw(Canvas canvas){
            if(getDrawable()==null)return;
            int save=canvas.saveLayer(0,0,getWidth(),getHeight(),null);super.onDraw(canvas);
            mask.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
            mask.setShader(new LinearGradient(0,0,getWidth(),0,new int[]{0x00ffffff,0xffffffff,0xffffffff,0x00ffffff},new float[]{0,.07f,.78f,1},Shader.TileMode.CLAMP));canvas.drawRect(0,0,getWidth(),getHeight(),mask);
            mask.setShader(new LinearGradient(0,0,0,getHeight(),new int[]{0x00ffffff,0xffffffff,0xffffffff,0x00ffffff},new float[]{0,.06f,.86f,1},Shader.TileMode.CLAMP));canvas.drawRect(0,0,getWidth(),getHeight(),mask);mask.setXfermode(null);mask.setShader(null);canvas.restoreToCount(save);
        }
    }
    final class Backdrop extends View {
        Bitmap bitmap;final Paint paint=new Paint(3);
        Backdrop(){super(a);setTag("detail-backdrop");setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onDraw(Canvas c){
            c.drawColor(MainActivity.DARK);if(bitmap==null)return;
            paint.setAlpha(145);c.drawBitmap(bitmap,null,new RectF(-getWidth()*.08f,-getHeight()*.2f,getWidth()*.73f,getHeight()*1.2f),paint);paint.setAlpha(255);
            paint.setShader(new LinearGradient(0,0,getWidth()*.78f,0,new int[]{0x22101013,MainActivity.DARK},null,Shader.TileMode.CLAMP));c.drawRect(0,0,getWidth(),getHeight(),paint);
            paint.setShader(new LinearGradient(0,getHeight()*.45f,0,getHeight(),new int[]{0x00101013,MainActivity.DARK},null,Shader.TileMode.CLAMP));c.drawRect(0,0,getWidth(),getHeight(),paint);paint.setShader(null);
        }
    }
}
