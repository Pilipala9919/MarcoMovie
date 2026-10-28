package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.media.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.*;
import android.util.LruCache;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/** Independent first native build. No original APK code or artwork is embedded. */
public final class MainActivity extends Activity {
    static final int WHITE=0xfff5f5f7, MUTED=0xffa1a1aa, DARK=0xff101013;
    final Handler ui=new Handler(Looper.getMainLooper());
    final ExecutorService worker=Executors.newFixedThreadPool(3);
    final ExecutorService artwork=Executors.newFixedThreadPool(3);
    final ExecutorService searching=Executors.newFixedThreadPool(2);
    GlobalSearchScreen searchScreen; Dialog sourceDialog,accountDialog; MagnetStream magnetStream; volatile PhoneticSearchIndex phonetic;
    LocalProxy localProxy; WebResolver webResolver; PlaybackControls playbackControls; Cms.Line activeLine; Cms.Episode activeEpisode; int resumeAt;WatchHistory.Entry playingBookmark;long lastBookmarkSave;
    final ArrayDeque<Screen> back=new ArrayDeque<>();
    final LruCache<String,Bitmap> images=new LruCache<String,Bitmap>(10*1024*1024){protected int sizeOf(String k,Bitmap b){return b.getByteCount();}};
    FrameLayout root; LinearLayout body; ScrollView scroll; Screen current; Cms.Config config;
    android.content.SharedPreferences prefs; boolean reduced,prepared,playing,foreground; int generation;
    final Map<String,SourceEngine> engines=new HashMap<>();
    final Map<String,HomeScreen.Snapshot> homeData=new ConcurrentHashMap<>();
    AppDialog appDialog; FrameLayout playbackLayer; MiniDetails miniDetails;boolean miniMode;boolean changingMiniEpisode;FrameLayout playerOverlay; boolean controlsVisible=true;Runnable hideControls;
    PlayerChrome playerChrome; MoviePlayer player; String configOrigin=""; TextView playStatus,playClock;
    static final class Screen {Runnable render;String focus;int scroll;boolean player,home;HomeScreen.State homeState;Screen(Runnable r){render=r;}}
    interface Work<T>{T run()throws Exception;}
    interface Done<T>{void accept(T value)throws Exception;}

    @Override public void onCreate(Bundle b){super.onCreate(b);getWindow().getDecorView().setSystemUiVisibility(5894);prefs=getSharedPreferences("movie",MODE_PRIVATE);reduced=prefs.getBoolean("reduced",false);configOrigin=prefs.getString("origin","");
        try{File f=new File(getFilesDir(),"config.json");if(f.exists())try(InputStream i=new FileInputStream(f)){config=Cms.parseConfig(Cms.read(i,Cms.MAX_JSON),configOrigin);}}catch(Exception e){config=null;}
        worker.execute(()->{try{PhoneticSearchIndex index=new PhoneticSearchIndex(getAssets().open("search/pinyin-characters.tsv"),getAssets().open("search/pinyin-phrases.dict.yaml"));try{org.json.JSONArray old=new org.json.JSONArray(prefs.getString("phonetic_titles","[]"));for(int i=0;i<old.length();i++)index.learn(old.optString(i));org.json.JSONArray history=new org.json.JSONArray(prefs.getString("global_search_history","[]"));for(int i=history.length()-1;i>=0;i--)index.prefer(history.optString(i));}catch(Exception ignored){}phonetic=index;}catch(Exception ignored){}});
        open(new Screen(()->home()),false);
    }
    int dp(float x){return Math.round(x*getResources().getDisplayMetrics().density);}
    GradientDrawable bg(int color,float radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    TextView text(String s,int size,int color){TextView t=new TextView(this);t.setText(s);t.setTextColor(color);t.setTextSize(size);t.setFontFeatureSettings("kern");return t;}
    LinearLayout vertical(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.HORIZONTAL);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    void gap(LinearLayout p,int n){View v=new View(this);p.addView(v,new LinearLayout.LayoutParams(1,dp(n)));}
    void paragraph(String s){TextView t=text(s,16,MUTED);t.setLineSpacing(dp(5),1);body.addView(t);gap(body,14);}
    Button button(String label,String key,Runnable action){Button b=new Button(this);b.setText(label);b.setTextSize(15);b.setTextColor(WHITE);b.setAllCaps(false);b.setGravity(Gravity.CENTER);b.setIncludeFontPadding(false);b.setStateListAnimator(null);b.setMinHeight(dp(48));b.setMinimumHeight(dp(48));b.setPadding(dp(20),dp(9),dp(20),dp(9));b.setBackground(bg(0xff242429,12));b.setTag(key);b.setFocusable(true);b.setFocusableInTouchMode(true);b.setOnClickListener(v->action.run());pressFeedback(b);
        b.setOnFocusChangeListener((v,f)->{v.animate().cancel();b.setTextColor(f?DARK:WHITE);b.setBackground(bg(f?0xfff5f5f7:0xff242429,12));v.animate().scaleX(f&&!reduced?1.04f:1).scaleY(f&&!reduced?1.04f:1).setDuration(reduced?0:170).setInterpolator(new DecelerateInterpolator()).start();});return b;}
    void pressFeedback(View view){
        view.setOnTouchListener((v,event)->{if(event.getAction()==android.view.MotionEvent.ACTION_DOWN){v.requestFocus();v.setAlpha(.65f);}else if(event.getAction()==android.view.MotionEvent.ACTION_UP||event.getAction()==android.view.MotionEvent.ACTION_CANCEL)v.setAlpha(1f);return false;});
        view.setOnKeyListener((v,key,event)->{if(key==KeyEvent.KEYCODE_DPAD_CENTER||key==KeyEvent.KEYCODE_ENTER)v.setAlpha(event.getAction()==KeyEvent.ACTION_DOWN?.65f:1f);return false;});
    }
    Button navButton(String label,String key,Runnable action){Button b=button(label,key,action);b.setTextSize(14);b.setMinWidth(0);b.setMinimumWidth(0);b.setPadding(dp(14),dp(5),dp(14),dp(5));b.setMinHeight(dp(38));b.setMinimumHeight(dp(38));b.setBackground(bg(Color.TRANSPARENT,20));b.setTextColor(MUTED);b.setOnFocusChangeListener((v,f)->{b.setTextColor(f?DARK:MUTED);b.setBackground(bg(f?WHITE:Color.TRANSPARENT,20));});return b;}
    void chooseOrImport(){if(config==null)importDialog();else chooseSources();}
    void addButton(LinearLayout p,Button b){LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);lp.setMargins(dp(4),dp(5),dp(10),dp(8));p.addView(b,lp);}
    void renderPage(String title,String eyebrow){renderPage(title,eyebrow,false);}
    void renderPage(String title,String eyebrow,boolean navigation){if(current!=null)current.home=navigation;if(searchScreen!=null){searchScreen.close();searchScreen=null;}stopWeb();stopMagnet();releasePlayer();generation++;root=new FrameLayout(this);root.setBackgroundColor(DARK);root.addView(new Atmosphere(this),new FrameLayout.LayoutParams(-1,-1));scroll=new ScrollView(this);scroll.setClipToPadding(false);scroll.setFillViewport(true);body=vertical();body.setPadding(dp(46),dp(26),dp(46),dp(44));scroll.addView(body,new ScrollView.LayoutParams(-1,-2));root.addView(scroll,new FrameLayout.LayoutParams(-1,-1));setContentView(root);
        if(navigation){
        LinearLayout nav=row();ImageView brandMark=new ImageView(this);brandMark.setImageResource(R.drawable.logo_mark);LinearLayout.LayoutParams brandSize=new LinearLayout.LayoutParams(dp(38),dp(38));brandSize.setMargins(0,0,dp(9),0);nav.addView(brandMark,brandSize);TextView brand=text("MARCO MOVIE",15,WHITE);brand.setLetterSpacing(.10f);brand.setTypeface(null,Typeface.BOLD);nav.addView(brand,new LinearLayout.LayoutParams(0,-2,1));
        addButton(nav,navButton("首页","nav-home",()->open(new Screen(()->home()),true)));addButton(nav,navButton("搜索","nav-search",()->globalSearchDialog()));addButton(nav,navButton("直播","nav-live",()->open(new Screen(()->liveSources()),true)));addButton(nav,navButton("收藏","nav-favorites",()->open(new Screen(()->new FavoritesScreen(this).show()),true)));addButton(nav,navButton("网盘","nav-accounts",()->AccountPanel.show(this,root.findViewWithTag("nav-accounts"))));addButton(nav,navButton("设置","nav-settings",()->open(new Screen(()->settings()),true)));body.addView(nav);gap(body,title.isEmpty()?10:22);
        }
        if(!title.isEmpty()){TextView eye=text(eyebrow,12,0xffa9c9f3);eye.setLetterSpacing(.15f);body.addView(eye);gap(body,10);TextView heading=text(title,36,WHITE);heading.setTypeface(null,Typeface.BOLD);body.addView(heading);gap(body,16);}
        if(!reduced){body.setAlpha(0);body.animate().alpha(1).setDuration(180).setInterpolator(new DecelerateInterpolator()).start();}
    }
    boolean available(Cms.Site s){return s.supported()||(prefs.getBoolean("experimental_csp",false)&&(CspEngine.eligible(s)||JsEngine.eligible(s))&&config!=null&&!config.spider.isEmpty());}
    int engineEpoch;
    SourceEngine engine(Cms.Site s)throws Exception {
        final Cms.Config snapshot;final int epoch;
        synchronized(this){SourceEngine existing=engines.get(s.key);if(existing!=null)return existing;snapshot=config;epoch=engineEpoch;}
        SourceEngine created;
        if(s.supported())created=new JsonCmsEngine(s);
        else if(prefs.getBoolean("experimental_csp",false)&&CspEngine.eligible(s)&&snapshot!=null){ensureProxy(snapshot);created=new CspEngine(getApplication(),snapshot,s);}
        else if(prefs.getBoolean("experimental_csp",false)&&JsEngine.eligible(s)&&snapshot!=null){ensureProxy(snapshot);created=new JsEngine(getApplication(),snapshot,s);}
        else throw new IOException("来源需要尚未启用的扩展引擎");
        SourceEngine selected;boolean stale;
        synchronized(this){stale=epoch!=engineEpoch;selected=engines.get(s.key);if(!stale&&selected==null){engines.put(s.key,created);return created;}}
        created.close();
        if(stale)throw new IOException("配置已更改，请重新选择来源");return selected;
    }
    synchronized void ensureProxy(Cms.Config snapshot)throws IOException{if(localProxy==null)localProxy=new LocalProxy(getApplication(),snapshot);}
    void closeEngines(){homeData.clear();if(localProxy!=null){localProxy.close();localProxy=null;}final List<SourceEngine> old;synchronized(this){engineEpoch++;old=new ArrayList<>(engines.values());engines.clear();}if(!old.isEmpty())new Thread(()->{for(SourceEngine e:old)e.close();},"close-source-engines").start();}
    void open(Screen s,boolean history){capture();if(history&&current!=null)back.push(current);current=s;s.render.run();restore(s);}
    void capture(){if(current!=null){View f=getCurrentFocus();if(f!=null&&f.getTag() instanceof String)current.focus=(String)f.getTag();if(scroll!=null)current.scroll=scroll.getScrollY();}}
    void restore(Screen s){ui.post(()->{if(current!=s)return;if(scroll!=null)scroll.scrollTo(0,s.scroll);View target=s.focus==null?null:root.findViewWithTag(s.focus);if(target!=null)target.requestFocus();else {View first=root.findViewWithTag("primary");if(first==null)first=root.findViewWithTag("nav-home");if(first==null){ArrayList<View> available=new ArrayList<>();body.addFocusables(available,View.FOCUS_FORWARD);if(!available.isEmpty())first=available.get(0);}if(first!=null)first.requestFocus();}});}
    void refresh(){capture();Screen s=current;s.render.run();restore(s);}
    @Override public void onBackPressed(){
        if(current!=null&&current.player){if(!miniMode&&playbackControls!=null){minimizePlayback();return;}if(miniMode){releasePlayer();if(!back.isEmpty())back.pop();if(!back.isEmpty()){current=back.pop();current.render.run();restore(current);}else{current=new Screen(this::home);current.render.run();}return;}}
        if(current!=null&&current.home){releasePlayer();finish();return;}
        if(!back.isEmpty()){capture();current=back.pop();current.render.run();restore(current);}else{releasePlayer();finish();}
    }
    void minimizePlayback(){if(playbackControls==null||miniMode)return;miniMode=true;showControls(false);playbackControls.subtitle.setVisibility(View.GONE);playbackControls.danmaku.setVisibility(View.GONE);miniDetails=new MiniDetails(this);}
    void expandPlayback(){if(!miniMode)return;miniMode=false;if(miniDetails!=null){miniDetails.remove();miniDetails=null;}playbackLayer.setClipToOutline(false);playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1,-1));playbackControls.subtitle.setVisibility(View.VISIBLE);playbackControls.danmaku.setVisibility(View.VISIBLE);playbackLayer.post(()->{if(playbackControls!=null){playbackControls.resize(playbackControls.videoWidth,playbackControls.videoHeight);showControls(true);playbackControls.timeline.requestFocus();}});}
    void toast(String message){final FrameLayout parent=root;if(parent==null)return;TextView tip=text(message,14,WHITE);tip.setGravity(Gravity.CENTER);tip.setPadding(dp(22),dp(12),dp(22),dp(12));tip.setBackground(bg(0xf535353c,22));tip.setTag("app-toast");FrameLayout.LayoutParams size=new FrameLayout.LayoutParams(-2,-2,Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);size.bottomMargin=dp(24);parent.addView(tip,size);ui.postDelayed(()->parent.removeView(tip),2600);}
    <T>void load(String label,Work<T> task,Done<T> done){final int ticket=generation;TextView loading=text(label,17,MUTED);body.addView(loading);worker.execute(()->{try{T value=task.run();ui.post(()->{if(isFinishing()||ticket!=generation)return;body.removeView(loading);try{done.accept(value);}catch(Exception e){notice("数据格式不符合此版本支持的格式。");}});}catch(Exception e){ui.post(()->{if(isFinishing()||ticket!=generation)return;body.removeView(loading);paragraph(message(e));addButton(body,button("重试","primary",()->refresh()));});}});}
    String message(Exception e){String s=e.getMessage();if(e instanceof CspEngine.EngineException)return s;if(s!=null&&(s.startsWith("配置")||s.startsWith("来源返回 HTTP")||s.startsWith("来源没有")||s.startsWith("来源重定向")||s.startsWith("单页超过")||s.startsWith("响应超过")||s.startsWith("剧集返回")||s.startsWith("媒体地址返回")||s.startsWith("此剧集")))return s;return "连接超时、来源不可达或数据格式不受支持。请检查配置与网络后重试。";}
    void notice(String s){new AppDialog.Builder(this).setMessage(s).setPositiveButton("知道了",null).show();}
    void learnTitles(List<Cms.Video> videos){PhoneticSearchIndex index=phonetic;if(index==null)return;LinkedHashSet<String> values=new LinkedHashSet<>();try{org.json.JSONArray previous=new org.json.JSONArray(prefs.getString("phonetic_titles","[]"));for(int i=0;i<previous.length();i++)values.add(previous.optString(i));}catch(Exception ignored){}for(Cms.Video video:videos){index.learn(video.title);values.add(video.title);}while(values.size()>400)values.remove(values.iterator().next());prefs.edit().putString("phonetic_titles",new org.json.JSONArray(values).toString()).apply();}
    void sourceAction(Cms.Site site,String action){
        final int ticket=generation;worker.execute(()->{try{String response=engine(site).action(action);ui.post(()->{if(ticket!=generation||isFinishing()||response==null||response.trim().isEmpty())return;try{org.json.JSONObject result=new org.json.JSONObject(response);if(result.has("list")){Cms.Listing list=Cms.listing(response);new AppDialog.Builder(this).setTitle(site.name).setItems(list.videos.stream().map(v->v.title).toArray(String[]::new),(dialog,index)->detail(site,list.videos.get(index))).setNegativeButton("关闭",null).show();}else notice(result.optString("msg",result.optString("message",response)));}catch(Exception ignored){notice(response);}});}catch(Exception error){ui.post(()->{if(ticket==generation)notice(message(error));});}});
    }
    void pickDanmaku(){try{Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType("*/*");startActivityForResult(intent,43);}catch(Exception error){notice("这台电视没有文件选择器。");}}
    void pickSubtitle(){try{Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType("*/*");startActivityForResult(intent,42);}catch(Exception error){notice("这台电视没有文件选择器，可安装文件管理器后再导入字幕。");}}

    void home(){if(current!=null)current.home=true;Cms.Site selected=null;if(config!=null)for(Cms.Site s:config.sites)if(s.key.equals(prefs.getString("selected_site",""))&&available(s))selected=s;if(selected!=null){contentHome(selected);return;}renderPage("把今晚，留给好故事。","YOUR OWN CINEMA",true);paragraph("属于你的电视播放器。导入自己合法获取的配置，用遥控器浏览和播放。");
        LinearLayout hero=row();addButton(hero,button(config==null?"＋ 导入我的配置":"＋ 更新配置","primary",()->importDialog()));if(config!=null)addButton(hero,button("浏览片库","primary",()->chooseSources()));addButton(hero,navButton("观看历史","history-open",()->open(new Screen(this::historyPage),true)));body.addView(hero);gap(body,30);
        if(config==null){paragraph("本产品仅为播放工具，不内置、不提供、不托管任何影视资源或配置地址。请自行合法获取内容与配置，并确保拥有相应使用权。");return;}
        TextView t=text("我的来源",22,WHITE);body.addView(t);gap(body,10);int supported=0;for(Cms.Site s:config.sites)if(available(s))supported++;
        paragraph("已保存 "+config.sites.size()+" 个来源。选择一个，开始浏览。还未支持的来源会保留在列表中。");
    }
    void contentHome(Cms.Site site){new HomeScreen(this,site).show();}
    void chooseSources(){SourcePicker.show(this);}
    void importDialog(){AddressInput input=new AddressInput(this,"https://…/config.json",prefs.getString("origin",""));AppDialog d=new AppDialog.Builder(this).setTitle("导入配置").setView(input).setNegativeButton("取消",null).setNeutralButton("选择本地文件",(x,y)->pickConfig()).setPositiveButton("导入地址",null).create();d.setOnShowListener(x->d.getButton(-1).setOnClickListener(view->{String address=input.value();if(!Cms.isHttp(address)){input.invalid("请输入 HTTP(S) 配置地址");return;}d.dismiss();open(new Screen(()->{renderPage("正在导入","IMPORT CONFIGURATION");load("连接配置并读取来源…",()->{String raw=Cms.fetch(address,null);return Cms.parseConfig(raw,address);},c->saveConfig(c,address));}),true);}));d.show();}
    void pickConfig(){try{Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.setType("*/*");i.addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(i,41);}catch(Exception e){notice("这台电视没有系统文件选择器。请安装文件管理器，或使用配置地址导入。");}}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request>=44&&request<=46){if(result==RESULT_OK&&data!=null&&data.getData()!=null)SettingsScreen.result(this,request,data.getData());return;}if(request==43&&result==RESULT_OK&&data!=null&&data.getData()!=null){final PlaybackControls controls=playbackControls;if(controls!=null){Uri file=data.getData();worker.execute(()->{try(InputStream in=getContentResolver().openInputStream(file)){String text=Cms.read(in,8*1024*1024);ui.post(()->{if(controls==playbackControls){controls.danmaku.enabled(true);controls.danmaku.loadText(text,new DanmakuView.Listener(){public void loaded(int count){toast("已加载 "+count+" 条弹幕");}public void error(String message){notice(message);}});}});}catch(Exception error){ui.post(()->notice("弹幕文件无法读取。"));}});}return;}if(request==42&&result==RESULT_OK&&data!=null&&data.getData()!=null){Uri subtitle=data.getData();if(player!=null&&prepared){String name="外挂字幕";try(android.database.Cursor cursor=getContentResolver().query(subtitle,new String[]{android.provider.OpenableColumns.DISPLAY_NAME},null,null,null)){if(cursor!=null&&cursor.moveToFirst())name=cursor.getString(0);}catch(Exception ignored){}try{player.addExternalSubtitle(subtitle,name,MediaOptions.subtitleMime(name,""));toast("已导入字幕");}catch(Exception error){notice("字幕无法读取，请选择 SRT、VTT、ASS 或 TTML 文件。");}}return;}if(request==41&&result==RESULT_OK&&data!=null&&data.getData()!=null){Uri uri=data.getData();open(new Screen(()->{renderPage("正在读取文件","IMPORT CONFIGURATION");load("读取本地配置…",()->{try(InputStream i=getContentResolver().openInputStream(uri)){return Cms.parseConfig(Cms.read(i,Cms.MAX_JSON),null);}},c->saveConfig(c,""));}),true);}}
    void saveConfig(Cms.Config c,String origin)throws Exception {File temp=new File(getFilesDir(),"config.tmp");try(OutputStream o=new FileOutputStream(temp)){o.write(c.raw.getBytes("UTF-8"));}File dest=new File(getFilesDir(),"config.json");if(!temp.renameTo(dest)){try(OutputStream o=new FileOutputStream(dest)){o.write(c.raw.getBytes("UTF-8"));}temp.delete();}closeEngines();config=c;configOrigin=origin;prefs.edit().putString("origin",origin).apply();back.clear();current=new Screen(()->home());current.render.run();restore(current);toast("已导入 "+c.sites.size()+" 个来源");}

    void categories(Cms.Site s){prefs.edit().putString("selected_site",s.key).apply();renderPage(s.name,"CHOOSE A CATEGORY");LinearLayout actions=row();addButton(actions,button("全局搜索","search",()->globalSearchDialog()));addButton(actions,button("最新内容","latest",()->open(new Screen(()->videos(s,"","最新内容",1,null)),true)));body.addView(actions);load("正在读取分类…",()->Cms.categories(engine(s).home()),cats->{if(cats.isEmpty()){paragraph("来源没有返回分类，可尝试“最新内容”或搜索。");return;}for(Cms.Category c:cats)addButton(body,button(c.name,"category:"+c.id,()->open(new Screen(()->videos(s,c.id,c.name,1,null)),true)));});}
    void searchDialog(Cms.Site s){globalSearchDialog();}
    void videos(Cms.Site s,String cat,String title,int page,String search){renderPage(title,"EXPLORE THE LIBRARY");paragraph(s.name+" · 第 "+page+" 页");load("正在读取影片…",()->{SourceEngine selected=engine(s);return Cms.listing(search!=null?selected.search(search,page):selected.category(cat,page));},list->{if(list.videos.isEmpty())paragraph("这一页没有影片。");LinearLayout cards=null;for(int i=0;i<list.videos.size();i++){if(i%4==0){cards=row();cards.setGravity(Gravity.TOP);cards.setClipChildren(false);cards.setClipToPadding(false);body.addView(cards);}Cms.Video v=list.videos.get(i);LinearLayout card=vertical();card.setPadding(dp(5),dp(5),dp(5),dp(10));card.setClipChildren(false);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,-2,1);lp.setMargins(dp(5),dp(5),dp(14),dp(19));cards.addView(card,lp);FrameLayout art=new FrameLayout(this);art.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{0xff304c70,0xff141c2c}));ImageView img=new ImageView(this);img.setScaleType(ImageView.ScaleType.CENTER_CROP);art.addView(img,new FrameLayout.LayoutParams(-1,-1));card.addView(art,new LinearLayout.LayoutParams(-1,dp(185)));poster(v.poster,img);TextView label=text(v.title,16,WHITE);label.setPadding(dp(5),dp(10),dp(5),0);label.setLines(2);label.setEllipsize(android.text.TextUtils.TruncateAt.END);card.addView(label);TextView remark=text(v.remarks,12,MUTED);remark.setMaxLines(1);remark.setEllipsize(android.text.TextUtils.TruncateAt.END);card.addView(remark);card.setFocusable(true);card.setFocusableInTouchMode(true);card.setClickable(true);card.setTag(i==0?"primary":"video:"+v.id);card.setOnClickListener(view->open(new Screen(()->detail(s,v)),true));card.setOnFocusChangeListener((view,focus)->{view.animate().cancel();card.setBackground(bg(focus?0xff435c7c:0x00101c30,10));view.animate().scaleX(focus&&!reduced?1.04f:1).scaleY(focus&&!reduced?1.04f:1).setDuration(reduced?0:170).setInterpolator(new DecelerateInterpolator()).start();});}
            if(cards!=null){int remainder=list.videos.size()%4;if(remainder>0)for(int i=remainder;i<4;i++){LinearLayout.LayoutParams blank=new LinearLayout.LayoutParams(0,1,1);blank.setMargins(dp(5),dp(5),dp(14),dp(19));cards.addView(new View(this),blank);}}LinearLayout paging=row();if(page>1)addButton(paging,button("上一页","previous",()->open(new Screen(()->videos(s,cat,title,page-1,search)),true)));if(page<list.pageCount)addButton(paging,button("下一页","next",()->open(new Screen(()->videos(s,cat,title,page+1,search)),true)));body.addView(paging);restore(current);});}
    void poster(String address,ImageView image){image.setTag(address);if(!Cms.isHttp(address))return;Bitmap cached=images.get(address);if(cached!=null){image.setImageBitmap(cached);return;}final int ticket=generation;artwork.execute(()->{if(ticket!=generation)return;HttpURLConnection c=null;try{c=(HttpURLConnection)new URL(Cms.normalizeHttp(Cms.imageRequest(address).url)).openConnection();for(Map.Entry<String,String> header:Cms.imageRequest(address).headers.entrySet())c.setRequestProperty(header.getKey(),header.getValue());c.setConnectTimeout(7000);c.setReadTimeout(8000);if(!Cms.imageRequest(address).headers.containsKey("User-Agent"))c.setRequestProperty("User-Agent",Cms.USER_AGENT);byte[]bytes;try(InputStream in=c.getInputStream()){ByteArrayOutputStream out=new ByteArrayOutputStream();byte[]buf=new byte[8192];int n;while((n=in.read(buf))!=-1){if(out.size()+n>3*1024*1024)throw new IOException();out.write(buf,0,n);}bytes=out.toByteArray();}BitmapFactory.Options opts=new BitmapFactory.Options();opts.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(bytes,0,bytes.length,opts);if(opts.outWidth<=0||opts.outHeight<=0)return;opts.inSampleSize=1;while(opts.outWidth/opts.inSampleSize>480||opts.outHeight/opts.inSampleSize>720)opts.inSampleSize*=2;opts.inJustDecodeBounds=false;Bitmap bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.length,opts);if(bitmap!=null){images.put(address,bitmap);ui.post(()->{if(ticket==generation&&!isFinishing()&&address.equals(image.getTag()))image.setImageBitmap(bitmap);});}}catch(Exception ignored){}finally{if(c!=null)c.disconnect();}});}
    void detail(Cms.Site s,Cms.Video listing){
        if("folder".equalsIgnoreCase(listing.tag)){open(new Screen(()->videos(s,listing.id,listing.title,1,null)),true);return;}
        if(listing.action!=null&&!listing.action.isEmpty()){sourceAction(s,listing.action);return;}
        if(listing.id.startsWith("msearch:")){crossSearch(Cms.searchTitle(listing));return;}
        renderPage("","",false);
        addButton(body,navButton("‹ 返回","detail-back",this::onBackPressed));gap(body,12);
        LinearLayout hero=row();hero.setTag("detail-hero");hero.setGravity(Gravity.TOP);body.addView(hero);
        FrameLayout cover=new FrameLayout(this);cover.setTag("detail-cover");cover.setBackground(bg(0xff29292e,20));cover.setClipToOutline(true);
        TextView placeholder=text("暂无封面",14,MUTED);placeholder.setGravity(Gravity.CENTER);cover.addView(placeholder,new FrameLayout.LayoutParams(-1,-1));
        ImageView art=new ImageView(this);art.setScaleType(ImageView.ScaleType.CENTER_CROP);cover.addView(art,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout.LayoutParams coverSize=new LinearLayout.LayoutParams(dp(188),dp(282));coverSize.setMargins(0,0,dp(32),dp(22));hero.addView(cover,coverSize);poster(listing.poster,art);
        LinearLayout info=vertical();hero.addView(info,new LinearLayout.LayoutParams(0,-2,1));
        TextView title=text(listing.title,32,WHITE);title.setTypeface(null,Typeface.BOLD);title.setMaxLines(2);title.setEllipsize(android.text.TextUtils.TruncateAt.END);info.addView(title);gap(info,14);
        TextView state=text("正在读取详情与剧集…",14,MUTED);info.addView(state);
        load("",()->{Cms.Listing l=Cms.listing(engine(s).detail(listing.id));if(l.videos.isEmpty())throw new IOException("来源没有返回影片详情");return l.videos.get(0);},v->{
            if(v.poster==null||v.poster.isEmpty())v.poster=listing.poster;
            if(v.title==null||v.title.isEmpty())v.title=listing.title;
            title.setText(v.title);poster(v.poster,art);info.removeView(state);
            TextView meta=text((v.year+"   "+v.area+"   "+v.remarks).trim(),14,MUTED);meta.setMaxLines(2);info.addView(meta);gap(info,12);
            if(!v.description.isEmpty()){TextView synopsis=text(v.description,15,0xffceced3);synopsis.setLineSpacing(dp(4),1);synopsis.setMaxLines(4);synopsis.setEllipsize(android.text.TextUtils.TruncateAt.END);info.addView(synopsis);addButton(info,navButton("展开简介","synopsis",()->new AppDialog.Builder(this).setTitle(v.title).setMessage(v.description).setPositiveButton("关闭",null).show()));}
            if(!v.actor.isEmpty()){TextView actor=text("演员  "+v.actor,13,MUTED);actor.setMaxLines(2);actor.setEllipsize(android.text.TextUtils.TruncateAt.END);info.addView(actor);gap(info,8);}
            Button favorite=button(Favorites.contains(prefs.getString("favorites","[]"),s.key,v.id)?"已收藏":"加入收藏","detail-favorite",()->{});
            favorite.setOnClickListener(view->{prefs.edit().putString("favorites",Favorites.toggle(prefs.getString("favorites","[]"),s.key,v)).apply();favorite.setText(Favorites.contains(prefs.getString("favorites","[]"),s.key,v.id)?"已收藏":"加入收藏");});addButton(info,favorite);
            if(v.lines.isEmpty()){paragraph("这部影片没有返回可识别的播放线路。");favorite.requestFocus();return;}
            LinearLayout episodePanel=vertical();body.addView(episodePanel);renderEpisodes(s,v,0,0,episodePanel);
            View saved=current!=null&&current.focus!=null?root.findViewWithTag(current.focus):null;View first=episodePanel.findViewWithTag("episode:"+v.lines.get(0).name+":0");if(saved!=null)saved.requestFocus();else if(first!=null)first.requestFocus();else favorite.requestFocus();
        });
    }
    void renderEpisodes(Cms.Site site,Cms.Video video,int lineIndex,int page,LinearLayout panel){
        panel.removeAllViews();Cms.Line line=video.lines.get(lineIndex);LinearLayout toolbar=row();TextView info=text(line.name+" · "+line.episodes.size()+" 集",20,WHITE);toolbar.addView(info,new LinearLayout.LayoutParams(0,-2,1));
        if(video.lines.size()>1)addButton(toolbar,navButton("选择线路  ⌄","detail-lines",()->{String[] labels=new String[video.lines.size()];for(int n=0;n<labels.length;n++)labels[n]=video.lines.get(n).name;new AppDialog.Builder(this).setTitle("选择线路").setSingleChoiceItems(labels,lineIndex,(dialog,n)->{dialog.dismiss();renderEpisodes(site,video,n,0,panel);View first=panel.findViewWithTag("episode:"+video.lines.get(n).name+":0");if(first!=null)first.requestFocus();}).setNegativeButton("取消",null).show();}));panel.addView(toolbar);
        int start=page*50,end=Math.min(start+50,line.episodes.size());LinearLayout episodes=null;
        for(int i=start;i<end;i++){if((i-start)%5==0){episodes=row();panel.addView(episodes);}Cms.Episode ep=line.episodes.get(i);Button episode=button(ep.name,"episode:"+line.name+":"+i,()->{resumeAt=0;resolvePlayer(site,video,line,ep);});episode.setSingleLine(true);episode.setEllipsize(android.text.TextUtils.TruncateAt.END);episode.setPadding(dp(8),dp(9),dp(8),dp(9));LinearLayout.LayoutParams cell=new LinearLayout.LayoutParams(0,dp(52),1);cell.setMargins(dp(3),dp(4),dp(5),dp(6));episodes.addView(episode,cell);}
        if(episodes!=null)for(int n=(end-start)%5;n>0&&n<5;n++)episodes.addView(new View(this),new LinearLayout.LayoutParams(0,1,1));
        if(line.episodes.size()>50){LinearLayout pages=row();if(page>0)addButton(pages,navButton("上一组","episodes-previous",()->renderEpisodes(site,video,lineIndex,page-1,panel)));if(end<line.episodes.size())addButton(pages,navButton("下一组","episodes-next",()->{renderEpisodes(site,video,lineIndex,page+1,panel);View first=panel.findViewWithTag("episode:"+line.name+":"+end);if(first!=null)first.requestFocus();}));addButton(pages,navButton("全部选集","episodes-all",()->{String[] labels=new String[line.episodes.size()];for(int n=0;n<labels.length;n++)labels[n]=line.episodes.get(n).name;new AppDialog.Builder(this).setTitle(line.name).setItems(labels,(dialog,n)->resolvePlayer(site,video,line,line.episodes.get(n))).setNegativeButton("取消",null).show();}));panel.addView(pages);}
    }

    void liveSources(){renderPage("直播","LIVE TV");if(config==null){paragraph("先导入包含直播列表的配置。");return;}try{List<LiveCatalog.Source> sources=LiveCatalog.sources(config.raw,configOrigin);for(LiveCatalog.Source source:sources)addButton(body,button(source.name,"live-source:"+source.name,()->open(new Screen(()->liveGroups(source)),true)));if(sources.isEmpty())paragraph("当前配置没有直播列表。");}catch(Exception e){paragraph("无法读取直播配置。");}}
    void liveGroups(LiveCatalog.Source source){renderPage(source.name,"LIVE CHANNELS");load("读取频道分组…",()->{if(source.isLocalProxy()){if(!prefs.getBoolean("experimental_csp",false))throw new IOException("请先启用来源扩展");ensureProxy(config);source.url=LocalProxy.rewrite(source.url);}return LiveCatalog.load(source);},catalog->{paragraph(catalog.channelCount()+" 个频道 · 选择分组");for(LiveCatalog.Group group:catalog.groups)addButton(body,button(group.name+"  ·  "+group.channels.size(),"group:"+group.name,()->open(new Screen(()->liveChannels(source,group,0)),true)));});}
    void liveChannels(LiveCatalog.Source source,LiveCatalog.Group group,int page){renderPage(group.name,"LIVE CHANNELS");int start=page*30,end=Math.min(group.channels.size(),start+30);for(int i=start;i<end;i++){LiveCatalog.Channel channel=group.channels.get(i);addButton(body,button(channel.name,"channel:"+i,()->{if(channel.streams.size()==1)playLive(source,channel,channel.streams.get(0));else{String[] names=new String[channel.streams.size()];for(int n=0;n<names.length;n++)names[n]="线路 "+(n+1);new AppDialog.Builder(this).setTitle(channel.name).setItems(names,(dialog,n)->playLive(source,channel,channel.streams.get(n))).show();}}));}LinearLayout pages=row();if(page>0)addButton(pages,button("上一页","previous",()->open(new Screen(()->liveChannels(source,group,page-1)),true)));if(end<group.channels.size())addButton(pages,button("下一页","next",()->open(new Screen(()->liveChannels(source,group,page+1)),true)));body.addView(pages);}
    void playLive(LiveCatalog.Source source,LiveCatalog.Channel channel,LiveCatalog.Stream stream){activeLine=null;activeEpisode=null;resumeAt=0;Cms.Site site=new Cms.Site();site.key="live";site.name=source.name;site.api=stream.url;site.type=1;site.playUrl="";site.headers.putAll(stream.headers);Cms.Video video=new Cms.Video();video.title=channel.name;Cms.Episode ep=new Cms.Episode();ep.name="直播";ep.url=stream.url;ep.headers.putAll(stream.headers);openPlayer(site,video,ep);}
    void globalSearchDialog(){openSearch("");}
    void openSearch(String initial){if(config==null){importDialog();return;}GlobalSearchScreen screen=new GlobalSearchScreen(this,initial);open(new Screen(()->{screen.show();searchScreen=screen;}),true);}
    void crossSearch(String keyword){openSearch(keyword);}
    void stopMagnet(){if(magnetStream!=null){magnetStream.close();magnetStream=null;}}
    void stopWeb(){if(webResolver!=null){webResolver.stop();webResolver=null;}}
    void resolveWebPage(Cms.Site s,Cms.Video v,Cms.Episode ep,String prefix){
        String address=(prefix==null?"":prefix)+ep.url;if(!Cms.isHttp(address)){paragraph("解析页面地址不受支持。");return;}final int ticket=generation;TextView state=text("正在读取来源播放页面…",16,MUTED);body.addView(state);
        try{webResolver=new WebResolver(this,address,ep.headers,new WebResolver.Listener(){public void media(String url,Map<String,String> headers){if(ticket!=generation)return;webResolver=null;Cms.Episode resolved=new Cms.Episode();resolved.name=ep.name;resolved.url=url;resolved.headers.putAll(headers);resolved.media=ep.media;if(!back.isEmpty())current=back.pop();openPlayer(s,v,resolved);}public void failed(String reason){if(ticket==generation)state.setText(reason);}});body.addView(webResolver.view(),new LinearLayout.LayoutParams(-1,dp(280)));}catch(Exception error){state.setText("这台电视无法打开网页播放组件。");}
    }
    void resolvePlayer(Cms.Site s,Cms.Video v,Cms.Line line,Cms.Episode ep){
        if(miniMode){changingMiniEpisode=true;releasePlayer();if(!back.isEmpty())current=back.pop();}
        activeLine=line;activeEpisode=ep;
        if(s.supported()){openPlayer(s,v,ep);return;}
        open(new Screen(()->{renderPage("正在准备播放","RESOLVE EPISODE");load("请求来源播放信息…",()->new org.json.JSONObject(engine(s).player(line.name,ep.url)),result->{
            String url=result.optString("url");Cms.Episode resolved=MediaOptions.episode(s,ep,result);
            if(result.optInt("parse",0)!=0||result.optInt("jx",0)!=0){resolveWebPage(s,v,resolved,result.optString("playUrl",s.playUrl));return;}
            if(!Cms.isMedia(url)&&!url.startsWith("magnet:?")){paragraph("来源返回的播放协议尚未支持："+(url.contains(":")?url.substring(0,url.indexOf(':')):"未知"));return;}
            current=back.pop();openPlayer(s,v,resolved);
        });}),true);
    }
    void openPlayer(Cms.Site s,Cms.Video v,Cms.Episode e){if(e.url.startsWith("magnet:?")){magnetPlayer(s,v,e);return;}if(!Cms.isMedia(e.url)){notice("这条剧集需要解析或使用了特殊协议，基础版尚未支持。");return;}Screen screen=new Screen(()->playerPage(s,v,e));screen.player=true;open(screen,true);}
    void magnetPlayer(Cms.Site site,Cms.Video video,Cms.Episode episode){
        open(new Screen(()->{renderPage(video.title,"MAGNET PLAYBACK");TextView state=text("正在获取磁力文件列表…",17,MUTED);body.addView(state);final int ticket=generation;
            try{magnetStream=MagnetStream.start(this,episode.url,new MagnetStream.Listener(){
                public void progress(String message){if(ticket==generation)state.setText(message);}
                public void files(List<MagnetStream.MediaFile> files,int suggested,MagnetStream.Selection selection){if(ticket!=generation)return;String[] names=new String[files.size()];for(int i=0;i<names.length;i++)names[i]=files.get(i).name;new AppDialog.Builder(MainActivity.this).setTitle("选择要播放的视频").setSingleChoiceItems(names,suggested,(dialog,index)->{dialog.dismiss();selection.select(index);}).setNegativeButton("取消",(dialog,index)->onBackPressed()).setOnCancelListener(dialog->onBackPressed()).show();}
                public void ready(String url,String mime,String name){if(ticket!=generation)return;Cms.Episode resolved=new Cms.Episode();resolved.name=name;resolved.url=url;resolved.headers.putAll(episode.headers);try{resolved.media=new org.json.JSONObject(episode.media.toString()).put("mimeType",mime);}catch(Exception ignored){}if(!back.isEmpty())current=back.pop();openPlayer(site,video,resolved);}
                public void error(String message){if(ticket==generation){state.setText(message);addButton(body,button("重试","primary",()->refresh()));}}
            });}catch(Exception error){state.setText("磁力播放初始化失败："+error.getClass().getSimpleName());}
        }),true);
    }
    void changeEpisode(Cms.Site site,Cms.Video video,Cms.Line line,Cms.Episode episode,int position){
        changingMiniEpisode=miniMode;resumeAt=position;releasePlayer();if(current!=null&&current.player&&!back.isEmpty())current=back.pop();resolvePlayer(site,video,line,episode);
    }
    void leavePlayback(){if(!back.isEmpty()){releasePlayer();current=back.pop();current.render.run();restore(current);}else onBackPressed();}
    void playerPage(Cms.Site s,Cms.Video v,Cms.Episode ep){ep.url=LocalProxy.rewrite(ep.url);try{org.json.JSONArray subtitles=ep.media.optJSONArray("subtitles");if(subtitles!=null)for(int i=0;i<subtitles.length();i++){org.json.JSONObject sub=subtitles.optJSONObject(i);if(sub!=null)sub.put("url",LocalProxy.rewrite(sub.optString("url")));}}catch(Exception ignored){}
        releasePlayer();playingBookmark=null;if(s.key!=null&&!s.key.equals("live")&&v.id!=null&&activeLine!=null&&activeEpisode!=null){playingBookmark=new WatchHistory.Entry();playingBookmark.site=s.key;playingBookmark.id=v.id;playingBookmark.title=v.title;playingBookmark.poster=v.poster;playingBookmark.line=activeLine.name;playingBookmark.episode=activeEpisode.name;playingBookmark.index=activeLine.episodes.indexOf(activeEpisode);}generation++;final int ticket=generation;getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root=new FrameLayout(this);root.setBackgroundColor(Color.BLACK);root.setFocusable(true);root.setFocusableInTouchMode(true);root.setTag("player-surface");scroll=null;TextureView surface=new TextureView(this);playbackLayer=new FrameLayout(this);playbackLayer.setTag("playback-layer");root.addView(playbackLayer,new FrameLayout.LayoutParams(-1,-1));playbackLayer.addView(surface,new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER));
        playerChrome=new PlayerChrome(this,v,ep);
        playbackControls=new PlaybackControls(this,playerChrome.dock,playerChrome.progress,surface,s,v,ep);final PlaybackControls controls=playbackControls;setContentView(root);
        surface.setSurfaceTextureListener(new TextureView.SurfaceTextureListener(){
            Surface renderSurface;
            public void onSurfaceTextureAvailable(SurfaceTexture texture,int width,int height){
                renderSurface=new Surface(texture);
                worker.execute(()->{MoviePlayer candidate=null;try{
                    Map<String,String> mediaHeaders=new LinkedHashMap<>(s.headers);mediaHeaders.putAll(ep.headers);candidate=prefs.getInt("player_engine",0)==1?new SystemPlayer(MainActivity.this):ep.media.optBoolean("_softwareFallback")?new MoviePlayer(MainActivity.this,ep.media.optInt("_fallbackMode",2)):new MoviePlayer(MainActivity.this);
                    candidate.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build());candidate.setDataSource(MainActivity.this,Uri.parse(Cms.isHttp(ep.url)?Cms.normalizeHttp(ep.url):ep.url),mediaHeaders);candidate.setOptions(ep.media);final MoviePlayer ready=candidate;
                    ui.post(()->{if(ticket!=generation||isFinishing()||renderSurface==null||!renderSurface.isValid()){ready.release();return;}player=ready;ready.setSurface(renderSurface);ready.setCuesListener(group->{if(ticket==generation){controls.subtitle.setCues(group.cues);controls.lastSubtitle=group.cues.isEmpty()?"":String.valueOf(group.cues.get(0).text);}});
                        ready.setOnPreparedListener(mp->{if(ticket!=generation)return;prepared=true;controls.prepared();playing=foreground;if(foreground)mp.start();else mp.pause();playStatus.setText(foreground?"正在播放 · 确认暂停 · 上下键显示工具条":"已暂停 · 按确认继续");clock(ticket);if(changingMiniEpisode){changingMiniEpisode=false;minimizePlayback();}else if(foreground)scheduleHide();});
                        ready.setOnVideoSizeChangedListener((mp,w,h)->{if(ticket==generation)controls.resize(w,h);});
                        ready.setOnCompletionListener(mp->{if(ticket!=generation)return;playing=false;playStatus.setText("播放结束");controls.completed();});
                        ready.setOnErrorListener((mp,what,extra)->{if(ticket!=generation)return true;if(PlaybackFailure.decoderFallback(what)&&prefs.getInt("decoder_mode",0)==0&&prefs.getInt("player_engine",0)==0&&!ep.media.optBoolean("_softwareFallback")){try{ep.media.put("_softwareFallback",true);ep.media.put("_fallbackMode",mp.softFallbackMode());}catch(Exception ignored){}resumeAt=mp.getCurrentPosition();playStatus.setText("正在尝试内置软解码…");ui.post(()->{if(ticket==generation)playerPage(s,v,ep);});return true;}prepared=false;playing=false;playStatus.setText(mp.getFailureMessage(what)+"（"+what+"）");showControls(true);return true;});
                        playStatus.setText("正在准备播放…");ready.prepareAsync();
                    });
                }catch(Exception ex){if(candidate!=null)candidate.release();ui.post(()->{if(ticket==generation)playStatus.setText(message(ex));});}});
            }
            public void onSurfaceTextureSizeChanged(SurfaceTexture t,int w,int h){}
            public boolean onSurfaceTextureDestroyed(SurfaceTexture t){if(ticket==generation)releasePlayer();if(renderSurface!=null){renderSurface.release();renderSurface=null;}return true;}
            public void onSurfaceTextureUpdated(SurfaceTexture t){}
        });playbackControls.timeline.requestFocus();
    }
    void showControls(boolean visible){if(miniMode&&visible)return;boolean changed=controlsVisible!=visible;controlsVisible=visible;if(playbackControls!=null)playbackControls.visible(visible);if(playerChrome!=null)playerChrome.update();
        if(playerOverlay!=null){playerOverlay.animate().cancel();if(visible){playerOverlay.setVisibility(View.VISIBLE);if(changed&&!reduced){playerOverlay.setAlpha(0);playerOverlay.setTranslationY(0);}playerOverlay.animate().alpha(1).translationY(0).setDuration(reduced?0:180).start();}else{playerOverlay.animate().alpha(0).translationY(0).setDuration(reduced?0:150).withEndAction(()->{if(!controlsVisible&&playerOverlay!=null)playerOverlay.setVisibility(View.GONE);}).start();root.requestFocus();}}
        if(visible){if(changed&&playbackControls!=null)playbackControls.timeline.requestFocus();scheduleHide();}else if(hideControls!=null)ui.removeCallbacks(hideControls);
    }
    void scheduleHide(){if(hideControls!=null)ui.removeCallbacks(hideControls);hideControls=()->{if(prepared&&playing&&(playbackControls==null||!playbackControls.dialogOpen))showControls(false);};ui.postDelayed(hideControls,5000);}
    void clock(int ticket){if(ticket!=generation||player==null||!prepared)return;savePlaybackHistory(false);try{playClock.setText(time(player.getCurrentPosition())+" / "+(player.getDuration()>0?time(player.getDuration()):"直播"));if(playbackControls!=null)playbackControls.tick();if(playerChrome!=null)playerChrome.update();}catch(Exception ignored){}ui.postDelayed(()->clock(ticket),1000);}
    String time(int ms){int sec=Math.max(0,ms/1000);return sec>=3600?String.format(Locale.ROOT,"%d:%02d:%02d",sec/3600,(sec/60)%60,sec%60):String.format(Locale.ROOT,"%02d:%02d",sec/60,sec%60);}
    void togglePlayback(){if(player==null||!prepared)return;try{if(player.isPlaying()){player.pause();playing=false;playStatus.setText("已暂停 · 按确认继续");}else{if(player.getDuration()>0&&player.getCurrentPosition()>=player.getDuration()-300)player.seekTo(0);player.start();playing=true;playStatus.setText("正在播放 · 确认暂停 · 上下键显示工具条");}if(playerChrome!=null)playerChrome.update();}catch(Exception ignored){}}
    void seek(int offset){if(player==null||!prepared)return;try{if(player.getDuration()>0)player.seekTo(Math.max(0,Math.min(player.getDuration(),player.getCurrentPosition()+offset)));}catch(Exception ignored){}}
    java.util.List<WatchHistory.Entry> watchHistory(){return WatchHistory.read(prefs.getString("watch_history","[]"));}
    void savePlaybackHistory(boolean force){
        if(player==null||!prepared||playingBookmark==null)return;long now=System.currentTimeMillis();if(!force&&now-lastBookmarkSave<5000)return;
        try{int position=player.getCurrentPosition();if(position<1000&&playingBookmark.position==0)return;playingBookmark.position=position;playingBookmark.duration=player.getDuration();playingBookmark.updated=now;prefs.edit().putString("watch_history",WatchHistory.upsert(prefs.getString("watch_history","[]"),playingBookmark)).apply();lastBookmarkSave=now;}catch(Exception ignored){}
    }
    String historyLabel(WatchHistory.Entry e){return e.episode+" · "+(e.complete()?"已看完":time(e.position)+(e.duration>0?" / "+time(e.duration):""));}
    void resumeHistory(WatchHistory.Entry e){
        Cms.Site site=null;if(config!=null)for(Cms.Site s:config.sites)if(s.key.equals(e.site))site=s;
        if(site==null||!available(site)){notice("这条记录的来源已不可用，记录仍保留在本机。");return;}final Cms.Site selected=site;
        open(new Screen(()->{renderPage("继续观看","");load("正在获取新的播放信息…",()->Cms.listing(engine(selected).detail(e.id)),listing->{
            if(listing.videos.isEmpty()){paragraph("这条记录的内容暂时不可用。");return;}Cms.Video video=listing.videos.get(0);Cms.Line line=null;for(Cms.Line candidate:video.lines)if(candidate.name.equals(e.line))line=candidate;
            if(line==null||line.episodes.isEmpty()){paragraph("原来的线路已变更，请重新选择线路和集数。");addButton(body,button("打开详情","history-detail",()->detail(selected,video)));return;}
            Cms.Episode episode=null;for(Cms.Episode candidate:line.episodes)if(candidate.name.equals(e.episode)){episode=candidate;break;}
            if(episode==null){paragraph("原来的集数已变更，请从详情重新选择。");addButton(body,button("打开详情","history-detail",()->detail(selected,video)));return;}
            resumeAt=e.resume();current=back.pop();resolvePlayer(selected,video,line,episode);
        });}),true);
    }
    void historyPage(){renderPage("观看历史","CONTINUE WATCHING");java.util.List<WatchHistory.Entry> entries=watchHistory();if(entries.isEmpty()){paragraph("播放后会在这里记录集数和进度。");return;}
        addButton(body,navButton("清空观看历史","history-clear",()->new AppDialog.Builder(this).setTitle("清空观看历史？").setMessage("只清除本机观看记录，保留配置和账号。").setNegativeButton("取消",null).setPositiveButton("清空",(d,n)->{prefs.edit().remove("watch_history").apply();refresh();}).show()));
        for(WatchHistory.Entry e:entries){LinearLayout line=row();Button item=button(e.title+" · "+historyLabel(e),"history:"+e.key(),()->resumeHistory(e));item.setSingleLine(true);item.setEllipsize(android.text.TextUtils.TruncateAt.END);line.addView(item,new LinearLayout.LayoutParams(0,dp(52),1));addButton(line,navButton("移除","history-remove:"+e.key(),()->{prefs.edit().putString("watch_history",WatchHistory.remove(prefs.getString("watch_history","[]"),e.key())).apply();refresh();}));body.addView(line);gap(body,8);}
    }
    void releasePlayer(){savePlaybackHistory(true);miniMode=false;miniDetails=null;if(playbackControls!=null)playbackControls.close();playbackControls=null;prepared=false;playing=false;if(player!=null){try{player.release();}catch(Exception ignored){}player=null;}getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);}
    @Override public boolean dispatchKeyEvent(KeyEvent event){
        if(current!=null&&current.player&&!miniMode&&(playbackControls==null||!playbackControls.dialogOpen)){
            int key=event.getKeyCode();boolean down=event.getAction()==KeyEvent.ACTION_DOWN;View focus=getCurrentFocus();
            boolean confirm=key==KeyEvent.KEYCODE_DPAD_CENTER||key==KeyEvent.KEYCODE_ENTER;
            if(confirm&&(!controlsVisible||focus==root||playbackControls!=null&&focus==playbackControls.timeline)){
                if(down&&event.getRepeatCount()==0){togglePlayback();showControls(true);}return true;
            }
            if(!controlsVisible&&(key==KeyEvent.KEYCODE_DPAD_UP||key==KeyEvent.KEYCODE_DPAD_DOWN||key==KeyEvent.KEYCODE_MENU)){
                if(down){showControls(true);if(playbackControls!=null)playbackControls.timeline.requestFocus();}return true;
            }
            if(!controlsVisible&&(key==KeyEvent.KEYCODE_DPAD_LEFT||key==KeyEvent.KEYCODE_DPAD_RIGHT)){
                if(down){seek(key==KeyEvent.KEYCODE_DPAD_LEFT?-10000:10000);showControls(true);}return true;
            }
            if(key==KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE||key==KeyEvent.KEYCODE_MEDIA_PLAY||key==KeyEvent.KEYCODE_MEDIA_PAUSE){if(down&&event.getRepeatCount()==0){if(key==KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE||(key==KeyEvent.KEYCODE_MEDIA_PLAY&&!playing)||(key==KeyEvent.KEYCODE_MEDIA_PAUSE&&playing))togglePlayback();showControls(true);}return true;}
            if(controlsVisible&&down)scheduleHide();
        }
        return super.dispatchKeyEvent(event);
    }
    @Override protected void onStart(){super.onStart();foreground=true;}
    @Override protected void onStop(){savePlaybackHistory(true);foreground=false;super.onStop();if(player!=null)try{player.pause();playing=false;if(playStatus!=null)playStatus.setText("已暂停 · 按确认继续");}catch(Exception ignored){}}
    @Override protected void onDestroy(){if(searchScreen!=null)searchScreen.close();stopWeb();stopMagnet();generation++;releasePlayer();closeEngines();worker.shutdownNow();artwork.shutdownNow();searching.shutdownNow();ui.removeCallbacksAndMessages(null);images.evictAll();super.onDestroy();}

    void settings(){new SettingsScreen(this).show();}

    final class Atmosphere extends View {final Paint paint=new Paint(3);Bitmap wallpaper;Atmosphere(Context c){super(c);if(prefs.getBoolean("wallpaper_enabled",false))wallpaper=BitmapFactory.decodeFile(new File(getFilesDir(),"wallpaper.jpg").getAbsolutePath());}protected void onDraw(Canvas canvas){canvas.drawColor(DARK);if(wallpaper!=null){float scale=Math.max((float)getWidth()/wallpaper.getWidth(),(float)getHeight()/wallpaper.getHeight());float w=wallpaper.getWidth()*scale,h=wallpaper.getHeight()*scale;canvas.drawBitmap(wallpaper,null,new RectF((getWidth()-w)/2,(getHeight()-h)/2,(getWidth()+w)/2,(getHeight()+h)/2),paint);canvas.drawColor(Color.argb(Math.round(255*Math.max(0,Math.min(100,prefs.getInt("wallpaper_dim",60)))/100f),0,0,0));}}protected void onDetachedFromWindow(){super.onDetachedFromWindow();if(wallpaper!=null){wallpaper.recycle();wallpaper=null;}}}
}
