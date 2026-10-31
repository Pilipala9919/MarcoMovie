package com.pilipala.marcomovie;

import java.util.concurrent.Callable;

/** Per-instance serialization with interruptible waits and foreground preference.
 * Never interrupts or concurrently enters an already-running native plugin. */
final class SourceGate {
    private static final ThreadLocal<long[]> TIMING=new ThreadLocal<>();
    static <T> T measured(long[] result,Callable<T> work)throws Exception {
        long[] previous=TIMING.get();TIMING.set(result);
        try{return work.call();}finally{if(previous==null)TIMING.remove();else TIMING.set(previous);}
    }
    private boolean occupied;
    private int foreground;
    <T> T call(boolean urgent,Callable<T> task)throws Exception {
        long queued=System.nanoTime();
        synchronized(this){
            if(urgent)foreground++;
            try{
                while(occupied||(!urgent&&foreground>0))wait();
                if(Thread.currentThread().isInterrupted())throw new InterruptedException();
                occupied=true;
            }finally{if(urgent)foreground--;notifyAll();}
        }
        long entered=System.nanoTime();long[] timing=TIMING.get();
        if(timing!=null)timing[0]+=entered-queued;
        try{return task.call();}finally{if(timing!=null)timing[1]+=System.nanoTime()-entered;synchronized(this){occupied=false;notifyAll();}}
    }
}
