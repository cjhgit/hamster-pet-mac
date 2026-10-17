// Native engine integration checks. Include the implementation to inspect the
// original state machine without adding diagnostic APIs to the shipping app.
#include "../hamster-mac/Native/HamsterEngine.cpp"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <set>

static double n(V v,int key){return number(G(v,key));}
static void tick(void* e,int frames){for(int i=0;i<frames;i++)HamsterEngineStep(e,1000.0/30);}
static void printObject(V v){
    printf("{");bool first=true;
    std::vector<std::pair<std::string,V>> entries;
    for(auto& kv:v.o->fields){
        if(kv.second.tag==V::Reference)continue;
        for(auto& name:E->keys)if(name.second==kv.first){entries.emplace_back(name.first,kv.second);break;}
    }
    std::sort(entries.begin(),entries.end(),[](auto& a,auto& b){return a.first<b.first;});
    for(auto& kv:entries){
        if(!first)printf(",");first=false;printf("\"%s\":",kv.first.c_str());V x=kv.second;
        if(x.tag==V::Undefined)printf("null");else if(x.tag==V::Boolean)printf(x.n?"true":"false");else if(std::isfinite(x.n))printf("%.17g",x.n);else printf("null");
    }
    printf("}");
}
static void trace(void* engine,int frame){
    printf("{\"frame\":%d,\"root\":",frame);printObject(E->root);printf(",\"ham\":");printObject(G(E->root,P_ham));printf("}\n");
}
static void printPath(CGPathRef path){
    printf("[");bool first=true;
    struct Context {bool *first;};Context context{&first};
    CGPathApply(path,&context,[](void* raw,const CGPathElement* e){
        auto c=static_cast<Context*>(raw);if(!*c->first)printf(",");*c->first=false;
        printf("[%d",int(e->type));int count=e->type==kCGPathElementAddQuadCurveToPoint?2:e->type==kCGPathElementAddCurveToPoint?3:e->type==kCGPathElementCloseSubpath?0:1;
        for(int i=0;i<count;i++)printf(",%.17g,%.17g",e->points[i].x,e->points[i].y);printf("]");
    });printf("]");
}
static void printGeometry(V v){
    printf("{\"name\":\"%s\",\"fills\":[",text(G(v,P__name)).c_str());
    auto shapes=[](auto& list){bool first=true;for(auto& s:list){if(!first)printf(",");first=false;printf("{\"color\":%u,\"alpha\":%.17g,\"width\":%.17g,\"path\":",s->color,s->alpha,s->width);printPath(s->path);printf("}");}};
    shapes(v.o->graphics->fills);printf("],\"strokes\":[");shapes(v.o->graphics->strokes);printf("],\"children\":[");
    bool first=true;for(auto child:v.o->children){if(!first)printf(",");first=false;printGeometry(child);}printf("]}");
}
static void verifyRenderingCache(void *engine) {
    auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for(int width:{371,742,1484})for(bool night:{false,true,false}) {
        int height=int(std::ceil(width*212.0/282));
        auto cached=CGBitmapContextCreate(nullptr,width,height,8,0,space,kCGImageAlphaPremultipliedLast);
        auto vector=CGBitmapContextCreate(nullptr,width,height,8,0,space,kCGImageAlphaPremultipliedLast);
        for(auto ctx:{cached,vector}) {
            CGContextSetFillColorSpace(ctx,space);CGContextSetStrokeColorSpace(ctx,space);
            CGContextTranslateCTM(ctx,0.375,height-0.25);
            CGContextScaleCTM(ctx,width/282.0,-width/282.0);
        }
        HamsterEngineMouse(engine,100+width%100,80,1);
        HamsterEngineMouse(engine,0,0,2);
        HamsterEngineDrawWithTheme(engine,cached,night);
        drawClip(E->root,vector,1,night,false);
        auto a=static_cast<const unsigned char*>(CGBitmapContextGetData(cached));
        auto b=static_cast<const unsigned char*>(CGBitmapContextGetData(vector));
        int largest=0;double difference=0;
        for(int y=0;y<height;y++)for(int x=0;x<width*4;x++) {
            int d=std::abs(int(a[y*CGBitmapContextGetBytesPerRow(cached)+x])-int(b[y*CGBitmapContextGetBytesPerRow(vector)+x]));
            largest=std::max(largest,d);difference+=d;
        }
        printf("CACHE: %dpx %s, max channel delta %d, mean %.6f\n",width,night?"night":"day",largest,difference/(width*height*4));
        assert(largest<=2);
        assert(G(E->root,P_bg).o->graphics->image && G(E->root,P_wheel).o->graphics->image);
        CGContextRelease(cached);CGContextRelease(vector);
        tick(engine,30);
    }
    HamsterEnginePurgeRenderCache(engine);
    assert(!G(E->root,P_bg).o->graphics->image && !G(E->root,P_wheel).o->graphics->image);
    // Oversized scales must release their previous cache and use vector drawing.
    auto tiny=CGBitmapContextCreate(nullptr,16,16,8,0,space,kCGImageAlphaPremultipliedLast);
    HamsterEngineDraw(engine,tiny);
    assert(G(E->root,P_bg).o->graphics->image && G(E->root,P_wheel).o->graphics->image);
    CGContextScaleCTM(tiny,100,100);
    HamsterEngineDraw(engine,tiny);
    assert(!G(E->root,P_bg).o->graphics->image && !G(E->root,P_wheel).o->graphics->image);
    CGContextRelease(tiny);CGColorSpaceRelease(space);
    puts("PASS: cached/vector rendering at three scales, fractional origins, theme changes, cache purge and memory limit");
}
int main(int argc,char** argv){
    void* engine=HamsterEngineCreate(11042);HamsterEngineStart(engine);
    V root=E->root,h=G(root,P_ham);
    if(argc>1&&std::string(argv[1])=="--cache") {
        verifyRenderingCache(engine);HamsterEngineDestroy(engine);return 0;
    }
    if(argc>1&&std::string(argv[1])=="--trace") {
        trace(engine,0);
        for(int i=1;i<=16000;i++){tick(engine,1);if(i<=30||i%100==0)trace(engine,i);}
        HamsterEngineDestroy(engine);return 0;
    }
    if(argc>1&&std::string(argv[1])=="--geometry") {
        int previous=0;for(int frame:{0,100,500,5000}){tick(engine,frame-previous);previous=frame;printGeometry(root);printf("\n");}
        HamsterEngineDestroy(engine);return 0;
    }
    assert(n(G(root,P_wheel),P__width)==206);
    HamsterEngineMouse(engine,200,80,1);
    assert(n(G(root,P_freshFood),P_length)==1);
    V food=G(root,P_food);
    assert(bool(G(food,P_drag)));
    HamsterEngineMouse(engine,220,50,0);tick(engine,1);
    assert(n(G(food,P_pos),P_x)==220);
    HamsterEngineMouse(engine,220,50,2);
    assert(!bool(G(food,P_drag)));tick(engine,100);
    assert(n(G(food,P_pos),P_y)==206);
    puts("PASS: native pointer coordinates, feeding, dragging, throwing, gravity, floor bounce");
    std::set<int> seen;
    auto run=[&](int frames){
        for(int i=0;i<frames;i++){
            tick(engine,1);
            for(int key:{P_isOnWheel,P_eating,P_drinking,P_cleaning,P_sleeping,P_isTired})if(bool(G(h,key)))seen.insert(key);
            assert(std::isfinite(n(h,P__x))&&std::isfinite(n(h,P__y)));
        }
    };
    for(int key:{P_isOnWheel,P_getOnWheel,P_cleaning,P_drinking})R(h,key)=V(false);
    R(food,P_drag)=V(true);R(root,P__xmouse)=G(G(h,P_mouthPt),P_x);R(root,P__ymouse)=G(G(h,P_mouthPt),P_y);
    run(1);run(180);R(food,P_drag)=V(false);
    auto count=n(G(root,P_freshFood),P_length);
    HamsterEngineMouse(engine,167,105,1);
    assert(n(G(root,P_freshFood),P_length)==count);
    R(root,P_mouseActive)=V(false);run(1500);
    for(int key:{P_isOnWheel,P_cleaning,P_eating,P_drinking})R(h,key)=V(false);
    R(h,P_waterLevel)=V(0);run(1800);run(12000);
    for(int key:{P_isOnWheel,P_cleaning,P_eating,P_drinking})R(h,key)=V(false);
    R(h,P_waterLevel)=V(10);R(h,P_goingTo)=V(0);R(h,P_dest)={};R(h,P_runAt)=V(1e9);R(h,P_gotoRandomAt)=V(1e9);
    call(h,P_goToSleep,{});run(600);
    for(int key:{P_isOnWheel,P_eating,P_drinking,P_cleaning,P_sleeping,P_isTired}){
        if(!seen.count(key)){fprintf(stderr,"FAIL: missing behavior %s\n",propertyNames[key]);return 1;}
    }
    HamsterEngineMouse(engine,140,100,0);run(1);assert(!bool(G(h,P_sleeping)));
    assert(n(G(root,P_freshFood),P_length)+n(G(root,P_eatenFood),P_length)==10);
    puts("PASS: wheel, fatigue, food eating/recycling, drinking, grooming, sleep and wake, 9-minute simulation");
    verifyRenderingCache(engine);
    // Alternate cached/vector rendering of the same frames for a fair comparison.
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx=CGBitmapContextCreate(nullptr,1484,1100,8,0,space,kCGImageAlphaPremultipliedLast);
    CGContextSetFillColorSpace(ctx,space);CGContextSetStrokeColorSpace(ctx,space);
    CGContextTranslateCTM(ctx,0,1100);CGContextScaleCTM(ctx,1484.0/280,-1100.0/210);
    double stepMilliseconds=0,cachedMilliseconds=0,vectorMilliseconds=0;
    for(int i=0;i<300;i++){
        auto start=std::chrono::steady_clock::now();tick(engine,1);
        stepMilliseconds+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        for(bool cache:{i%2==0,i%2!=0}) {
            start=std::chrono::steady_clock::now();
            if(cache)HamsterEngineDraw(engine,ctx);else drawClip(E->root,ctx,1,false,false);
            double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
            (cache?cachedMilliseconds:vectorMilliseconds)+=ms;
        }
    }
    double ms=(stepMilliseconds+cachedMilliseconds)/300;
    printf("PERF: native simulation + Retina bitmap render: %.3f ms/frame; live objects: %zu\n",ms,E->heap.size());
    printf("PERF: draw cached %.3f vs vector %.3f ms/frame (%.1f%% less); simulation %.3f ms/frame\n",
           cachedMilliseconds/300,vectorMilliseconds/300,100*(1-cachedMilliseconds/vectorMilliseconds),stepMilliseconds/300);
    assert(ms<1000.0/30);
    CGContextRelease(ctx);CGColorSpaceRelease(space);
    HamsterEngineDestroy(engine);
    const char* colors[]={"bgColor","bodyColor","earColor","snoutColor","eyeColor","feetColor","tailColor","waterColor","foodColor","wheelColor","wheelOuterColor","wheelCenterColor","wheelSpokeColor"};
    engine=HamsterEngineCreate(11042);
    for(auto name:colors)HamsterEngineSetColor(engine,name,0x123456);
    HamsterEngineStart(engine);
    for(auto name:colors)assert(n(E->root,E->key(name))==0x123456);
    HamsterEngineDestroy(engine);puts("PASS: all thirteen color settings");
}
