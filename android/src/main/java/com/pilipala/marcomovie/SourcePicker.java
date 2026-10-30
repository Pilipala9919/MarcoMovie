package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;

/** The source chooser stays above the current screen and never creates a second navigation page. */
final class SourcePicker {
    static void show(MainActivity a){
        if(a.config==null){a.importDialog();return;}
        View anchor=a.getCurrentFocus();Dialog dialog=new Dialog(a);a.sourceDialog=dialog;dialog.setOnDismissListener(d->{if(a.sourceDialog==dialog)a.sourceDialog=null;if(anchor!=null&&anchor.isAttachedToWindow())anchor.requestFocus();});dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel=a.vertical();panel.setPadding(a.dp(26),a.dp(24),a.dp(26),a.dp(18));panel.setBackground(a.bg(0xff18181d,22));
        TextView title=a.text("选择片源",26,MainActivity.WHITE);title.setTypeface(null,Typeface.BOLD);panel.addView(title);a.gap(panel,6);
        TextView hint=a.text("选择后返回首页，显示该片源的内容",14,MainActivity.MUTED);panel.addView(hint);a.gap(panel,16);
        ScrollView scrolling=new TvScrollView(a);scrolling.setClipToPadding(false);LinearLayout grid=a.vertical();grid.setPadding(a.dp(5),a.dp(5),a.dp(5),a.dp(5));scrolling.addView(grid);panel.addView(scrolling,new LinearLayout.LayoutParams(-1,a.dp(286)));
        String selected=a.prefs.getString("selected_site","");Button selectedButton=null;LinearLayout row=null;int index=0;
        for(Cms.Site site:a.config.sites){
            if(index%3==0){row=a.row();row.setClipChildren(false);grid.addView(row);}
            boolean current=site.key.equals(selected);Button button=a.button((current?"✓  ":"")+site.name,"source-choice:"+site.key,()->{
                if(!a.available(site)){a.notice("这个片源需要启用来源扩展，或仍有接口待适配。可以在设置中查看。");return;}
                a.prefs.edit().putString("selected_site",site.key).apply();dialog.dismiss();a.back.clear();a.open(new MainActivity.Screen(a::home),false);
            });button.setTextSize(14);button.setSingleLine(true);button.setEllipsize(android.text.TextUtils.TruncateAt.END);button.setPadding(a.dp(13),a.dp(10),a.dp(13),a.dp(10));
            boolean enabled=a.available(site);button.setSelected(current);
            Runnable paint=()->{boolean focused=button.hasFocus();FocusMotion.style(a,button,focused,current?0xff35353f:0xff242429,MainActivity.WHITE,12,enabled?MainActivity.WHITE:MainActivity.MUTED,MainActivity.DARK,false,1.02f);};
            button.setOnFocusChangeListener((v,f)->paint.run());paint.run();
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,a.dp(52),1);lp.setMargins(a.dp(4),a.dp(4),a.dp(4),a.dp(4));row.addView(button,lp);if(current)selectedButton=button;index++;
        }
        if(row!=null)while(index++%3!=0)row.addView(new View(a),new LinearLayout.LayoutParams(0,1,1));
        a.gap(panel,14);LinearLayout footer=a.row();TextView count=a.text(a.config.sites.size()+" 个片源",13,MainActivity.MUTED);footer.addView(count,new LinearLayout.LayoutParams(0,-2,1));a.addButton(footer,a.navButton("更新配置","source-update",()->{dialog.dismiss();a.importDialog();}));a.addButton(footer,a.navButton("完成","source-close",dialog::dismiss));panel.addView(footer);
        dialog.setContentView(panel);Window window=dialog.getWindow();if(window!=null){window.setBackgroundDrawableResource(android.R.color.transparent);window.setLayout(a.dp(720),-2);window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);WindowManager.LayoutParams params=window.getAttributes();params.dimAmount=.65f;window.setAttributes(params);}
        Button focus=selectedButton;dialog.setOnShowListener(d->{if(focus!=null)focus.requestFocus();else if(grid.getChildCount()>0)((LinearLayout)grid.getChildAt(0)).getChildAt(0).requestFocus();});dialog.show();if(window!=null)window.setLayout(Math.min(a.dp(720),a.root.getWidth()-a.dp(48)),-2);
    }
}
