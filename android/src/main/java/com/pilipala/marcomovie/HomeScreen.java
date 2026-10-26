package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONObject;

/** A vertically browsed TV library built only from the selected source's content. */
final class HomeScreen {
    final int COLUMNS, SECTION_LIMIT, CATEGORY_LIMIT;
    final MainActivity a;
    final Cms.Site site;
    final Set<String> shown=new LinkedHashSet<>();
    final List<List<View>> focusRows=new ArrayList<>();
    final List<Section> sections=new ArrayList<>();
    int ticket;
    int posterWidth;
    TextView selectedTitle,selectedInfo;
    boolean firstResult;Snapshot snapshot;
    static final class Snapshot {final long time=System.currentTimeMillis();final List<Cms.Video> videos;final List<Cms.Category> categories;final String name,skip;final java.util.Map<String,List<Cms.Video>> loaded=new java.util.HashMap<>();Snapshot(List<Cms.Video> videos,List<Cms.Category> categories,String name,String skip){this.videos=videos;this.categories=categories;this.name=name;this.skip=skip;}}


    HomeScreen(MainActivity activity,Cms.Site selected){a=activity;site=selected;COLUMNS=Math.max(5,Math.min(8,a.prefs.getInt("home_columns",6)));SECTION_LIMIT=COLUMNS*Math.max(1,Math.min(4,a.prefs.getInt("home_rows",2)));CATEGORY_LIMIT=Math.max(0,Math.min(5,a.prefs.getInt("home_sections",3)));}

    void show(){
        a.renderPage("","");ticket=a.generation;
        // The flat charcoal surface lets the artwork, rather than the background,
        // carry the colour. Keep the existing native top navigation.
        a.root.setBackgroundColor(0xff101013);
        a.body.setPadding(a.dp(42),a.dp(14),a.dp(42),a.dp(36));
        a.body.setClipChildren(false);a.body.setClipToPadding(false);a.scroll.setClipChildren(false);
        float screenDp=a.getResources().getDisplayMetrics().widthPixels/a.getResources().getDisplayMetrics().density;
        posterWidth=Math.max(60,Math.min(COLUMNS==5?120:100,(int)((screenDp-84-(COLUMNS-1)*18)/COLUMNS)-8));

        LinearLayout intro=a.row();intro.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titles=a.vertical();
        titles.setTag("source-switcher");titles.setId(View.generateViewId());titles.setFocusable(true);titles.setFocusableInTouchMode(true);titles.setClickable(true);titles.setPadding(a.dp(7),a.dp(3),a.dp(7),a.dp(3));titles.setContentDescription("当前片源："+site.name+"，按确认键切换");titles.setOnClickListener(view->a.chooseSources());titles.setOnFocusChangeListener((view,focus)->{GradientDrawable background=a.bg(focus?0xff292930:Color.TRANSPARENT,9);if(focus)background.setStroke(a.dp(2),MainActivity.WHITE);titles.setBackground(background);});
        selectedTitle=a.text("发现好故事",23,MainActivity.WHITE);selectedTitle.setTypeface(null,Typeface.BOLD);selectedTitle.setSingleLine(true);selectedTitle.setEllipsize(TextUtils.TruncateAt.END);titles.addView(selectedTitle);
        selectedInfo=a.text(site.name+"  ⌄",11,0xff9b9ba4);selectedInfo.setSingleLine(true);selectedInfo.setEllipsize(TextUtils.TruncateAt.END);titles.addView(selectedInfo);
        intro.addView(titles,new LinearLayout.LayoutParams(0,a.dp(49),1));
        View categoryMenu=a.navButton("全部分类  ›","home-categories",()->a.open(new MainActivity.Screen(()->a.categories(site)),true));
        intro.addView(categoryMenu,new LinearLayout.LayoutParams(a.dp(112),a.dp(38)));a.body.addView(intro);
        a.gap(a.body,5);

        Section recommendation=new Section("片源推荐",0,null);sections.add(recommendation);a.body.addView(recommendation.container);
        Snapshot saved=a.homeData.get(site.key);if(saved!=null&&System.currentTimeMillis()-saved.time<300000){snapshot=saved;renderSnapshot(recommendation);return;}
        a.worker.execute(()->{
            try{
                SourceEngine source=a.engine(site);String home=source.home();List<Cms.Category> categories=Cms.categories(home);
                Cms.Listing listing=new JSONObject(home).has("list")?Cms.listing(home):new Cms.Listing();
                clean(listing.videos);
                if(listing.videos.isEmpty())try{listing=Cms.listing(source.homeVideos());clean(listing.videos);}catch(Exception ignored){}
                String name="片源推荐";String consumedCategory="";
                if(listing.videos.isEmpty()&&!categories.isEmpty()){
                    Cms.Category first=categories.get(0);listing=Cms.listing(source.category(first.id,1));clean(listing.videos);name=first.name;consumedCategory=first.id;
                }
                final Cms.Listing initial=listing;final String initialName=name;final String skip=consumedCategory;
                a.ui.post(()->{
                    if(!active())return;
                    snapshot=new Snapshot(initial.videos,categories,initialName,skip);a.homeData.put(site.key,snapshot);renderSnapshot(recommendation);
                });
            }catch(Exception error){a.ui.post(()->{if(active()){recommendation.state.setText(a.message(error));addRetry(recommendation);}});}
        });
    }

    boolean active(){return ticket==a.generation&&!a.isFinishing();}
    void renderSnapshot(Section recommendation){
        recommendation.title.setText(snapshot.name);if(!snapshot.skip.isEmpty())for(Cms.Category category:snapshot.categories)if(category.id.equals(snapshot.skip))recommendation.category=category;fill(recommendation,snapshot.videos);int number=1;
        for(Cms.Category category:snapshot.categories){if(number>CATEGORY_LIMIT)break;if(category.id.equals(snapshot.skip))continue;Section section=new Section(category.name,number++,category);sections.add(section);a.body.addView(section.container);List<Cms.Video> saved=snapshot.loaded.get(category.id);if(saved!=null)fill(section,saved);else loadCategory(section,category);}
        if(snapshot.videos.isEmpty()){recommendation.state.setVisibility(View.VISIBLE);recommendation.state.setText("这个来源暂时没有推荐内容，可使用全局搜索找片。");}
    }
    static void clean(List<Cms.Video> videos){videos.removeIf(video->video==null||video.id==null||video.id.trim().isEmpty());}

    void loadCategory(Section section,Cms.Category category){
        a.worker.execute(()->{
            try{
                if(!active())return;Cms.Listing listing=Cms.listing(a.engine(site).category(category.id,1));clean(listing.videos);
                a.ui.post(()->{if(active()){if(snapshot!=null)snapshot.loaded.put(category.id,listing.videos);fill(section,listing.videos);}});
            }catch(Exception error){a.ui.post(()->{if(active())section.state.setText("这个分区暂时不可用");});}
        });
    }

    void addRetry(Section section){
        View retry=a.navButton("重新加载","home-retry",()->a.refresh());section.content.addView(retry,new LinearLayout.LayoutParams(-2,-2));
    }

    void fill(Section section,List<Cms.Video> videos){a.learnTitles(videos);
        section.state.setVisibility(View.GONE);section.content.removeAllViews();
        List<Cms.Video> selected=new ArrayList<>();
        for(Cms.Video video:videos){String key=video.id.trim();if(shown.add(key)){selected.add(video);if(selected.size()==SECTION_LIMIT)break;}}
        if(selected.isEmpty()){
            if(!videos.isEmpty()){section.container.setVisibility(View.GONE);return;}
            section.state.setText("这个分区暂无内容");section.state.setVisibility(View.VISIBLE);return;
        }
        for(int offset=0;offset<selected.size();offset+=COLUMNS){
            LinearLayout row=a.row();row.setGravity(Gravity.TOP);row.setClipChildren(false);row.setClipToPadding(false);row.setPadding(0,a.dp(3),0,a.dp(9));
            section.content.addView(row,new LinearLayout.LayoutParams(-1,-2));
            List<View> focusRow=new ArrayList<>();
            for(int column=0;column<COLUMNS;column++){
                int index=offset+column;
                LinearLayout.LayoutParams cell=new LinearLayout.LayoutParams(0,-2,1);cell.setMargins(0,0,column==COLUMNS-1?0:a.dp(18),0);
                if(index>=selected.size()){row.addView(new View(a),cell);continue;}
                Cms.Video video=selected.get(index);View card=card(video,section.index*SECTION_LIMIT+index);row.addView(card,cell);focusRow.add(card);
            }
            // Insert rows by their visual section order even if category requests
            // complete in a different order.
            section.rows.add(focusRow);
        }
        wireNavigation();restoreFocus();
    }

    View card(Cms.Video video,int index){
        LinearLayout card=a.vertical();card.setPadding(a.dp(4),a.dp(4),a.dp(4),a.dp(4));card.setGravity(Gravity.CENTER_HORIZONTAL);card.setClipChildren(false);card.setClipToPadding(false);
        ImageView image=new ImageView(a);image.setScaleType(ImageView.ScaleType.CENTER_CROP);image.setBackground(a.bg(0xff24242b,7));image.setClipToOutline(true);
        card.addView(image,new LinearLayout.LayoutParams(a.dp(posterWidth),a.dp(posterWidth*1.5f)));a.poster(video.poster,image);
        TextView title=a.text(video.title,12,0xffe9e9ee);title.setSingleLine(true);title.setEllipsize(TextUtils.TruncateAt.END);title.setPadding(a.dp(2),a.dp(6),a.dp(2),0);card.addView(title,new LinearLayout.LayoutParams(-1,a.dp(23)));
        card.setFocusable(true);card.setFocusableInTouchMode(true);card.setClickable(true);card.setTag("home-video:"+index);card.setId(View.generateViewId());card.setContentDescription(video.title+(video.remarks==null||video.remarks.isEmpty()?"":"，"+video.remarks));
        card.setOnClickListener(view->a.open(new MainActivity.Screen(()->a.detail(site,video)),true));
        card.setOnFocusChangeListener((view,focused)->{
            view.animate().cancel();GradientDrawable outline=a.bg(focused?0xff292930:Color.TRANSPARENT,10);if(focused)outline.setStroke(a.dp(2),0xfff8f8fc);card.setBackground(outline);
            view.animate().scaleX(focused&&!a.reduced?1.035f:1).scaleY(focused&&!a.reduced?1.035f:1).setDuration(a.reduced?0:180).setInterpolator(new DecelerateInterpolator()).start();
            title.setTextColor(focused?Color.WHITE:0xffbfbfc7);
            if(focused){selectedTitle.setText(video.title);String note=video.remarks==null?"":video.remarks;selectedInfo.setText(site.name+(note.isEmpty()?"":" · "+note)+"  ⌄");view.requestRectangleOnScreen(new Rect(0,-a.dp(8),view.getWidth(),view.getHeight()+a.dp(10)),false);}
        });return card;
    }

    void wireNavigation(){
        focusRows.clear();for(Section section:sections)focusRows.addAll(section.rows);
        View nav=a.root.findViewWithTag("nav-home");if(nav!=null&&nav.getId()==View.NO_ID)nav.setId(View.generateViewId());
        for(int r=0;r<focusRows.size();r++){
            List<View> row=focusRows.get(r);
            Section owner=null;for(Section section:sections)if(section.rows.contains(row)){owner=section;break;}
            for(int c=0;c<row.size();c++){
                View card=row.get(c);card.setNextFocusLeftId(row.get(Math.max(0,c-1)).getId());card.setNextFocusRightId(row.get(Math.min(row.size()-1,c+1)).getId());
                if(r==0)card.setNextFocusUpId(a.root.findViewWithTag("source-switcher").getId());
                else if(owner!=null&&owner.rows.get(0)==row)card.setNextFocusUpId(owner.more.getId());
                else if(r>0){List<View> above=focusRows.get(r-1);card.setNextFocusUpId(above.get(Math.min(c,above.size()-1)).getId());}else if(nav!=null)card.setNextFocusUpId(nav.getId());
                if(r+1<focusRows.size()){List<View> below=focusRows.get(r+1);card.setNextFocusDownId(below.get(Math.min(c,below.size()-1)).getId());}else card.setNextFocusDownId(card.getId());
            }
            if(owner!=null&&owner.rows.get(0)==row){owner.more.setNextFocusDownId(row.get(row.size()-1).getId());if(r>0){List<View> above=focusRows.get(r-1);owner.more.setNextFocusUpId(above.get(above.size()-1).getId());}else if(nav!=null)owner.more.setNextFocusUpId(nav.getId());}
        }
    }

    void restoreFocus(){
        a.ui.post(()->{
            if(!active()||a.current==null)return;
            if(a.current.focus!=null){View restored=a.root.findViewWithTag(a.current.focus);if(restored!=null){restored.requestFocus();if(a.scroll!=null)a.scroll.scrollTo(0,a.current.scroll);return;}}
            if(!firstResult&&!focusRows.isEmpty()){firstResult=true;focusRows.get(0).get(0).requestFocus();}
        });
    }

    final class Section {
        final int index;final LinearLayout container=a.vertical(),content=a.vertical();final TextView title,state,more;final List<List<View>> rows=new ArrayList<>();Cms.Category category;
        Section(String name,int index,Cms.Category category){
            this.category=category;
            this.index=index;container.setClipChildren(false);container.setClipToPadding(false);
            LinearLayout heading=a.row();heading.setPadding(a.dp(4),a.dp(index==0?2:8),a.dp(4),a.dp(4));
            title=a.text(name,16,0xfff1f1f5);title.setTypeface(null,Typeface.BOLD);heading.addView(title,new LinearLayout.LayoutParams(0,-2,1));
            more=a.text("查看全部  ›",11,0xffa1a1ad);more.setGravity(Gravity.CENTER);more.setPadding(a.dp(9),0,a.dp(9),0);more.setFocusable(true);more.setFocusableInTouchMode(true);more.setClickable(true);more.setId(View.generateViewId());more.setTag("home-category-more:"+index);more.setOnClickListener(view->a.open(new MainActivity.Screen(()->{if(this.category==null)a.categories(site);else a.videos(site,this.category.id,this.category.name,1,null);}),true));more.setOnFocusChangeListener((view,focused)->{more.setTextColor(focused?Color.BLACK:0xffa1a1ad);more.setBackground(a.bg(focused?0xfff4f4f7:Color.TRANSPARENT,12));});heading.addView(more,new LinearLayout.LayoutParams(-2,a.dp(24)));container.addView(heading);
            state=a.text("正在整理片单…",12,0xff8b8b95);state.setPadding(a.dp(4),a.dp(10),0,a.dp(14));container.addView(state);container.addView(content);content.setClipChildren(false);content.setClipToPadding(false);
        }
    }
}
