package com.pilipala.marcomovie;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded global search. A late or cancelled native plugin can never post a new result. */
public final class SearchCoordinator implements AutoCloseable {
    public enum Outcome {RESULT, EMPTY, FAILED, TIMEOUT, BUSY}
    public interface Runner {List<Cms.Video> search(Cms.Site site,String query)throws Exception;}
    public interface Listener {void source(Cms.Site site,List<Cms.Video> videos,Outcome outcome);}
    private static final ThreadPoolExecutor NETWORK=new ThreadPoolExecutor(6,6,30,TimeUnit.SECONDS,new ArrayBlockingQueue<Runnable>(64),r->{Thread t=new Thread(r,"movie-global-search");t.setDaemon(true);return t;});
    private static final ScheduledExecutorService TIMER=Executors.newSingleThreadScheduledExecutor(r->{Thread t=new Thread(r,"movie-search-deadline");t.setDaemon(true);return t;});
    private final List<Job> jobs=new ArrayList<>();
    private final long requestMs,sessionMs;
    private final Runner runner;private final Listener listener;
    private volatile boolean closed;
    private ScheduledFuture<?> deadline;private int nextJob,inFlight;
    public SearchCoordinator(Runner runner,Listener listener){this(runner,listener,20000,90000);}
    SearchCoordinator(Runner runner,Listener listener,long requestMs,long sessionMs){this.runner=runner;this.listener=listener;this.requestMs=requestMs;this.sessionMs=sessionMs;}
    static synchronized void configureThreads(int count){int value=Math.max(2,Math.min(6,count));if(value>NETWORK.getMaximumPoolSize()){NETWORK.setMaximumPoolSize(value);NETWORK.setCorePoolSize(value);}else{NETWORK.setCorePoolSize(value);NETWORK.setMaximumPoolSize(value);}}
    public synchronized void start(List<Cms.Site> sites,String query){
        if(closed||!jobs.isEmpty())throw new IllegalStateException("Search already started");
        for(Cms.Site site:sites)jobs.add(new Job(site,query));
        deadline=TIMER.schedule(()->{for(Job job:jobs)job.finish(Collections.emptyList(),job.started?Outcome.TIMEOUT:Outcome.BUSY);},sessionMs,TimeUnit.MILLISECONDS);
        pump();
    }
    private synchronized void pump(){
        while(!closed&&inFlight<NETWORK.getMaximumPoolSize()&&nextJob<jobs.size()){
            Job job=jobs.get(nextJob++);if(job.done.get())continue;job.allocated=true;inFlight++;
            try{job.future=RequestScope.submit(NETWORK,job);}catch(RejectedExecutionException busy){job.finish(Collections.emptyList(),Outcome.BUSY);}
        }
    }
    final class Job implements Runnable {
        final Cms.Site site;final String query;final AtomicBoolean done=new AtomicBoolean();
        volatile boolean started;boolean allocated;volatile Future<?> future;volatile ScheduledFuture<?> timeout;
        Job(Cms.Site site,String query){this.site=site;this.query=query;}
        public void run(){
            if(closed||done.get())return;started=true;
            timeout=TIMER.schedule(()->finish(Collections.emptyList(),Outcome.TIMEOUT),requestMs,TimeUnit.MILLISECONDS);
            try{
                List<Cms.Video> raw=runner.search(site,query);List<Cms.Video> videos=new ArrayList<>();Set<String> seen=new HashSet<>();
                if(raw!=null)for(Cms.Video v:raw)if(v!=null&&v.id!=null&&!v.id.isEmpty()&&!v.id.startsWith("msearch:")&&seen.add(v.id)){videos.add(v);if(videos.size()==24)break;}
                finish(videos,videos.isEmpty()?Outcome.EMPTY:Outcome.RESULT);
            }catch(Exception error){finish(Collections.emptyList(),Thread.currentThread().isInterrupted()?Outcome.TIMEOUT:Outcome.FAILED);}
        }
        void finish(List<Cms.Video> videos,Outcome outcome){
            if(!done.compareAndSet(false,true))return;if(timeout!=null)timeout.cancel(false);
            if((outcome==Outcome.TIMEOUT||outcome==Outcome.BUSY)&&future!=null)future.cancel(true);
            synchronized(SearchCoordinator.this){if(allocated){allocated=false;inFlight--;}}
            if(!closed){listener.source(site,Collections.unmodifiableList(videos),outcome);TIMER.execute(()->pump());}
        }
        void cancel(){done.set(true);if(timeout!=null)timeout.cancel(false);if(future!=null)future.cancel(true);}
    }
    @Override public synchronized void close(){if(closed)return;closed=true;if(deadline!=null)deadline.cancel(false);for(Job job:jobs)job.cancel();NETWORK.purge();}
}
