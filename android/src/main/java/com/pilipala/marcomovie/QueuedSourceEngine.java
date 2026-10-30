package com.pilipala.marcomovie;

/** Keeps extension state serialized; user-selected details/playback precede queued browsing. */
final class QueuedSourceEngine implements SourceEngine {
    final SourceEngine delegate;final SourceGate gate=new SourceGate();
    QueuedSourceEngine(SourceEngine source){delegate=source;}
    public String home()throws Exception{return gate.call(false,delegate::home);}
    public String homeVideos()throws Exception{return gate.call(false,delegate::homeVideos);}
    public String category(String id,int page)throws Exception{return gate.call(false,()->delegate.category(id,page));}
    public String search(String query,int page)throws Exception{return gate.call(false,()->delegate.search(query,page));}
    public String detail(String id)throws Exception{return gate.call(true,()->delegate.detail(id));}
    public String player(String flag,String id)throws Exception{return gate.call(true,()->delegate.player(flag,id));}
    public String action(String value)throws Exception{return gate.call(true,()->delegate.action(value));}
    public boolean requiresExternalRuntime(){return delegate.requiresExternalRuntime();}
    public void close(){try{gate.call(true,()->{delegate.close();return null;});}catch(Exception ignored){Thread.currentThread().interrupt();}}
}
