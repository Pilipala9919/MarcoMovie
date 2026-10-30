package com.pilipala.marcomovie;

import java.util.concurrent.Callable;

/** Per-instance serialization with interruptible waits and foreground preference.
 * Never interrupts or concurrently enters an already-running native plugin. */
final class SourceGate {
    private boolean occupied;
    private int foreground;
    <T> T call(boolean urgent,Callable<T> task)throws Exception {
        synchronized(this){
            if(urgent)foreground++;
            try{
                while(occupied||(!urgent&&foreground>0))wait();
                if(Thread.currentThread().isInterrupted())throw new InterruptedException();
                occupied=true;
            }finally{if(urgent)foreground--;notifyAll();}
        }
        try{return task.call();}finally{synchronized(this){occupied=false;notifyAll();}}
    }
}
