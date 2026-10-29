package com.pilipala.marcomovie;

import android.animation.*;
import android.graphics.Rect;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.ScrollView;

/** Retarget remote focus scrolls from their current position without a short-gap jump. */
final class TvScrollView extends ScrollView {
    final MainActivity a;ValueAnimator motion;boolean focusing,layingOut;int goal;
    TvScrollView(MainActivity host){super(host);a=host;setOverScrollMode(OVER_SCROLL_NEVER);}
    void cancelMotion(){if(motion!=null){ValueAnimator old=motion;motion=null;old.removeAllListeners();old.removeAllUpdateListeners();old.cancel();}}
    void moveTo(int y){int height=getChildCount()==0?0:getChildAt(0).getHeight();int end=Math.max(0,Math.min(y,Math.max(0,height-getHeight()+getPaddingTop()+getPaddingBottom())));if(motion!=null&&end==goal)return;cancelMotion();goal=end;int start=getScrollY();if(a.reduced||start==end){super.scrollTo(0,end);return;}motion=ValueAnimator.ofInt(start,end);motion.setDuration(Math.min(300,170+Math.abs(end-start)/8));motion.setInterpolator(new DecelerateInterpolator());motion.addUpdateListener(value->TvScrollView.super.scrollTo(0,(Integer)value.getAnimatedValue()));motion.addListener(new AnimatorListenerAdapter(){public void onAnimationEnd(Animator animator){if(motion==animator)motion=null;}});motion.start();}
    @Override public void scrollTo(int x,int y){if(layingOut&&x==getScrollX()&&y==getScrollY()){super.scrollTo(x,y);return;}if((focusing||layingOut)&&!a.reduced){moveTo(y);return;}cancelMotion();super.scrollTo(x,y);}
    @Override protected void onLayout(boolean changed,int l,int t,int r,int b){layingOut=true;try{super.onLayout(changed,l,t,r,b);}finally{layingOut=false;}}
    @Override public void requestChildFocus(View child,View focused){focusing=true;try{super.requestChildFocus(child,focused);}finally{focusing=false;}}
    @Override public boolean requestChildRectangleOnScreen(View child,Rect rectangle,boolean immediate){Rect area=new Rect(rectangle);offsetDescendantRectToMyCoords(child,area);int delta=computeScrollDeltaToGetChildRectOnScreen(area);if(delta==0)return false;if(immediate||a.reduced)scrollTo(getScrollX(),getScrollY()+delta);else moveTo(getScrollY()+delta);return true;}
    @Override public boolean onTouchEvent(MotionEvent event){if(event.getActionMasked()==MotionEvent.ACTION_DOWN)cancelMotion();return super.onTouchEvent(event);}
    @Override protected void onDetachedFromWindow(){cancelMotion();super.onDetachedFromWindow();}
}
