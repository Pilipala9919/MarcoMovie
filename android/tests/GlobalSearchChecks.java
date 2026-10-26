package com.pilipala.marcomovie;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class GlobalSearchChecks {
    static int checks;
    static void check(boolean pass,String label){if(!pass)throw new AssertionError(label);checks++;System.out.println("PASS "+label);}
    static Cms.Site site(String key){Cms.Site site=new Cms.Site();site.key=key;site.name=key;return site;}
    static Cms.Video video(String id){Cms.Video video=new Cms.Video();video.id=id;video.title=id;return video;}
    public static void main(String[] args)throws Exception{
        PinyinKeyboardModel model=new PinyinKeyboardModel(Files.newInputStream(Paths.get(args[0],"android/src/main/assets/search/pinyin-characters.tsv")));
        check(model.dictionary.size()>400,"complete local syllable dictionary loaded");
        model.input("san");check(model.candidates().get(0).text.equals("三"),"frequency-ordered simplified Chinese candidate");
        model.select(model.candidates().get(0));model.input("ti");PinyinKeyboardModel.Candidate body=null;for(PinyinKeyboardModel.Candidate c:model.candidates())if(c.text.equals("体")){body=c;break;}model.select(body);
        check(model.query().equals("三体"),"remote pinyin selection composes a real Chinese film title");
        model.clear();model.input("santi");model.select(model.candidates().get(0));check(model.committed().equals("三")&&model.composition().equals("ti"),"continuous pinyin preserves remaining syllable after selection");model.select(model.candidates().get(0));check(model.query().equals("三体"),"continuous pinyin can be committed one syllable at a time");
        model.input("a");model.backspace();check(model.query().equals("三体"),"delete removes composition before committed text");model.backspace();check(model.query().equals("三"),"delete removes committed Han character");
        model.set("A\ud83d\ude00");model.backspace();check(model.query().equals("A"),"delete does not split a surrogate pair");
        model.clear();model.mode(PinyinKeyboardModel.Mode.LETTERS);model.input("st");check(model.query().equals("st")&&model.candidates().isEmpty(),"initial-letter query does not require a Chinese candidate");
        model.mode(PinyinKeyboardModel.Mode.NUMBERS);model.input("2026");check(model.query().equals("st2026"),"number mode appends directly");
        model.clear();model.mode(PinyinKeyboardModel.Mode.PINYIN);model.input("lv");check(model.candidates().stream().anyMatch(c->c.text.equals("旅")),"v-input supports umlaut-u syllables");
        model.space();check(model.composition().isEmpty()&&!model.committed().isEmpty(),"space commits the first pinyin candidate");model.mode(PinyinKeyboardModel.Mode.LETTERS);model.input("x");model.space();model.input("y");check(model.query().endsWith("x y"),"space works in literal mode");
        model.set(new String(new char[80]).replace('\0','a'));model.input("b");check(model.query().length()==80,"bounded query length");
        CountDownLatch complete=new CountDownLatch(4);Map<String,SearchCoordinator.Outcome> outcomes=new ConcurrentHashMap<>();AtomicInteger validCount=new AtomicInteger();
        SearchCoordinator coordinator=new SearchCoordinator((site,query)->{if(site.key.equals("broken"))throw new IOException("fixture");if(site.key.equals("slow")){Thread.sleep(500);return Collections.emptyList();}if(site.key.equals("empty"))return Collections.emptyList();return Arrays.asList(video("msearch:fixture"),video("42"),video("42"),video(""));},(site,videos,outcome)->{outcomes.put(site.key,outcome);validCount.addAndGet(videos.size());complete.countDown();},60,500);
        coordinator.start(Arrays.asList(site("good"),site("empty"),site("broken"),site("slow")),"三体");check(complete.await(2,TimeUnit.SECONDS),"all source outcomes finish despite one slow source");
        check(outcomes.get("good")==SearchCoordinator.Outcome.RESULT&&validCount.get()==1,"deduplicates playable results and skips cross-search placeholders");check(outcomes.get("empty")==SearchCoordinator.Outcome.EMPTY,"empty source remains distinct from failure");check(outcomes.get("broken")==SearchCoordinator.Outcome.FAILED,"source failure remains distinct from empty");check(outcomes.get("slow")==SearchCoordinator.Outcome.TIMEOUT,"per-source deadline delivers one timeout");coordinator.close();
        CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);AtomicInteger calls=new AtomicInteger();SearchCoordinator cancelled=new SearchCoordinator((site,query)->{entered.countDown();while(release.getCount()>0)try{release.await();}catch(InterruptedException ignored){}return Collections.singletonList(video("late"));},(site,videos,outcome)->calls.incrementAndGet(),1000,2000);cancelled.start(Collections.singletonList(site("uncancellable")),"old");check(entered.await(1,TimeUnit.SECONDS),"cancellation fixture is running");cancelled.close();release.countDown();Thread.sleep(100);check(calls.get()==0,"cancelled native work cannot deliver a stale result");
        System.out.println("OK "+checks+" global search and pinyin checks; no real source playback implied.");
    }
}
