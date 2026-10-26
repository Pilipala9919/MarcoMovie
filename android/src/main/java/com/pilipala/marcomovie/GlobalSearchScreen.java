package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.*;

/** Dedicated global search page with a local remote-control keyboard. */
public final class GlobalSearchScreen implements AutoCloseable {
    final MainActivity a;final String initial;
    PinyinKeyboardModel keyboard;TextView input,composition,status;LinearLayout candidates,keys,resultBody,sourceFilters;
    SearchCoordinator coordinator;boolean closed;int pageTicket,searchSerial,candidatePage,finished,failed,timedOut,busy,matched;
    String activeFilter="",submitted="",edited="";Runnable pendingSearch;
    final LinkedHashMap<String,SourceResult> results=new LinkedHashMap<>();
    final Map<String,LinearLayout> posterCards=new HashMap<>();
    final Map<PinyinKeyboardModel.Mode,Button> modeButtons=new LinkedHashMap<>();
    static final class SourceResult {final Cms.Site site;final List<Cms.Video> videos;final SearchCoordinator.Outcome outcome;SourceResult(Cms.Site site,List<Cms.Video> videos,SearchCoordinator.Outcome outcome){this.site=site;this.videos=videos;this.outcome=outcome;}}
    public GlobalSearchScreen(MainActivity activity,String initialKeyword){a=activity;initial=initialKeyword==null?"":initialKeyword;}
    public void show(){
        String restored=keyboard==null?initial:keyboard.query();boolean searchAgain=!submitted.isEmpty()||!initial.trim().isEmpty();
        a.renderPage("","");closed=false;pageTicket=a.generation;a.root.setBackgroundColor(0xff101013);if(a.root.getChildAt(0) instanceof MainActivity.Atmosphere)a.root.removeViewAt(0);
        a.body.setPadding(a.dp(32),a.dp(14),a.dp(32),a.dp(16));
        try{keyboard=new PinyinKeyboardModel(a.getAssets().open("search/pinyin-characters.tsv"));}catch(Exception missing){a.paragraph("内置拼音字库无法读取，请重新安装完整版本。");return;}
        keyboard.set(restored);
        LinearLayout split=a.row();split.setGravity(Gravity.TOP);int height=Math.max(350,Math.round(a.getResources().getDisplayMetrics().heightPixels/a.getResources().getDisplayMetrics().density)-100);a.body.addView(split,new LinearLayout.LayoutParams(-1,a.dp(height)));
        LinearLayout left=a.vertical();left.setPadding(0,0,a.dp(24),0);split.addView(left,new LinearLayout.LayoutParams(a.dp(282),-1));
        TextView heading=a.text("搜索所有片源",24,MainActivity.WHITE);heading.setTypeface(null,Typeface.BOLD);left.addView(heading);a.gap(left,12);
        input=a.text("",18,MainActivity.WHITE);input.setGravity(Gravity.CENTER_VERTICAL);input.setIncludeFontPadding(false);input.setTag("primary");input.setContentDescription("搜索内容");input.setSingleLine(true);input.setEllipsize(android.text.TextUtils.TruncateAt.START);input.setPadding(a.dp(14),a.dp(10),a.dp(12),a.dp(10));input.setBackground(a.bg(0xff29292e,10));input.setFocusable(true);input.setFocusableInTouchMode(true);input.setClickable(true);input.setOnClickListener(v->{View first=a.root.findViewWithTag("search-key:a");if(first!=null)first.requestFocus();});input.setOnKeyListener((v,key,event)->physicalKey(key,event));left.addView(input,new LinearLayout.LayoutParams(-1,a.dp(48)));
        composition=a.text("",12,MainActivity.MUTED);composition.setSingleLine(true);composition.setPadding(a.dp(2),a.dp(5),0,0);left.addView(composition,new LinearLayout.LayoutParams(-1,a.dp(25)));
        candidates=a.row();left.addView(candidates,new LinearLayout.LayoutParams(-1,a.dp(34)));
        LinearLayout modes=a.row();left.addView(modes,new LinearLayout.LayoutParams(-1,a.dp(38)));
        modeButton(modes,"拼音",PinyinKeyboardModel.Mode.PINYIN);modeButton(modes,"字母",PinyinKeyboardModel.Mode.LETTERS);modeButton(modes,"数字",PinyinKeyboardModel.Mode.NUMBERS);
        keys=a.vertical();left.addView(keys);a.gap(left,5);
        LinearLayout editing=a.row();left.addView(editing);keyButton(editing,"空格","search-space",()->{keyboard.space();changed();},1);keyButton(editing,"删除","search-delete",()->{keyboard.backspace();changed();},1);keyButton(editing,"清空","search-clear",()->{keyboard.clear();changed();},1);
        Button submit=a.button("立即搜索","search-submit",()->submit());submit.setTextSize(15);submit.setMinHeight(a.dp(40));submit.setMinimumHeight(a.dp(40));submit.setPadding(a.dp(8),a.dp(5),a.dp(8),a.dp(5));LinearLayout.LayoutParams submitSize=new LinearLayout.LayoutParams(-1,a.dp(42));submitSize.topMargin=a.dp(8);left.addView(submit,submitSize);
        LinearLayout right=a.vertical();split.addView(right,new LinearLayout.LayoutParams(0,-1,1));
        status=a.text("输入即搜索 · 停顿片刻自动更新结果。",14,MainActivity.MUTED);status.setMinHeight(a.dp(30));right.addView(status);
        HorizontalScrollView filterScroll=new HorizontalScrollView(a);filterScroll.setHorizontalScrollBarEnabled(false);sourceFilters=a.row();filterScroll.addView(sourceFilters);right.addView(filterScroll,new LinearLayout.LayoutParams(-1,a.dp(42)));
        ScrollView resultScroll=new ScrollView(a);resultScroll.setTag("global-search-results");resultScroll.setClipToPadding(false);resultBody=a.vertical();resultBody.setPadding(a.dp(4),a.dp(8),a.dp(4),a.dp(20));resultScroll.addView(resultBody);right.addView(resultScroll,new LinearLayout.LayoutParams(-1,0,1));
        rebuildKeys();changed();showHistory();
        if(searchAgain&&!restored.trim().isEmpty())submit();
    }
    boolean current(){return !closed&&!a.isFinishing()&&pageTicket==a.generation;}
    void modeButton(LinearLayout row,String title,PinyinKeyboardModel.Mode mode){Button b=keyButton(row,title,"search-mode:"+mode.name(),()->{keyboard.mode(mode);candidatePage=0;rebuildKeys();changed();},1);modeButtons.put(mode,b);}
    Button keyButton(LinearLayout row,String label,String tag,Runnable action,float weight){
        Button b=a.button(label,tag,action);b.setMinWidth(0);b.setMinimumWidth(0);b.setMinHeight(0);b.setMinimumHeight(0);b.setTextSize(14);b.setPadding(a.dp(2),0,a.dp(2),0);b.setBackground(a.bg(0xff29292e,7));b.setOnFocusChangeListener((v,focus)->{b.setTextColor(focus?MainActivity.DARK:MainActivity.WHITE);b.setBackground(a.bg(focus?MainActivity.WHITE:0xff29292e,7));});b.setOnKeyListener((v,key,event)->physicalKey(key,event));LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(0,a.dp(28),weight);size.setMargins(a.dp(2),a.dp(2),a.dp(2),a.dp(2));row.addView(b,size);return b;
    }
    void rebuildKeys(){keys.removeAllViews();String characters=keyboard.mode()==PinyinKeyboardModel.Mode.NUMBERS?"1234567890-_:.,!?@#&/":keyboard.mode()==PinyinKeyboardModel.Mode.LETTERS?"abcdefghijklmnopqrstuvwxyz":"abcdefghijklmnopqrstuvwxyz'";
        for(int start=0;start<characters.length();start+=6){LinearLayout row=a.row();keys.addView(row);for(int column=0;column<6;column++){int index=start+column;if(index>=characters.length()){row.addView(new View(a),new LinearLayout.LayoutParams(0,a.dp(32),1));continue;}String letter=characters.substring(index,index+1);keyButton(row,letter.toUpperCase(Locale.ROOT),"search-key:"+letter,()->{keyboard.input(letter);changed();},1);}}
        for(Map.Entry<PinyinKeyboardModel.Mode,Button> entry:modeButtons.entrySet())entry.getValue().setText((entry.getKey()==keyboard.mode()?"● ":"")+modeLabel(entry.getKey()));
    }
    String modeLabel(PinyinKeyboardModel.Mode mode){return mode==PinyinKeyboardModel.Mode.PINYIN?"拼音":mode==PinyinKeyboardModel.Mode.LETTERS?"字母":"数字";}
    boolean physicalKey(int key,KeyEvent event){if(key==KeyEvent.KEYCODE_DPAD_CENTER||key==KeyEvent.KEYCODE_ENTER){View focus=a.getCurrentFocus();if(focus!=null)focus.setAlpha(event.getAction()==KeyEvent.ACTION_DOWN?.65f:1f);}if(event.getAction()!=KeyEvent.ACTION_DOWN)return false;if(key==KeyEvent.KEYCODE_DEL){keyboard.backspace();changed();return true;}if(key==KeyEvent.KEYCODE_SPACE){keyboard.space();changed();return true;}if(key==KeyEvent.KEYCODE_SEARCH){submit();return true;}int unicode=event.getUnicodeChar();if(unicode>=32&&unicode<127&&key!=KeyEvent.KEYCODE_DPAD_CENTER&&key!=KeyEvent.KEYCODE_ENTER){keyboard.input(String.valueOf((char)unicode).toLowerCase(Locale.ROOT));changed();return true;}return false;}
    void changed(){if(input==null)return;if(a.phonetic!=null&&keyboard.composition().isEmpty()&&keyboard.committed().length()>=2)a.phonetic.prefer(keyboard.committed());input.setText(keyboard.query().isEmpty()?"输入片名…":keyboard.committed()+(keyboard.composition().isEmpty()?"":"  "+keyboard.composition()));composition.setText(keyboard.composition().isEmpty()?(keyboard.mode()==PinyinKeyboardModel.Mode.PINYIN?"默认识别首拼 / 全拼 · 也可拼音选字":"直接输入字母、首字母或数字"):"拼音  "+keyboard.composition());candidatePage=0;renderCandidates();scheduleSearch();}
    void renderCandidates(){candidates.removeAllViews();List<PinyinKeyboardModel.Candidate> values=keyboard.candidates();if(values.isEmpty()){TextView hint=a.text(keyboard.composition().isEmpty()?"":"继续输入拼音，或切到字母搜索",12,MainActivity.MUTED);candidates.addView(hint);return;}int pages=(values.size()+5)/6;candidatePage=Math.max(0,Math.min(candidatePage,pages-1));final int page=candidatePage;keyButton(candidates,"‹","candidate-previous",()->{candidatePage=Math.max(0,candidatePage-1);renderCandidates();},1).setEnabled(page>0);
        for(int i=page*6;i<Math.min(values.size(),page*6+6);i++){PinyinKeyboardModel.Candidate candidate=values.get(i);keyButton(candidates,candidate.text,"candidate:"+candidate.text,()->{keyboard.select(candidate);changed();View first=a.root.findViewWithTag("search-key:a");if(first!=null)first.requestFocus();},1);}
        keyButton(candidates,"›","candidate-next",()->{candidatePage=Math.min(pages-1,candidatePage+1);renderCandidates();},1).setEnabled(page<pages-1);
    }
    void scheduleSearch(){
        String query=keyboard.query().trim();if(query.equals(edited))return;edited=query;
        if(pendingSearch!=null)a.ui.removeCallbacks(pendingSearch);pendingSearch=null;
        ++searchSerial;if(coordinator!=null){coordinator.close();coordinator=null;}
        submitted="";results.clear();posterCards.clear();sourceFilters.removeAllViews();resultBody.removeAllViews();
        if(query.isEmpty()){status.setText("输入即搜索 · 支持中文、首拼和全拼");showHistory();return;}
        status.setText("正在输入… 停顿后自动搜索");
        pendingSearch=()->{pendingSearch=null;if(current()&&query.equals(keyboard.query().trim()))submit(false);};a.ui.postDelayed(pendingSearch,650);
    }
    void submit(){submit(true);}
    void submit(boolean remember){if(!current())return;if(pendingSearch!=null){a.ui.removeCallbacks(pendingSearch);pendingSearch=null;}String query=keyboard.query().trim();if(query.isEmpty()){status.setText("先输入一个片名。也可以搜索英文、首字母或数字。");return;}submitted=query;if(remember)saveHistory(query);if(coordinator!=null)coordinator.close();results.clear();posterCards.clear();finished=failed=timedOut=busy=matched=0;activeFilter="";sourceFilters.removeAllViews();resultBody.removeAllViews();final int serial=++searchSerial;
        List<Cms.Site> sources=new ArrayList<>();if(a.config!=null)for(Cms.Site site:a.config.sites)if(site.searchable&&a.available(site))sources.add(site);
        // Only changes scheduling order; every available searchable source participates.
        final String selected=a.prefs.getString("selected_site","");Collections.sort(sources,(x,y)->Boolean.compare(!x.key.equals(selected),!y.key.equals(selected)));
        final int total=sources.size();status.setText(total==0?"没有可搜索来源，请先导入配置并启用来源扩展。":"正在搜索全部 "+total+" 个来源…");
        if(total==0)return;
        final List<String> variants=a.phonetic==null?Collections.singletonList(query):a.phonetic.expand(query);final boolean latin=query.matches("[A-Za-z0-9' -]+");
        if(variants.size()>1)status.setText("搜索全部 "+total+" 个来源 · 自动匹配 "+String.join(" / ",variants.subList(0,Math.min(2,variants.size()))));
        SearchCoordinator.configureThreads(a.prefs.getInt("search_threads",6));coordinator=new SearchCoordinator((site,keyword)->{List<Cms.Video> found=new ArrayList<>();Set<String> ids=new HashSet<>();Exception last=null;int count=0;for(String term:variants){if(Thread.currentThread().isInterrupted())break;if(++count>3)break;try{List<Cms.Video> batch=Cms.listing(a.engine(site).search(term,1)).videos;for(Cms.Video video:batch)if(ids.add(video.id)&&(!latin||a.phonetic==null||a.phonetic.matches(video.title,query)||term.equalsIgnoreCase(query)))found.add(video);if(found.size()>=12)break;}catch(Exception error){last=error;}}if(found.isEmpty()&&last!=null)throw last;return found;},(site,videos,outcome)->a.ui.post(()->{if(!current()||serial!=searchSerial)return;a.learnTitles(videos);SourceResult source=new SourceResult(site,videos,outcome);results.put(site.key,source);finished++;if(outcome==SearchCoordinator.Outcome.RESULT)matched++;if(outcome==SearchCoordinator.Outcome.FAILED)failed++;if(outcome==SearchCoordinator.Outcome.TIMEOUT)timedOut++;if(outcome==SearchCoordinator.Outcome.BUSY)busy++;updateStatus(total);renderFilters();renderResults();}),Math.max(10,Math.min(30,a.prefs.getInt("search_timeout",20)))*1000L,90000L);coordinator.start(sources,query);
    }
    void updateStatus(int total){String text=(finished==total?"搜索结束":"搜索中")+" · "+finished+" / "+total+" 个来源已处理 · "+matched+" 个有结果";if(timedOut>0)text+=" · "+timedOut+" 个超时";if(failed>0)text+=" · "+failed+" 个暂不可用";if(busy>0)text+=" · "+busy+" 个未完成";status.setText(text);}
    void renderFilters(){String focus=focusedTag(sourceFilters);sourceFilters.removeAllViews();addFilter("全部","",focus);for(SourceResult source:results.values())if(!source.videos.isEmpty())addFilter(clean(source.site.name),source.site.key,focus);}
    void addFilter(String label,String key,String focus){Button b=a.navButton((key.equals(activeFilter)?"● ":"")+label,"search-filter:"+key,()->{activeFilter=key;renderFilters();renderResults();});b.setTextSize(12);a.addButton(sourceFilters,b);if(String.valueOf(b.getTag()).equals(focus))b.requestFocus();}
    void renderResults(){String focus=focusedTag(resultBody);resultBody.removeAllViews();List<SourceResult> matching=new ArrayList<>();for(SourceResult source:results.values())if((activeFilter.isEmpty()||source.site.key.equals(activeFilter))&&!source.videos.isEmpty())matching.add(source);
        int shown=0;LinearLayout row=null;for(SourceResult source:matching)for(int i=0;i<Math.min(12,source.videos.size());i++){if(shown>=120)break;if(shown%4==0){row=a.row();row.setGravity(Gravity.TOP);row.setClipChildren(false);resultBody.addView(row);}Cms.Video video=source.videos.get(i);String cardKey=source.site.key+":"+video.id;LinearLayout card=posterCards.get(cardKey);if(card==null){card=a.vertical();final LinearLayout selectedCard=card;card.setPadding(a.dp(4),a.dp(4),a.dp(4),a.dp(8));ImageView poster=new ImageView(a);poster.setScaleType(ImageView.ScaleType.CENTER_CROP);poster.setBackground(a.bg(0xff25252a,9));poster.setClipToOutline(true);LinearLayout.LayoutParams posterSize=new LinearLayout.LayoutParams(a.dp(110),a.dp(165));posterSize.gravity=Gravity.CENTER_HORIZONTAL;card.addView(poster,posterSize);a.poster(video.poster,poster);TextView title=a.text(video.title,14,MainActivity.WHITE);title.setSingleLine(true);title.setEllipsize(android.text.TextUtils.TruncateAt.END);title.setPadding(a.dp(2),a.dp(6),0,0);card.addView(title);TextView origin=a.text(clean(source.site.name),11,MainActivity.MUTED);origin.setSingleLine(true);origin.setEllipsize(android.text.TextUtils.TruncateAt.END);card.addView(origin);card.setTag("global-result:"+source.site.key+":"+video.id);card.setFocusable(true);card.setFocusableInTouchMode(true);card.setClickable(true);card.setOnClickListener(view->{saveHistory(submitted);a.open(new MainActivity.Screen(()->a.detail(source.site,video)),true);});card.setOnFocusChangeListener((view,selected)->{GradientDrawable background=a.bg(selected?0xff393940:Color.TRANSPARENT,11);if(selected)background.setStroke(a.dp(2),MainActivity.WHITE);selectedCard.setBackground(background);});posterCards.put(cardKey,card);}if(card.getParent() instanceof ViewGroup)((ViewGroup)card.getParent()).removeView(card);LinearLayout.LayoutParams cell=new LinearLayout.LayoutParams(0,-2,1);cell.setMargins(a.dp(3),a.dp(3),a.dp(8),a.dp(13));row.addView(card,cell);if(String.valueOf(card.getTag()).equals(focus))card.requestFocus();shown++;}
        if(row!=null&&shown%4!=0)for(int i=shown%4;i<4;i++)row.addView(new View(a),new LinearLayout.LayoutParams(0,1,1));if(shown==0&&finished>0){TextView empty=a.text("暂时还没有找到匹配影片。\n可以继续等待其他片源，或换一个片名。",16,MainActivity.MUTED);empty.setPadding(a.dp(8),a.dp(30),a.dp(8),0);resultBody.addView(empty);}if(shown>=120)resultBody.addView(a.text("显示前 120 条结果；选择上方片源查看该源结果。",12,MainActivity.MUTED));
    }
    String focusedTag(ViewGroup group){View focus=a.getCurrentFocus();if(focus==null||focus.getTag()==null)return null;View parent=focus;while(parent!=null){if(parent==group)return String.valueOf(focus.getTag());if(!(parent.getParent() instanceof View))break;parent=(View)parent.getParent();}return null;}
    String clean(String title){return title==null?"来源":title.replaceAll("[\\p{So}\\p{Cs}]","").replace('┃',' ').trim();}
    void showHistory(){resultBody.removeAllViews();resultBody.addView(a.text("最近搜索",17,MainActivity.WHITE));List<String> history=history();if(history.isEmpty()){TextView hint=a.text("支持中文、首拼和全拼，例如 st / santi。\n也可以输入字母、数字或选择拼音候选字。",15,MainActivity.MUTED);hint.setLineSpacing(a.dp(6),1);hint.setPadding(0,a.dp(18),0,0);resultBody.addView(hint);return;}for(String value:history){Button recent=a.navButton(value,"search-history:"+value,()->{keyboard.set(value);changed();submit();});a.addButton(resultBody,recent);}Button clear=a.navButton("清除搜索记录","search-clear-history",()->{a.prefs.edit().remove("global_search_history").apply();showHistory();});a.addButton(resultBody,clear);}
    List<String> history(){List<String> out=new ArrayList<>();try{JSONArray list=new JSONArray(a.prefs.getString("global_search_history","[]"));for(int i=0;i<Math.min(8,list.length());i++){String text=list.optString(i);if(!text.isEmpty())out.add(text);}}catch(Exception ignored){}return out;}
    void saveHistory(String query){List<String> previous=history();previous.remove(query);previous.add(0,query);JSONArray list=new JSONArray();for(int i=0;i<Math.min(8,previous.size());i++)list.put(previous.get(i));a.prefs.edit().putString("global_search_history",list.toString()).apply();}
    @Override public void close(){closed=true;if(pendingSearch!=null){a.ui.removeCallbacks(pendingSearch);pendingSearch=null;}posterCards.clear();searchSerial++;if(coordinator!=null)coordinator.close();}
}
