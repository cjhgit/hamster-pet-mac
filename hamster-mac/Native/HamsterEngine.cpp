#include "HamsterEngine.h"
#include "Properties.hpp"
#include <CoreText/CoreText.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
#include <sstream>
#include <limits>

namespace {
struct Obj;
struct V {
    enum Tag { Undefined, Number, Boolean, Reference } tag = Undefined;
    double n = 0;
    Obj *o = nullptr;
    V() = default;
    V(double v):tag(Number),n(v){}
    V(int v):V(double(v)){}
    V(bool v):tag(Boolean),n(v){}
    explicit V(Obj *p):tag(p ? Reference : Undefined),o(p){}
    explicit operator bool() const;
    V& operator+=(V); V& operator-=(V); V& operator*=(V); V& operator/=(V); V& operator%=(V);
    V operator++(int); V operator--(int);
};
using Args = std::vector<V>;
using Fn = V(*)(V,const Args&);
struct Shape {
    CGMutablePathRef path = CGPathCreateMutable();
    std::vector<CGPoint> mesh;
    bool meshReady = false;
    CGRect meshBounds = CGRectNull;
    uint32_t color = 0; double alpha = 1, width = 0;
    Shape(uint32_t c,double a,double w=0):color(c),alpha(a),width(w){}
    ~Shape() { CGPathRelease(path); }
};
struct Graphics {
    std::vector<std::unique_ptr<Shape>> fills, strokes;
    Shape *fill = nullptr, *stroke = nullptr;
    CGImageRef image = nullptr;
    CGAffineTransform imageTransform = CGAffineTransformIdentity;
    CGRect imageRect = CGRectZero;
    bool imageNight = false;
    double imageAlpha = 1;
    ~Graphics() { if (image) CGImageRelease(image); }
    bool lineEnabled = false;
    double width=0, alpha=1; uint32_t color=0;
    CGPoint pen = CGPointZero;
    double minX=INFINITY,minY=INFINITY,maxX=-INFINITY,maxY=-INFINITY;
    void point(double x,double y) {
        double pad=lineEnabled?width/2:0;
        minX=std::min(minX,x-pad); maxX=std::max(maxX,x+pad);
        minY=std::min(minY,y-pad); maxY=std::max(maxY,y+pad);
    }
};
struct Obj {
    enum Kind { Plain, Array, String, Function, Clip } kind = Plain;
    std::unordered_map<int,V> fields;
    std::vector<V> elements;
    std::vector<V> children;
    std::vector<V> drawChildren;
    bool childrenOrderDirty = true;
    std::string text;
    Obj *prototype=nullptr, *instancePrototype=nullptr;
    Fn fn=nullptr, initializer=nullptr;
    std::unique_ptr<Graphics> graphics;
    bool marked=false;
    CTLineRef textLine=nullptr;
    std::unique_ptr<Shape> textShape;
    bool textNight=false;
    double textAscent=0;
    ~Obj(){if(textLine)CFRelease(textLine);}
};
struct Timer { int id; V target, method; double at,delay; bool repeat; };
struct Engine {
    std::vector<std::unique_ptr<Obj>> heap;
    V globals,root,clipPrototype,arrayPrototype;
    std::unordered_map<std::string,int> keys;
    std::unordered_map<int,Timer> timers;
    uint32_t seed; int timerID=0,frames=0;
    double time=0;
    std::vector<HamsterVertex> metalVertices;
    std::vector<HamsterDrawCommand> metalCommands;
    std::vector<HamsterBodyVertex> bodyVertices;
    std::vector<uint32_t> bodyIndices;
    std::vector<double> bodySignature;
    std::vector<float> bodyField;
    std::vector<double> bodyFieldSignature;
    uint32_t bodyFieldGeneration=0;
    uint32_t bodyGeneration=0;
    explicit Engine(uint32_t s):seed(s) { for(int i=0;i<PropertyCount;i++) keys[propertyNames[i]]=i; }
    double random() { seed=seed*1664525u+1013904223u; return double(seed)/4294967296.0; }
    V allocate(Obj::Kind kind=Obj::Plain) {
        auto p=std::make_unique<Obj>(); p->kind=kind; Obj *raw=p.get(); heap.push_back(std::move(p)); return V(raw);
    }
    int key(const std::string& s) { auto it=keys.find(s); if(it!=keys.end())return it->second; int k=int(keys.size());keys[s]=k;return k; }
    void mark(V v) {
        if(!v.o||v.o->marked)return;
        auto p=v.o; p->marked=true;
        mark(V(p->prototype)); mark(V(p->instancePrototype));
        for(auto& kv:p->fields)mark(kv.second);
        for(auto x:p->elements)mark(x);
        for(auto x:p->children)mark(x);
    }
    void collect() {
        mark(globals);mark(root);mark(clipPrototype);mark(arrayPrototype);
        for(auto& kv:timers) {mark(kv.second.target);mark(kv.second.method);}
        heap.erase(std::remove_if(heap.begin(),heap.end(),[](auto& p){return !p->marked;}),heap.end());
        for(auto& p:heap)p->marked=false;
    }
};
thread_local Engine *E=nullptr;
V::operator bool() const {
    if(tag==Undefined)return false;
    if(tag!=Reference)return n!=0&&!std::isnan(n);
    return o && (o->kind!=Obj::String||!o->text.empty());
}
double number(V v) {
    if(v.tag==V::Number||v.tag==V::Boolean)return v.n;
    if(v.o&&v.o->kind==Obj::String) { try{return std::stod(v.o->text);}catch(...){return NAN;} }
    return NAN;
}
std::string text(V v) {
    if(v.tag==V::Undefined)return "undefined";
    if(v.tag==V::Boolean)return v.n?"true":"false";
    if(v.o)return v.o->kind==Obj::String?v.o->text:"[object Object]";
    std::ostringstream s;s.precision(15);s<<v.n;return s.str();
}
V string(const std::string& s) { V v=E->allocate(Obj::String);v.o->text=s;return v; }
V object(std::initializer_list<std::pair<int,V>> fields) {V v=E->allocate();for(auto& p:fields)v.o->fields[p.first]=p.second;return v;}
V array(const Args& a) {V v=E->allocate(Obj::Array);v.o->elements=a;v.o->prototype=E->arrayPrototype.o;return v;}
V function(Fn f) {V v=E->allocate(Obj::Function);v.o->fn=f;return v;}
V arg(const Args& a,size_t i) {return i<a.size()?a[i]:V();}
V& R(V v,int key) { static V sink; if(!v.o){sink={};return sink;}return v.o->fields[key]; }
V G(V v,int key) {
    if(!v.o)return {};
    if(key==P_length&&(v.o->kind==Obj::Array||v.o->kind==Obj::String))return V(int(v.o->kind==Obj::Array?v.o->elements.size():v.o->text.size()));
    if(v.o->graphics&&(key==P__width||key==P__height)) {
        auto& g=*v.o->graphics;return V(std::isfinite(g.minX)?(key==P__width?g.maxX-g.minX:g.maxY-g.minY):0);
    }
    for(Obj *p=v.o;p;p=p->prototype) {auto it=p->fields.find(key);if(it!=p->fields.end())return it->second;}
    return {};
}
V indexGet(V v,V i) {
    if(!v.o)return {};
    if(v.o->kind!=Obj::Array)return G(v,E->key(text(i)));
    double n=number(i);if(!std::isfinite(n)||n<0||n>=v.o->elements.size())return {};return v.o->elements[size_t(n)];
}
V& indexRef(V v,V i) {
    if(!v.o)return R(v,0);
    if(v.o->kind!=Obj::Array)return R(v,E->key(text(i)));
    double n=number(i);if(!std::isfinite(n)||n<0||n>100000)return R({},0);
    auto idx=size_t(n);if(idx>=v.o->elements.size())v.o->elements.resize(idx+1);return v.o->elements[idx];
}
V invoke(V method,V self,const Args& a) {return method.o&&method.o->fn?method.o->fn(self,a):V();}
V call(V self,int key,const Args& a) {return invoke(G(self,key),self,a);}
V operator+(V a,V b) {if((a.o&&a.o->kind==Obj::String)||(b.o&&b.o->kind==Obj::String))return string(text(a)+text(b));return V(number(a)+number(b));}
V operator-(V a,V b){return V(number(a)-number(b));}
V operator*(V a,V b){return V(number(a)*number(b));}
V operator/(V a,V b){return V(number(a)/number(b));}
V operator%(V a,V b){return V(std::fmod(number(a),number(b)));}
V operator-(V a){return V(-number(a));}
bool operator==(V a,V b){
    if(a.tag==V::Undefined||b.tag==V::Undefined)return a.tag==b.tag;
    if(a.o&&b.o) {if(a.o->kind==Obj::String&&b.o->kind==Obj::String)return a.o->text==b.o->text;return a.o==b.o;}
    return number(a)==number(b);
}
bool operator!=(V a,V b){return !(a==b);}
bool operator<(V a,V b){return number(a)<number(b);}
bool operator>(V a,V b){return number(a)>number(b);}
bool operator<=(V a,V b){return number(a)<=number(b);}
bool operator>=(V a,V b){return number(a)>=number(b);}
int32_t int32(V v){double n=number(v);if(!std::isfinite(n))return 0;return int32_t(uint32_t(int64_t(n)));}
V operator<<(V a,V b){return V(int(int32(a)<< (int32(b)&31)));}
V operator>>(V a,V b){return V(int(int32(a)>> (int32(b)&31)));}
V operator^(V a,V b){return V(int(int32(a)^int32(b)));}
V& V::operator+=(V b){return *this=*this+b;}
V& V::operator-=(V b){return *this=*this-b;}
V& V::operator*=(V b){return *this=*this*b;}
V& V::operator/=(V b){return *this=*this/b;}
V& V::operator%=(V b){return *this=*this%b;}
V V::operator++(int){V old=*this;*this+=V(1);return old;}
V V::operator--(int){V old=*this;*this-=V(1);return old;}
double roundJS(double v){return std::floor(v+0.5);}
V parseNumber(V v){try{return V(double(std::stoull(text(v),nullptr,0)));}catch(...){return V(NAN);}}
V schedule(V target,V method,V delay,bool repeat=false) {
    int id=++E->timerID;double d=number(delay);E->timers[id]={id,target,method,E->time+d,d,repeat};return V(id);
}

V clip(V klass={}) {
    V v=E->allocate(Obj::Clip);v.o->graphics=std::make_unique<Graphics>();
    v.o->prototype=klass.o?klass.o->instancePrototype:E->clipPrototype.o;
    for(int k:{P__x,P__y,P__rotation})R(v,k)=V(0);
    for(int k:{P__xscale,P__yscale,P__alpha})R(v,k)=V(100);
    R(v,P__visible)=V(true);
    if(klass.o&&klass.o->initializer)klass.o->initializer(v,{});
    return v;
}
V addChild(V self,V child,V name,V depth) {
    if(!self.o)return {};
    auto& children=self.o->children;
    self.o->childrenOrderDirty=true;
    for(auto it=children.begin();it!=children.end();) {
        if(G(*it,P__depth)==depth){R(*it,P__removed)=V(true);it=children.erase(it);}else ++it;
    }
    R(child,P__parent)=self;R(child,P__name)=name;R(child,P__depth)=depth;
    R(self,E->key(text(name)))=child;children.push_back(child);return child;
}
V builtinCreateClip(V self,const Args& a){return addChild(self,clip(),arg(a,0),arg(a,1));}
V builtinAttach(V self,const Args& a){
    V klass;std::string symbol=text(arg(a,0));
    for(auto& kv:E->globals.o->fields)if(text(G(kv.second,P_symbolName))==symbol){klass=kv.second;break;}
    return addChild(self,clip(klass),arg(a,1),arg(a,2));
}
V builtinCreateText(V self,const Args& a){return builtinCreateClip(self,a);}
V builtinNextDepth(V self,const Args&) {double d=0;for(auto c:self.o->children)d=std::max(d,number(G(c,P__depth))+1);return V(d);}
V builtinDepth(V self,const Args&){return G(self,P__depth);}
V builtinSwap(V self,const Args& a){
    V other=arg(a,0),parent=G(self,P__parent);
    if(!other.o&&parent.o) {for(auto c:parent.o->children)if(G(c,P__depth)==other){other=c;break;}}
    if(parent.o)parent.o->childrenOrderDirty=true;
    V otherParent=G(other,P__parent);if(otherParent.o)otherParent.o->childrenOrderDirty=true;
    V old=G(self,P__depth);R(self,P__depth)=other.o?G(other,P__depth):other;if(other.o)R(other,P__depth)=old;return {};
}
V builtinRemove(V self,const Args&) {
    V parent=G(self,P__parent);if(!parent.o)return {};
    parent.o->childrenOrderDirty=true;
    auto& children=parent.o->children;children.erase(std::remove_if(children.begin(),children.end(),[self](V v){return v.o==self.o;}),children.end());
    R(parent,E->key(text(G(self,P__name))))={};R(self,P__removed)=V(true);return {};
}
V builtinMask(V self,const Args& a){R(self,E->key("mask"))=arg(a,0);R(arg(a,0),P_isMask)=V(true);return {};}
V builtinClear(V self,const Args&){if(self.o&&self.o->graphics)self.o->graphics=std::make_unique<Graphics>();return {};}
V builtinLineStyle(V self,const Args& a){
    if(!self.o||!self.o->graphics)return {};
    auto& g=*self.o->graphics;g.lineEnabled=!a.empty()&&arg(a,0).tag!=V::Undefined;
    g.width=number(arg(a,0));if(g.width==0)g.width=0.05;g.color=a.size()>1?uint32_t(number(a[1])):0;
    g.alpha=a.size()>2?number(a[2])/100:1;g.stroke=nullptr;return {};
}
V builtinBeginFill(V self,const Args& a){
    if(!self.o||!self.o->graphics)return {};
    auto& g=*self.o->graphics;g.fills.push_back(std::make_unique<Shape>(uint32_t(number(arg(a,0))),a.size()>1?number(a[1])/100:1));g.fill=g.fills.back().get();return {};
}
V builtinEndFill(V self,const Args&){if(self.o&&self.o->graphics)self.o->graphics->fill=nullptr;return {};}
V builtinMove(V self,const Args& a){
    if(!self.o||!self.o->graphics)return {};
    double x=number(arg(a,0)),y=number(arg(a,1));if(!std::isfinite(x)||!std::isfinite(y))return {};
    auto& g=*self.o->graphics;g.pen={x,y};g.point(x,y);
    if(g.fill)CGPathMoveToPoint(g.fill->path,nullptr,x,y);if(g.stroke)CGPathMoveToPoint(g.stroke->path,nullptr,x,y);return {};
}
V segment(V self,const Args& a,bool curve){
    if(!self.o||!self.o->graphics)return {};
    for(auto v:a)if(!std::isfinite(number(v)))return {};
    auto& g=*self.o->graphics;double x=number(arg(a,curve?2:0)),y=number(arg(a,curve?3:1));
    if(g.lineEnabled&&!g.stroke){
        g.strokes.push_back(std::make_unique<Shape>(g.color,g.alpha,g.width));g.stroke=g.strokes.back().get();CGPathMoveToPoint(g.stroke->path,nullptr,g.pen.x,g.pen.y);
    }
    auto append=[&](Shape *s){if(!s)return;if(curve)CGPathAddQuadCurveToPoint(s->path,nullptr,number(a[0]),number(a[1]),x,y);else CGPathAddLineToPoint(s->path,nullptr,x,y);};
    append(g.fill);if(g.lineEnabled)append(g.stroke);g.point(x,y);g.pen={x,y};return {};
}
V builtinLine(V s,const Args& a){return segment(s,a,false);}
V builtinCurve(V s,const Args& a){return segment(s,a,true);}
V builtinFormat(V s,const Args& a){R(s,P_format)=arg(a,0);return {};}
V builtinPush(V s,const Args& a){for(auto v:a)s.o->elements.push_back(v);return V(int(s.o->elements.size()));}
V builtinPop(V s,const Args&){if(s.o->elements.empty())return {};V v=s.o->elements.back();s.o->elements.pop_back();return v;}
V builtinSplice(V s,const Args& a){auto& v=s.o->elements;int start=std::clamp(int(number(arg(a,0))),0,int(v.size())),count=std::clamp(int(number(arg(a,1))),0,int(v.size())-start);v.erase(v.begin()+start,v.begin()+start+count);return {};}
V builtinTimeout(V,const Args& a){return schedule(arg(a,0),arg(a,1),arg(a,2));}
V builtinCancel(V,const Args& a){E->timers.erase(int(number(arg(a,0))));return {};}

#include "Original.hpp"

void initializeRuntime() {
    E->globals=object({});E->clipPrototype=object({});E->arrayPrototype=object({});
    for(auto pair:std::initializer_list<std::pair<int,Fn>>{
        {P_createEmptyMovieClip,builtinCreateClip},{P_attachMovie,builtinAttach},{P_createTextField,builtinCreateText},
        {P_getNextHighestDepth,builtinNextDepth},{P_getDepth,builtinDepth},{P_swapDepths,builtinSwap},{P_removeMovieClip,builtinRemove},
        {P_setMask,builtinMask},{P_clear,builtinClear},{P_lineStyle,builtinLineStyle},{P_beginFill,builtinBeginFill},{P_endFill,builtinEndFill},
        {P_moveTo,builtinMove},{P_lineTo,builtinLine},{P_curveTo,builtinCurve},{P_setTextFormat,builtinFormat}})R(E->clipPrototype,pair.first)=function(pair.second);
    R(E->arrayPrototype,P_push)=function(builtinPush);R(E->arrayPrototype,P_pop)=function(builtinPop);R(E->arrayPrototype,P_splice)=function(builtinSplice);
    R(E->globals,P_Stage)=object({{P_width,V(280)},{P_height,V(210)}});
    R(E->globals,P_com)=object({{P_abowman,object({{P_math,object({})},{P_graphics,object({})}})}});
    R(E->globals,P__global)=object({{P_setTimeout,function(builtinTimeout)},{P_clearTimeout,function(builtinCancel)}});
    initializeClasses(); E->root=clip();
}
void advance(double elapsed){
    E->time+=elapsed;
    std::vector<int> due;
    for(auto& kv:E->timers)if(kv.second.at<=E->time)due.push_back(kv.first);
    std::sort(due.begin(),due.end());
    for(int id:due){
        auto it=E->timers.find(id);if(it==E->timers.end())continue;Timer t=it->second;
        if(t.repeat)it->second.at=E->time+t.delay;else E->timers.erase(it);
        call(t.target,E->key(text(t.method)),{});
    }
}
void setColor(CGContextRef ctx,uint32_t c,double alpha,bool stroke=false){
    double r=(c>>16&255)/255.0,g=(c>>8&255)/255.0,b=(c&255)/255.0;
    CGFloat rgba[]={CGFloat(r),CGFloat(g),CGFloat(b),CGFloat(alpha)};
    if(stroke)CGContextSetStrokeColor(ctx,rgba);else CGContextSetFillColor(ctx,rgba);
}
void drawGraphics(V v,CGContextRef ctx,double alpha,bool night) {
    const bool background= v.o==G(E->root,P_bg).o || v.o==G(E->root,P_wheel).o;
    const bool water= v.o==G(G(E->root,P_water),P_mcWater).o;
    for(auto& s:v.o->graphics->fills){
        uint32_t color=night&&background?0x354252:s->color;
        if(night&&water)color=(((color>>16&255)*3/5)<<16)|(((color>>8&255)*3/5)<<8)|((color&255)*3/5);
        setColor(ctx,color,s->alpha*alpha);CGContextAddPath(ctx,s->path);CGContextEOFillPath(ctx);
    }
    CGContextSetLineCap(ctx,kCGLineCapRound);CGContextSetLineJoin(ctx,kCGLineJoinRound);
    for(auto& s:v.o->graphics->strokes){setColor(ctx,night&&v.o==G(E->root,P_bg).o?0x8291A4:s->color,s->alpha*alpha,true);CGContextSetLineWidth(ctx,s->width);CGContextAddPath(ctx,s->path);CGContextStrokePath(ctx);}
}
// Cache only the two large, stationary vector surfaces. Moving parts retain
// vector rendering; the device transform keeps Retina edges pixel-aligned.
bool drawCachedGraphics(V v,CGContextRef ctx,double alpha,bool night) {
    if(v.o!=G(E->root,P_bg).o && v.o!=G(E->root,P_wheel).o)return false;
    auto& g=*v.o->graphics;
    auto transform=CGContextGetCTM(ctx);
    if(!g.image || !CGAffineTransformEqualToTransform(transform,g.imageTransform) ||
       g.imageNight!=night || g.imageAlpha!=alpha) {
        if(g.image){CGImageRelease(g.image);g.image=nullptr;}
        CGRect bounds=CGRectNull;
        for(auto& s:g.fills)bounds=CGRectUnion(bounds,CGPathGetPathBoundingBox(s->path));
        for(auto& s:g.strokes)bounds=CGRectUnion(bounds,CGRectInset(CGPathGetPathBoundingBox(s->path),-s->width/2,-s->width/2));
        if(CGRectIsNull(bounds))return false;
        auto pixels=CGRectIntegral(CGRectInset(CGRectApplyAffineTransform(bounds,transform),-1,-1));
        // Bound cache memory for unusually large windows, falling back to vectors.
        if(!std::isfinite(pixels.size.width)||!std::isfinite(pixels.size.height)||
           pixels.size.width<=0||pixels.size.height<=0||pixels.size.width>4096||pixels.size.height>4096||
           pixels.size.width*pixels.size.height>4*1024*1024)return false;
        auto space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        auto bitmap=CGBitmapContextCreate(nullptr,size_t(pixels.size.width),size_t(pixels.size.height),8,0,
                                         space,kCGImageAlphaPremultipliedLast);
        if(bitmap){CGContextSetFillColorSpace(bitmap,space);CGContextSetStrokeColorSpace(bitmap,space);}
        CGColorSpaceRelease(space);
        if(!bitmap)return false;
        auto local=transform;local.tx-=pixels.origin.x;local.ty-=pixels.origin.y;
        CGContextConcatCTM(bitmap,local);
        drawGraphics(v,bitmap,alpha,night);
        g.image=CGBitmapContextCreateImage(bitmap);
        CGContextRelease(bitmap);
        if(!g.image)return false;
        g.imageTransform=transform;g.imageRect=pixels;g.imageNight=night;g.imageAlpha=alpha;
    }
    CGContextSaveGState(ctx);
    CGContextConcatCTM(ctx,CGAffineTransformInvert(transform));
    CGContextSetInterpolationQuality(ctx,kCGInterpolationNone);
    CGContextDrawImage(ctx,g.imageRect,g.image);
    CGContextRestoreGState(ctx);
    return true;
}
void prepareText(V v,double alpha,bool night) {
    V format=G(v,P_format);
      if(v.o->textLine && v.o->textNight!=night){CFRelease(v.o->textLine);v.o->textLine=nullptr;}
      if(!v.o->textLine){
        CTFontRef font=CTFontCreateWithName(CFSTR("Icicle Country 2"),number(G(format,P_size)),nullptr);
        std::string content=text(G(v,P_text));CFStringRef str=CFStringCreateWithCString(nullptr,content.c_str(),kCFStringEncodingUTF8);
        uint32_t c=night?0xB4BCC6:uint32_t(number(G(format,P_color)));CGFloat rgba[]={CGFloat(c>>16&255)/255,CGFloat(c>>8&255)/255,CGFloat(c&255)/255,CGFloat(alpha)};
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGColorRef color=CGColorCreate(space,rgba);
        const void* keys[]={kCTFontAttributeName,kCTForegroundColorAttributeName};const void* vals[]={font,color};
        CFDictionaryRef attrs=CFDictionaryCreate(nullptr,keys,vals,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attr=CFAttributedStringCreate(nullptr,str,attrs);CTLineRef line=CTLineCreateWithAttributedString(attr);
        v.o->textLine=line;
        v.o->textNight=night;
        // Match the reference Canvas top baseline for the embedded author font.
        // Core Text's typographic ascent places this particular font too low.
        v.o->textAscent=9.25*number(G(format,P_size))/14;
        CFRelease(attr);CFRelease(attrs);CGColorRelease(color);CGColorSpaceRelease(space);CFRelease(str);CFRelease(font);
      }
}
void drawClip(V v,CGContextRef ctx,double alpha=1,bool night=false,bool cache=true){
    if(!v.o||!bool(G(v,P__visible))||bool(G(v,P_isMask))||bool(G(v,P__removed)))return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx,number(G(v,P__x)),number(G(v,P__y)));
    CGContextRotateCTM(ctx,number(G(v,P__rotation))*M_PI/180);
    CGContextScaleCTM(ctx,number(G(v,P__xscale))/100,number(G(v,P__yscale))/100);
    alpha*=number(G(v,P__alpha))/100;
    V mask=G(v,E->key("mask"));
    if(mask.o&&mask.o->graphics){
        CGMutablePathRef p=CGPathCreateMutable();CGAffineTransform t=CGAffineTransformMakeTranslation(number(G(mask,P__x)),number(G(mask,P__y)));
        for(auto& shape:mask.o->graphics->fills)CGPathAddPath(p,&t,shape->path);
        CGContextAddPath(ctx,p);CGContextClip(ctx);CGPathRelease(p);
    }
    if(v.o->graphics && (!cache || !drawCachedGraphics(v,ctx,alpha,night)))drawGraphics(v,ctx,alpha,night);
    V format=G(v,P_format);
    if(format.o){
        prepareText(v,alpha,night);
        CGContextSaveGState(ctx);CGContextSetAlpha(ctx,alpha);CGContextTranslateCTM(ctx,2,5+v.o->textAscent);CGContextScaleCTM(ctx,1,-1);CGContextSetTextMatrix(ctx,CGAffineTransformIdentity);CGContextSetTextPosition(ctx,0,0);CTLineDraw(v.o->textLine,ctx);CGContextRestoreGState(ctx);
    }
    // Original depth swaps determine which ears, feet, and face parts occlude others.
    if(!cache) {
        auto children=v.o->children;
        std::stable_sort(children.begin(),children.end(),[](V a,V b){return number(G(a,P__depth))<number(G(b,P__depth));});
        for(auto child:children)drawClip(child,ctx,alpha,night,false);
    } else {
        if(v.o->childrenOrderDirty) {
            v.o->drawChildren=v.o->children;
            std::stable_sort(v.o->drawChildren.begin(),v.o->drawChildren.end(),[](V a,V b){return number(G(a,P__depth))<number(G(b,P__depth));});
            v.o->childrenOrderDirty=false;
        }
        for(auto child:v.o->drawChildren)drawClip(child,ctx,alpha,night);
    }
    CGContextRestoreGState(ctx);
}
#include "MetalGeometry.hpp"
} // namespace

void *HamsterEngineCreate(uint32_t seed){auto *engine=new Engine(seed);E=engine;initializeRuntime();return engine;}
void HamsterEngineDestroy(void *engine){delete static_cast<Engine*>(engine);if(E==engine)E=nullptr;}
void HamsterEngineSetColor(void *engine,const char *name,uint32_t color){E=static_cast<Engine*>(engine);char hex[7];snprintf(hex,sizeof(hex),"%06X",color&0xffffff);R(E->root,E->key(std::string("up_")+name))=string(hex);}
void HamsterEngineStart(void *engine){E=static_cast<Engine*>(engine);initializeTimeline(E->root,{});HamsterEngineStep(engine,0);E->collect();}
void HamsterEngineSetWatermarkVisible(void *engine,int visible){E=static_cast<Engine*>(engine);R(G(E->root,P_txt),P__visible)=V(visible!=0);}
void HamsterEngineStep(void *engine,double elapsed){E=static_cast<Engine*>(engine);advance(std::max(0.0,elapsed));call(E->root,P_onEnterFrame,{});call(G(E->root,P_ham),P_onEnterFrame,{});if(++E->frames%30==0)E->collect();}
void HamsterEngineMouse(void *engine,double x,double y,int action){E=static_cast<Engine*>(engine);if(action!=2){R(E->root,P__xmouse)=V(x);R(E->root,P__ymouse)=V(y);}if(action==0)call(E->root,P_onMouseMove,{});if(action==1){call(E->root,P_onMouseMove,{});call(E->root,P_onMouseDown,{});}if(action==2)call(E->root,P_onMouseUp,{});}
void HamsterEnginePurgeRenderCache(void *engine){
    E=static_cast<Engine*>(engine);
    for(int key:{P_bg,P_wheel}) {
        V v=G(E->root,key);
        if(v.o&&v.o->graphics&&v.o->graphics->image){CGImageRelease(v.o->graphics->image);v.o->graphics->image=nullptr;}
    }
}
void HamsterEngineDraw(void *engine,CGContextRef ctx){
    HamsterEngineDrawWithTheme(engine,ctx,0);
}
void HamsterEngineDrawWithTheme(void *engine,CGContextRef ctx,int night){
    E=static_cast<Engine*>(engine);
    CGContextSaveGState(ctx);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextSetFillColorSpace(ctx,space);CGContextSetStrokeColorSpace(ctx,space);CGColorSpaceRelease(space);
    drawClip(E->root,ctx,1,night!=0);
    CGContextRestoreGState(ctx);
}

HamsterMetalFrame HamsterEngineBuildMetalFrame(void *engine,int night){
    E=static_cast<Engine*>(engine);
    E->metalVertices.clear();E->metalCommands.clear();
    // A white canvas is also geometry, so transparent window corners stay clear.
    uint32_t cover=metalQuad(CGRectMake(-1,-1,282,212));
    E->metalCommands.push_back({cover,6,cover,4,1,1,1,1});
    metalClip(E->root,CGAffineTransformIdentity,1,night!=0);
    return {E->metalVertices.data(),E->metalCommands.data(),uint32_t(E->metalVertices.size()),uint32_t(E->metalCommands.size())};
}

int HamsterEngineGetFrameCount(void *engine){return static_cast<Engine*>(engine)->frames;}
double HamsterEngineGetElapsedMilliseconds(void *engine){return static_cast<Engine*>(engine)->time;}

HamsterSceneState HamsterEngineGetSceneState(void *engine){
    E=static_cast<Engine*>(engine); V h=G(E->root,P_ham);
    auto n=[&](V v,int key,double fallback=0.0){double x=number(G(v,key));return std::isfinite(x)?x:fallback;};
    return {n(h,P__x),n(h,P__y),n(h,P_ang),n(h,P_standToAng,6.283185307179586),
        n(h,P_headAng),n(h,P_headAngZ),n(E->root,P_wheelAng),n(h,P_angVel),
        n(h,P_eyesCloseFrac,1),n(h,P_waterLevel,10),
        bool(G(h,P_isOnWheel)),bool(G(h,P_sleeping)),bool(G(h,P_eating)),bool(G(h,P_cleaning)),
        bool(G(h,P_dest)) || (bool(G(h,P_isOnWheel)) && !bool(G(h,P_isTired))),n(h,P__rotation),n(h,P_legVel)};
}

namespace {
double rigNumber(V v,int key,double fallback=0){double n=number(G(v,key));return std::isfinite(n)?n:fallback;}
V rigFeature(V h,int feature){const int keys[]={P_mcEye1,P_mcEye2,P_mcEar1,P_mcEar2};return feature>=0&&feature<4?G(h,keys[feature]):V();}
}
HamsterRigPoint HamsterEngineGetRigPoint(void *engine,int index){
    E=static_cast<Engine*>(engine);V h=G(E->root,P_ham);
    double a=rigNumber(h,P_ang),co=cos(a),si=sin(a);
    if(index<4){
        const int keys[]={P_rearBodyPt,P_frontBodyPt,P_headPos,P_tailPos};
        if(index<0)return {};
        V p=G(h,keys[index]);
        return {rigNumber(p,P_xpos),-rigNumber(p,P_ypos),si*rigNumber(p,P_x)-co*rigNumber(p,P_z),0};
    }
    int legIndex=(index-4)/5,part=(index-4)%5;
    const int legs[]={P_legFR,P_legFL,P_legRR,P_legRL};
    if(legIndex>3)return {};
    V leg=G(h,legs[legIndex]);
    if(part<3){
        const int keys[]={P_frontPt,P_sidePt,P_rearPt};V p=G(leg,keys[part]);
        return {rigNumber(p,P_xpos),-rigNumber(p,P_ypos),si*rigNumber(p,P_x)-co*rigNumber(p,P_z),0};
    }
    V base=G(leg,P_base),foot=G(leg,P_ftPos),p=part==3?G(leg,P_jtPos):foot;
    double forward=rigNumber(base,P_x)+rigNumber(leg,P_legLen)*cos(rigNumber(leg,P_legAng));
    double lateral=rigNumber(base,P_z)+rigNumber(foot,P_z);
    double footAngle=-M_PI-rigNumber(leg,P_maxFtAng)*std::min(0.0,rigNumber(foot,P_x))/rigNumber(leg,P_maxStepDist,20);
    if(bool(G(h,P_isOnWheel))){
        double phase=rigNumber(h,P_angVel)+rigNumber(leg,P_angOffset);
        double fraction=rigNumber(h,P_legVel)/rigNumber(h,P_maxLegVel,.9);
        double stride=rigNumber(h,P_maxStepDist,20)*(legIndex<2?.2:.4)+rigNumber(h,P_maxStepDist,20)*.8*fraction;
        forward+=cos(phase)*stride;
        footAngle=-M_PI-rigNumber(leg,P_maxFtAng)*std::min(0.0,cos(phase))*(stride/rigNumber(leg,P_maxStepDist,20));
        lateral=rigNumber(base,P_z);
    }else{ forward+=rigNumber(foot,P_x); }
    if(part==3)forward+=rigNumber(leg,P_ftLen)*cos(footAngle);
    return {rigNumber(p,P_xpos),-rigNumber(p,P_ypos)+rigNumber(leg,P_currStepHt),si*forward-co*lateral,0};
}
int HamsterEngineGetRigFeatureCount(void *engine,int feature){
    E=static_cast<Engine*>(engine);V p=G(rigFeature(G(E->root,P_ham),feature),P_opoints);
    return p.o?int(rigNumber(p,P_length)):0;
}
HamsterRigPoint HamsterEngineGetRigFeatureLocalPoint(void *engine,int feature,int index){
    E=static_cast<Engine*>(engine);V h=G(E->root,P_ham),clip=rigFeature(h,feature),points=G(clip,P_opoints);
    if(!points.o||index<0||index>=int(rigNumber(points,P_length)))return {};
    V p=indexGet(points,V(index));bool eye=feature<2;
    V center=G(h,eye?P_eyePt:P_earPt);
    double side=(feature%2==0?1:-1),gap=rigNumber(h,eye?P_eyeGap:P_earGap);
    double x=rigNumber(p,P_x)+rigNumber(center,P_x),y=rigNumber(p,P_y),z=rigNumber(p,P_z)+side*gap;
    if(eye)y*=std::clamp(rigNumber(h,P_eyesCloseFrac,1),.03,1.0);
    y+=rigNumber(center,P_y);
    return {x,-y,-z,bool(G(p,P_curve))};
}
HamsterRigPoint HamsterEngineGetRigFeaturePoint(void *engine,int feature,int index){
    if(index<0 || index>=HamsterEngineGetRigFeatureCount(engine,feature))return {};
    auto p=HamsterEngineGetRigFeatureLocalPoint(engine,feature,index);
    V h=G(E->root,P_ham);
    double a=rigNumber(h,P_ang)+rigNumber(h,P_headAng),co=cos(a),si=sin(a);
    HamsterRigPoint head=HamsterEngineGetRigPoint(engine,2);
    return {head.x+co*p.x-si*p.z,head.y+p.y,head.z+si*p.x+co*p.z,p.curve};
}
uint32_t HamsterEngineGetSceneColor(void *engine,const char *name){
    E=static_cast<Engine*>(engine);double c=number(G(E->root,E->key(name)));
    return std::isfinite(c)?uint32_t(c):0;
}
int HamsterEngineGetSceneFoodCount(void *engine){
    E=static_cast<Engine*>(engine);return int(number(G(G(E->root,P_freshFood),P_length)));
}
HamsterSceneFood HamsterEngineGetSceneFood(void *engine,int index){
    E=static_cast<Engine*>(engine);V foods=G(E->root,P_freshFood);
    if(index<0 || index>=int(number(G(foods,P_length))))return {};
    V f=indexGet(foods,V(index));V p=G(f,P_pos);
    return {number(G(p,P_x)),number(G(p,P_y)),number(G(f,P_radius)),bool(G(f,P__visible))};
}

#include "HamsterBodyMesh.hpp"
