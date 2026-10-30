package com.pilipala.marcomovie;

import android.animation.ArgbEvaluator;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.TextView;

/** Shared frame clock and velocity-preserving focus/press springs. No layout animation. */
final class FocusMotion {
    static final ArgbEvaluator COLORS=new ArgbEvaluator();
    static final class State {
        final GradientDrawable background=new GradientDrawable();
        final MotionSpring emphasis=new MotionSpring(0,26,.002f),compression=new MotionSpring(0,40,.002f);
        MotionLoop.Step animator;int targetColor,color,stroke,text,normal,active,idleText,activeText;float scale=1,elevation,gain=1;
        boolean ready,pressed,border;
    }
    static State state(View view){State state=(State)view.getTag(R.id.focus_motion);if(state==null){state=new State();view.setTag(R.id.focus_motion,state);final State saved=state;view.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener(){public void onViewAttachedToWindow(View v){}public void onViewDetachedFromWindow(View v){cancel(saved);saved.pressed=false;saved.compression.snap(0);v.setAlpha(1);}});}return state;}
    static void cancel(State state){if(state.animator!=null){MotionLoop.remove(state.animator);state.animator=null;}}
    static void style(MainActivity a,View view,boolean focused,int normal,int active,int radius,int idleText,int activeText,boolean border,float gain){
        State state=state(view);if(!state.ready){state.ready=true;state.color=normal;state.text=idleText;state.stroke=0x00f5f5f7;state.background.setColor(normal);view.animate().cancel();}
        state.targetColor=focused?active:normal;state.normal=normal;state.active=active;state.idleText=idleText;state.activeText=activeText;state.border=border;state.gain=gain;
        state.background.setCornerRadius(a.dp(radius));if(view.getBackground()!=state.background)view.setBackground(state.background);
        if(!focused){state.pressed=false;state.compression.target(0);}state.emphasis.target(focused?1:0);transition(a,view,state);
    }
    static void transition(MainActivity a,View view,State state){
        if(a.reduced||!view.isAttachedToWindow()){cancel(state);state.emphasis.snap(state.emphasis.target);state.compression.snap(state.compression.target);paint(view,state,a.reduced);return;}
        if(!state.emphasis.step(0)&&!state.compression.step(0)){paint(view,state,false);return;}
        if(state.animator!=null)return;
        state.animator=seconds->{if(!view.isAttachedToWindow()){state.animator=null;return false;}boolean moving=state.emphasis.step(seconds);moving|=state.compression.step(seconds);paint(view,state,false);if(!moving)state.animator=null;return moving;};MotionLoop.add(state.animator);
    }
    static void paint(View view,State state,boolean reduced){
        float f=Math.max(0,Math.min(1,state.emphasis.value)),p=Math.max(0,Math.min(1,state.compression.value));
        int color=(Integer)COLORS.evaluate(f,state.normal,state.active),outline=state.border?(Integer)COLORS.evaluate(f,0x00f5f5f7,MainActivity.WHITE):0x00f5f5f7;
        int text=f<.5f?state.idleText:state.activeText;float light=(Color.red(color)*.299f+Color.green(color)*.587f+Color.blue(color)*.114f);
        if(view instanceof TextView&&Color.alpha(color)>220)text=light>150?MainActivity.DARK:state.activeText==MainActivity.DARK?MainActivity.WHITE:state.activeText;
        apply(view,state,color,outline,text,reduced?1:(1+(state.gain-1)*f)*(1-.03f*p),0,1-.1f*p);
    }
    static void apply(View view,State state,int color,int stroke,int text,float scale,float elevation,float alpha){
        if(state.color!=color)state.background.setColor(color);if(state.stroke!=stroke)state.background.setStroke(Math.round(view.getResources().getDisplayMetrics().density*2),stroke);
        if(view instanceof TextView&&((TextView)view).getCurrentTextColor()!=text)((TextView)view).setTextColor(text);
        if(view.getScaleX()!=scale)view.setScaleX(scale);if(view.getScaleY()!=scale)view.setScaleY(scale);
        if(view.getElevation()!=elevation)view.setElevation(elevation);if(view.getAlpha()!=alpha)view.setAlpha(alpha);
        state.color=color;state.stroke=stroke;state.text=text;state.scale=scale;state.elevation=elevation;
    }
    static void press(MainActivity a,View view,boolean pressed){State state=(State)view.getTag(R.id.focus_motion);if(state==null||state.pressed==pressed)return;state.pressed=pressed;state.compression.target(pressed?1:0);transition(a,view,state);}
    static void key(MainActivity a,View view,int key,KeyEvent event){if(key==KeyEvent.KEYCODE_DPAD_CENTER||key==KeyEvent.KEYCODE_ENTER)press(a,view,event.getAction()==KeyEvent.ACTION_DOWN);}
}
