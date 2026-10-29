package com.pilipala.marcomovie;

import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Home-only, fixed right rail. Content keeps its own scroll and return focus. */
final class HomeDock {
    final MainActivity a;
    final LinearLayout rail;
    final TextView hint;
    final View[] items=new View[6];
    final String[] labels={"首页","搜索","直播","收藏","网盘","设置"};
    final String[] keys={"nav-home","nav-search","nav-live","nav-favorites","nav-accounts","nav-settings"};
    HomeDock(MainActivity host){
        a=host;rail=a.vertical();rail.setTag("home-dock");rail.setGravity(Gravity.CENTER);rail.setPadding(a.dp(6),a.dp(8),a.dp(6),a.dp(8));
        android.graphics.drawable.GradientDrawable background=a.bg(0xee242429,25);background.setStroke(a.dp(1),0x16ffffff);rail.setBackground(background);rail.setElevation(a.dp(8));
        FrameLayout.LayoutParams size=new FrameLayout.LayoutParams(a.dp(50),a.dp(292),Gravity.RIGHT|Gravity.CENTER_VERTICAL);size.rightMargin=a.dp(20);a.root.addView(rail,size);
        hint=a.text("",12,MainActivity.WHITE);hint.setTag("home-dock-label");hint.setGravity(Gravity.CENTER);hint.setIncludeFontPadding(false);hint.setPadding(a.dp(12),0,a.dp(16),0);hint.setBackground(new LabelBubble());hint.setVisibility(View.INVISIBLE);
        FrameLayout.LayoutParams tip=new FrameLayout.LayoutParams(-2,a.dp(28),Gravity.RIGHT|Gravity.TOP);tip.rightMargin=a.dp(78);a.root.addView(hint,tip);
        Runnable[] actions={()->{if(a.scroll!=null)a.smoothHomeScroll(0);View target=a.root.findViewWithTag("home-history:0");if(target==null)target=a.root.findViewWithTag("home-tab:0");if(target==null)target=a.root.findViewWithTag("primary");if(target!=null)target.requestFocus();},a::globalSearchDialog,()->a.open(new MainActivity.Screen(a::liveSources),true),()->a.open(new MainActivity.Screen(()->new FavoritesScreen(a).show()),true),()->AccountPanel.show(a,items[4]),()->a.open(new MainActivity.Screen(a::settings),true)};
        for(int i=0;i<items.length;i++){
            final int index=i;Icon icon=new Icon(i);items[i]=icon;icon.setTag(keys[i]);icon.setId(View.generateViewId());icon.setContentDescription(labels[i]);icon.setFocusable(true);icon.setFocusableInTouchMode(true);icon.setClickable(true);icon.setSelected(i==0);a.pressFeedback(icon);
            LinearLayout.LayoutParams cell=new LinearLayout.LayoutParams(a.dp(38),a.dp(38));cell.topMargin=a.dp(4);cell.bottomMargin=a.dp(4);rail.addView(icon,cell);
            icon.setOnClickListener(v->actions[index].run());icon.setOnFocusChangeListener((v,focused)->{icon.invalidate();FocusMotion.style(a,icon,focused,Color.TRANSPARENT,MainActivity.WHITE,16,MainActivity.WHITE,MainActivity.DARK,false,1.045f);if(focused)showLabel(index);else {hint.animate().cancel();hint.animate().alpha(0).setDuration(a.reduced?0:100).withEndAction(()->{if(!contains(a.getCurrentFocus()))hint.setVisibility(View.INVISIBLE);}).start();}});
        }
        for(int i=0;i<items.length;i++){items[i].setNextFocusUpId(items[Math.max(0,i-1)].getId());items[i].setNextFocusDownId(items[Math.min(5,i+1)].getId());items[i].setNextFocusRightId(items[i].getId());}
        a.root.getViewTreeObserver().addOnGlobalFocusChangeListener((oldFocus,newFocus)->{
            if(contains(newFocus)&&oldFocus!=null&&!contains(oldFocus)&&oldFocus.getTag() instanceof String&&a.current!=null)a.current.homeReturnFocus=(String)oldFocus.getTag();
        });
    }
    boolean contains(View view){for(View item:items)if(item==view)return true;return false;}
    void showLabel(int index){
        hint.animate().cancel();hint.setText(labels[index]);rail.post(()->{if(!items[index].hasFocus())return;FrameLayout.LayoutParams p=(FrameLayout.LayoutParams)hint.getLayoutParams();p.topMargin=rail.getTop()+items[index].getTop()+(items[index].getHeight()-a.dp(28))/2;hint.setLayoutParams(p);hint.setAlpha(1);hint.setTranslationX(0);hint.setVisibility(View.VISIBLE);if(!a.reduced){hint.setAlpha(0);hint.setTranslationX(a.dp(4));hint.animate().alpha(1).translationX(0).setDuration(140).start();}});
    }
    void rightEdge(View view){if(view!=null)view.setNextFocusRightId(items[0].getId());}
    boolean key(KeyEvent event){
        if(!contains(a.getCurrentFocus())||event.getKeyCode()!=KeyEvent.KEYCODE_DPAD_LEFT)return false;
        if(event.getAction()==KeyEvent.ACTION_DOWN&&event.getRepeatCount()==0){View target=a.current==null||a.current.homeReturnFocus==null?null:a.root.findViewWithTag(a.current.homeReturnFocus);if(target==null||!target.isShown())target=a.root.findViewWithTag("source-switcher");if(target==null)target=a.root.findViewWithTag("primary");if(target!=null)target.requestFocus();}return true;
    }
    final class LabelBubble extends android.graphics.drawable.Drawable {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        @Override public void draw(Canvas c){Rect b=getBounds();float edge=b.right-a.dp(4),middle=b.exactCenterY();paint.setColor(0xff303036);paint.setStyle(Paint.Style.FILL);c.drawRoundRect(new RectF(b.left,b.top,edge,b.bottom),a.dp(9),a.dp(9),paint);Path tip=new Path();tip.moveTo(edge-a.dp(1),middle-a.dp(4));tip.lineTo(b.right,middle);tip.lineTo(edge-a.dp(1),middle+a.dp(4));tip.close();c.drawPath(tip,paint);}
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);}
        @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
    final class Icon extends View {
        final int kind;final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);
        Icon(int kind){super(a);this.kind=kind;}
        void line(Canvas c,float...xy){Path path=new Path();path.moveTo(xy[0],xy[1]);for(int i=2;i<xy.length;i+=2)path.lineTo(xy[i],xy[i+1]);c.drawPath(path,p);}
        @Override protected void onDraw(Canvas c){super.onDraw(c);c.save();c.translate(getWidth()/2f-a.dp(10.5f),getHeight()/2f-a.dp(10.5f));c.scale(a.dp(21)/24f,a.dp(21)/24f);FocusMotion.State motion=(FocusMotion.State)getTag(R.id.focus_motion);boolean light=hasFocus()&&(motion==null||Color.alpha(motion.color)>150);p.setColor(light?MainActivity.DARK:0xffd6d6dd);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(hasFocus()?2:1.7f);p.setStrokeCap(Paint.Cap.ROUND);p.setStrokeJoin(Paint.Join.ROUND);
            switch(kind){
                case 0:line(c,3,10,12,3,21,10);line(c,5,9,5,21,10,21,10,15,14,15,14,21,19,21,19,9);break;
                case 1:c.drawCircle(10.5f,10.5f,6.7f,p);line(c,16,16,21,21);break;
                case 2:c.drawRoundRect(new RectF(3,6,21,19),3,3,p);line(c,8,2,12,6,16,2);line(c,9,22,15,22);break;
                case 3:Path heart=new Path();heart.moveTo(12,21);heart.cubicTo(9,18,2,13,2,8);heart.cubicTo(2,2,9,1,12,6);heart.cubicTo(15,1,22,2,22,8);heart.cubicTo(22,13,15,18,12,21);c.drawPath(heart,p);break;
                case 4:Path cloud=new Path();cloud.moveTo(6,19);cloud.cubicTo(-1,19,0,10,6,10);cloud.cubicTo(6,1,18,1,19,10);cloud.cubicTo(25,10,25,19,19,19);cloud.close();c.drawPath(cloud,p);break;
                case 5:c.drawCircle(12,12,6.3f,p);c.drawCircle(12,12,2.5f,p);for(int n=0;n<8;n++){double t=n*Math.PI/4;line(c,12+(float)Math.cos(t)*7,12+(float)Math.sin(t)*7,12+(float)Math.cos(t)*9.7f,12+(float)Math.sin(t)*9.7f);}break;
            }c.restore();if(isSelected()){p.setStyle(Paint.Style.FILL);p.setColor(hasFocus()?MainActivity.DARK:MainActivity.WHITE);c.drawCircle(a.dp(5),getHeight()/2f,a.dp(1.5f),p);}
        }
        @Override public CharSequence getAccessibilityClassName(){return Button.class.getName();}
    }
}
