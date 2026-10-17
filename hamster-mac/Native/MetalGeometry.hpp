// Geometry only: rasterization, even-odd coverage and compositing run on Metal.
// Static shapes keep their local mesh; dynamic paths are rebuilt by the model.
struct MetalContours {
    std::vector<std::vector<CGPoint>> contours;
    CGPoint pen=CGPointZero, start=CGPointZero;
    void point(CGPoint p) { contours.back().push_back(p);pen=p; }
    static CGPoint mid(CGPoint a,CGPoint b){return {(a.x+b.x)/2,(a.y+b.y)/2};}
    static double distance(CGPoint p,CGPoint a,CGPoint b){
        double dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);
        return length>1e-9?std::abs(dy*(p.x-a.x)-dx*(p.y-a.y))/length:std::hypot(p.x-a.x,p.y-a.y);
    }
    void curve(CGPoint a,CGPoint b,CGPoint c,CGPoint d,int depth=0){
        // At the largest preset on Retina, 0.025 stage units is < 0.14 pixel.
        if(depth>=12||std::max(distance(b,a,d),distance(c,a,d))<=0.025){point(d);return;}
        auto ab=mid(a,b),bc=mid(b,c),cd=mid(c,d),abc=mid(ab,bc),bcd=mid(bc,cd),m=mid(abc,bcd);
        curve(a,ab,abc,m,depth+1);curve(m,bcd,cd,d,depth+1);
    }
    explicit MetalContours(CGPathRef path){
        CGPathApply(path,this,[](void *raw,const CGPathElement *e){
            auto& c=*static_cast<MetalContours*>(raw);
            switch(e->type){
                case kCGPathElementMoveToPoint:c.contours.emplace_back();c.start=e->points[0];c.point(c.start);break;
                case kCGPathElementAddLineToPoint:c.point(e->points[0]);break;
                case kCGPathElementAddQuadCurveToPoint:{
                    auto a=c.pen,b=e->points[0],d=e->points[1];
                    c.curve(a,{a.x+(b.x-a.x)*2/3,a.y+(b.y-a.y)*2/3},
                              {d.x+(b.x-d.x)*2/3,d.y+(b.y-d.y)*2/3},d);break;
                }
                case kCGPathElementAddCurveToPoint:c.curve(c.pen,e->points[0],e->points[1],e->points[2]);break;
                case kCGPathElementCloseSubpath:c.point(c.start);break;
            }
        });
    }
};
void metalTriangle(std::vector<CGPoint>& out,CGPoint a,CGPoint b,CGPoint c){out.push_back(a);out.push_back(b);out.push_back(c);}
void prepareMesh(Shape& shape){
    if(shape.meshReady)return;
    shape.meshReady=true;
    MetalContours path(shape.path);
    auto& out=shape.mesh;
    shape.meshBounds=CGRectInset(CGPathGetPathBoundingBox(shape.path),-shape.width/2,-shape.width/2);
    static const auto circles=[] {
        std::vector<std::vector<CGPoint>> result(65);
        for(int n=8;n<=64;n++)for(int i=0;i<=n;i++)result[n].push_back({std::cos(i*2*M_PI/n),std::sin(i*2*M_PI/n)});
        return result;
    }();
    for(auto& points:path.contours){
        if(shape.width==0){
            // Triangle fans + stencil parity also handle concave contours/holes.
            out.reserve(out.size()+points.size()*3);
            for(size_t i=2;i<points.size();i++)metalTriangle(out,points[0],points[i-1],points[i]);
        } else if(points.size()>=2) {
            double radius=shape.width/2;
            int segments=std::clamp(int(std::ceil(M_PI/std::acos(std::max(-1.0,1-0.025/radius)))),8,64);
            auto& circle=circles[segments];
            out.reserve(out.size()+points.size()*12+segments*6);
            auto disk=[&](CGPoint p){
                for(int i=0;i<segments;i++)metalTriangle(out,p,{p.x+radius*circle[i].x,p.y+radius*circle[i].y},
                                                            {p.x+radius*circle[i+1].x,p.y+radius*circle[i+1].y});
            };
            CGPoint previous=CGPointZero;bool hasPrevious=false;
            for(size_t i=1;i<points.size();i++){
                auto a=points[i-1],b=points[i];double dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);
                if(length<1e-9)continue;
                double x=-dy*radius/length,y=dx*radius/length;
                CGPoint p={a.x+x,a.y+y},q={a.x-x,a.y-y},r={b.x+x,b.y+y},s={b.x-x,b.y-y};
                metalTriangle(out,p,q,r);metalTriangle(out,q,s,r);
                if(hasPrevious){
                    // A bevel approximates a smooth curve's tiny round join to
                    // the same subpixel tolerance; corners still use a disk.
                    double dot=(x*previous.x+y*previous.y)/(radius*radius);
                    if(dot<1-0.025/radius)disk(a);
                    else {
                        metalTriangle(out,a,{a.x+previous.x,a.y+previous.y},p);
                        metalTriangle(out,a,{a.x-previous.x,a.y-previous.y},q);
                    }
                }
                previous={x,y};hasPrevious=true;
            }
            disk(points.front());disk(points.back());
        }
    }
}
uint32_t metalQuad(CGRect r){
    uint32_t start=uint32_t(E->metalVertices.size());
    float x=CGRectGetMinX(r),y=CGRectGetMinY(r),right=CGRectGetMaxX(r),bottom=CGRectGetMaxY(r);
    for(auto p:{HamsterVertex{x,y},HamsterVertex{right,y},HamsterVertex{x,bottom},
                HamsterVertex{right,y},HamsterVertex{right,bottom},HamsterVertex{x,bottom}})E->metalVertices.push_back(p);
    return start;
}
void metalShape(Shape& shape,CGAffineTransform transform,uint32_t color,double alpha,uint32_t kind){
    prepareMesh(shape);
    if(shape.mesh.empty()||alpha<=0)return;
    uint32_t start=uint32_t(E->metalVertices.size());
    if(!std::isfinite(transform.a)||!std::isfinite(transform.b)||!std::isfinite(transform.c)||
       !std::isfinite(transform.d)||!std::isfinite(transform.tx)||!std::isfinite(transform.ty))return;
    E->metalVertices.reserve(E->metalVertices.size()+shape.mesh.size()+6);
    for(auto p:shape.mesh)E->metalVertices.push_back({float(p.x*transform.a+p.y*transform.c+transform.tx),
                                                   float(p.x*transform.b+p.y*transform.d+transform.ty)});
    uint32_t count=uint32_t(E->metalVertices.size())-start;
    uint32_t cover=metalQuad(CGRectInset(CGRectApplyAffineTransform(shape.meshBounds,transform),-0.5,-0.5));
    E->metalCommands.push_back({start,count,cover,kind,float(color>>16&255)/255,float(color>>8&255)/255,
                               float(color&255)/255,float(alpha)});
}
void prepareTextShape(V v,bool night,double alpha){
    prepareText(v,alpha,night);
    if(v.o->textShape)return;
    v.o->textShape=std::make_unique<Shape>(0,1);
    auto runs=CTLineGetGlyphRuns(v.o->textLine);
    for(CFIndex i=0;i<CFArrayGetCount(runs);i++){
        auto run=static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs,i));
        auto font=static_cast<CTFontRef>(CFDictionaryGetValue(CTRunGetAttributes(run),kCTFontAttributeName));
        CFIndex count=CTRunGetGlyphCount(run);
        std::vector<CGGlyph> glyphs(count);std::vector<CGPoint> positions(count);
        CTRunGetGlyphs(run,CFRangeMake(0,0),glyphs.data());CTRunGetPositions(run,CFRangeMake(0,0),positions.data());
        for(CFIndex j=0;j<count;j++)if(auto path=CTFontCreatePathForGlyph(font,glyphs[j],nullptr)){
            auto translation=CGAffineTransformMakeTranslation(positions[j].x,positions[j].y);
            CGPathAddPath(v.o->textShape->path,&translation,path);CGPathRelease(path);
        }
    }
}
void metalClip(V v,CGAffineTransform parent,double alpha,bool night){
    if(!v.o||!bool(G(v,P__visible))||bool(G(v,P_isMask))||bool(G(v,P__removed)))return;
    auto transform=CGAffineTransformTranslate(parent,number(G(v,P__x)),number(G(v,P__y)));
    transform=CGAffineTransformRotate(transform,number(G(v,P__rotation))*M_PI/180);
    transform=CGAffineTransformScale(transform,number(G(v,P__xscale))/100,number(G(v,P__yscale))/100);
    alpha*=number(G(v,P__alpha))/100;
    V mask=G(v,E->key("mask"));
    auto drawMask=[&](uint32_t kind){
        auto t=CGAffineTransformTranslate(transform,number(G(mask,P__x)),number(G(mask,P__y)));
        for(auto& shape:mask.o->graphics->fills)metalShape(*shape,t,0,1,kind);
    };
    bool masked=mask.o&&mask.o->graphics;
    if(masked)drawMask(2);
    if(v.o->graphics){
        bool bg=v.o==G(E->root,P_bg).o,wheel=v.o==G(E->root,P_wheel).o;
        bool water=v.o==G(G(E->root,P_water),P_mcWater).o;
        for(auto& s:v.o->graphics->fills){
            uint32_t color=night&&(bg||wheel)?0x354252:s->color;
            if(night&&water)color=(((color>>16&255)*3/5)<<16)|(((color>>8&255)*3/5)<<8)|((color&255)*3/5);
            metalShape(*s,transform,color,alpha*s->alpha,0);
        }
        for(auto& s:v.o->graphics->strokes)metalShape(*s,transform,night&&bg?0x8291A4:s->color,alpha*s->alpha,1);
    }
    V format=G(v,P_format);
    if(format.o){
        prepareTextShape(v,night,alpha);
        auto t=CGAffineTransformTranslate(transform,2,5+v.o->textAscent);
        t=CGAffineTransformScale(t,1,-1);
        metalShape(*v.o->textShape,t,night?0xB4BCC6:uint32_t(number(G(format,P_color))),alpha,0);
    }
    if(v.o->childrenOrderDirty){
        v.o->drawChildren=v.o->children;
        std::stable_sort(v.o->drawChildren.begin(),v.o->drawChildren.end(),[](V a,V b){return number(G(a,P__depth))<number(G(b,P__depth));});
        v.o->childrenOrderDirty=false;
    }
    for(auto child:v.o->drawChildren)metalClip(child,transform,alpha,night);
    if(masked)drawMask(3);
}
