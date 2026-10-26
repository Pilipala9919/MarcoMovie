package com.pilipala.marcomovie;

/** Only shipped engine. An unsupported SourceEngine is never selected silently. */
public final class JsonCmsEngine implements SourceEngine {
    private final Cms.Site site;
    public JsonCmsEngine(Cms.Site site) {
        if(!site.supported())throw new IllegalArgumentException("Unsupported source type");
        this.site=site;
    }
    public String home()throws Exception{return Cms.fetch(Cms.query(site.api,"ac","list"),site.headers);}
    public String category(String id,int page)throws Exception{return Cms.fetch(Cms.query(site.api,"ac","detail","t",id,"pg",""+page),site.headers);}
    public String detail(String id)throws Exception{return Cms.fetch(Cms.query(site.api,"ac","detail","ids",id),site.headers);}
    public String search(String keyword,int page)throws Exception{return Cms.fetch(Cms.query(site.api,"ac","detail","wd",keyword,"pg",""+page),site.headers);}
    public boolean requiresExternalRuntime(){return false;}
}
