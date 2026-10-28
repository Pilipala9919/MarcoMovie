package com.pilipala.marcomovie;

import android.animation.*;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.TextView;

/** One interruptible transition per focused view; never changes layout geometry. */
final class FocusMotion {
    static final ArgbEvaluator COLORS=new ArgbEvaluator();
    static final class State {final GradientDrawable background=new GradientDrawable();ValueAnimator animator;int color,stroke,text;float scale=1,elevation;boolean ready,pressed;int targetColor,targetStroke,targetText;float targetScale,targetElevation;}
    static State state(View view){State state=(State)view.getTag(R.id.focus_motion);if(state==null){state=new State();view.setTag(R.id.focus_motion,state);final State saved=state;view.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener(){public void onViewAttachedToWindow(View v){}public void onViewDetachedFromWindow(View v){cancel(saved);saved.pressed=false;v.setAlpha(1);}});}return state;}
    static void cancel(State state){if(state.animator!=null){ValueAnimator old=state.animator;state.animator=null;old.cancel();old.removeAllUpdateListeners();old.removeAllListeners();}}
    static void style(MainActivity a,View view,boolean focused,int normal,int active,int radius,int idleText,int activeText,boolean border,float gain){
        State state=state(view);if(!state.ready){state.ready=true;state.color=normal;state.text=idleText;state.stroke=0;state.scale=1;state.elevation=0;view.animate().cancel();}
        state.background.setCornerRadius(a.dp(radius));view.setBackground(state.background);
        if(!focused)state.pressed=false;state.targetColor=focused?active:normal;state.targetText=focused?activeText:idleText;state.targetStroke=border&&focused?MainActivity.WHITE:0x00f5f5f7;state.targetScale=focused&&!a.reduced?gain:1;state.targetElevation=focused&&gain>1.025f&&!a.reduced?a.dp(4):0;
        transition(a,view,state,focused?160:140);
    }
    static void transition(MainActivity a,View view,State state,int duration){cancel(state);int start=state.color,stroke=state.stroke,text=state.text;float scale=view.getScaleX(),elevation=view.getElevation(),alpha=view.getAlpha();float endScale=a.reduced?1:state.targetScale*(state.pressed?.97f:1),endAlpha=state.pressed?.9f:1;
        if(a.reduced||!view.isAttachedToWindow()){apply(view,state,state.targetColor,state.targetStroke,state.targetText,endScale,state.targetElevation,endAlpha);return;}
        ValueAnimator animator=ValueAnimator.ofFloat(0,1);state.animator=animator;animator.setDuration(duration);animator.setInterpolator(new DecelerateInterpolator());animator.addUpdateListener(value->{float fraction=(Float)value.getAnimatedValue();int color=(Integer)COLORS.evaluate(fraction,start,state.targetColor),outline=(Integer)COLORS.evaluate(fraction,stroke,state.targetStroke);int copy=fraction<.5f?text:state.targetText;float light=(Color.red(color)*.299f+Color.green(color)*.587f+Color.blue(color)*.114f);if(view instanceof TextView&&Color.alpha(color)>220)copy=light>150?MainActivity.DARK:state.targetText==MainActivity.DARK?MainActivity.WHITE:state.targetText;apply(view,state,color,outline,copy,scale+(endScale-scale)*fraction,elevation+(state.targetElevation-elevation)*fraction,alpha+(endAlpha-alpha)*fraction);});animator.addListener(new AnimatorListenerAdapter(){public void onAnimationEnd(Animator animation){if(state.animator==animation){state.animator=null;animation.removeAllListeners();((ValueAnimator)animation).removeAllUpdateListeners();}}});animator.start();
    }
    static void apply(View view,State state,int color,int stroke,int text,float scale,float elevation,float alpha){state.color=color;state.stroke=stroke;state.text=text;state.scale=scale;state.elevation=elevation;state.background.setColor(color);state.background.setStroke(Math.round(view.getResources().getDisplayMetrics().density*2),stroke);if(view instanceof TextView)((TextView)view).setTextColor(text);view.setScaleX(scale);view.setScaleY(scale);view.setElevation(elevation);view.setAlpha(alpha);}
    static void press(MainActivity a,View view,boolean pressed){State state=(State)view.getTag(R.id.focus_motion);if(state==null||state.pressed==pressed)return;state.pressed=pressed;transition(a,view,state,pressed?65:110);}
    static void key(MainActivity a,View view,int key,KeyEvent event){if(key==KeyEvent.KEYCODE_DPAD_CENTER||key==KeyEvent.KEYCODE_ENTER)press(a,view,event.getAction()==KeyEvent.ACTION_DOWN);}
}
