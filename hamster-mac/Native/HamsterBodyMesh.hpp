// A closed, smooth union of the original torso and articulated head. Remeshing
// the volume avoids the self-intersections a sharply bent skinned neck creates.
namespace hamster_body {
struct Vec {
    double x=0,y=0,z=0;
    Vec operator+(Vec b)const{return {x+b.x,y+b.y,z+b.z};}
    Vec operator-(Vec b)const{return {x-b.x,y-b.y,z-b.z};}
    Vec operator*(double s)const{return {x*s,y*s,z*s};}
    Vec operator/(double s)const{return *this*(1/s);}
};
inline double dot(Vec a,Vec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline Vec cross(Vec a,Vec b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline double length(Vec a){return sqrt(dot(a,a));}
inline Vec unit(Vec a){double n=length(a);return n>1e-10?a/n:Vec{0,1,0};}
inline Vec point(HamsterRigPoint p){return {p.x,p.y,p.z};}
struct Profile {double x,cy,ry,rz;};
// Longitudinal sections of one continuous skin: independent dorsal/ventral
// curves and left/right flank widths, rather than one ellipsoid radius.
struct BodySection {double x,back,belly,right,left;};
inline double smoothMin(double a,double b,double k){
    double h=std::max(k-std::abs(a-b),0.0)/k;
    return std::min(a,b)-h*h*k*.25;
}
struct Field {
    Vec rear,front,head,axis,down,side,headForward,headDown,headSide,center;
    double torsoLength,runShape;
    double extension[4];
    std::array<BodySection,257> bodySections;
    std::array<Profile,257> headSections;
    explicit Field(void *engine){
        auto state=HamsterEngineGetSceneState(engine);
        rear=point(HamsterEngineGetRigPoint(engine,0));front=point(HamsterEngineGetRigPoint(engine,1));head=point(HamsterEngineGetRigPoint(engine,2));
        axis=unit(front-rear);side={sin(state.heading),0,-cos(state.heading)};
        down=unit(cross(side,axis));center=(rear+front)*.5;torsoLength=length(front-rear)*.5+20;
        double effort=state.onWheel?std::clamp((state.speed-.15)/.65,0.0,1.0):0;
        runShape=effort*effort*(3-2*effort);
        for(int leg=0;leg<4;leg++){
            Vec base=point(HamsterEngineGetRigPoint(engine,4+5*leg));
            Vec wrist=point(HamsterEngineGetRigPoint(engine,7+5*leg));
            extension[leg]=std::clamp(dot(wrist-base,axis)/24.0,-1.0,1.0);
        }
        double a=state.heading+state.headYaw,p=state.headPitch;
        headForward={cos(a)*cos(p),-sin(p),sin(a)*cos(p)};
        headDown={-cos(a)*sin(p),-cos(p),-sin(a)*sin(p)};
        headSide={sin(a),0,-cos(a)};
    }
    void prepare(){
        buildBodySections();
        static const auto lookup=[]{
            std::array<Profile,257> result;
            for(int i=0;i<=256;i++)result[i]=profile(-15+51*double(i)/256);
            return result;
        }();
        headSections=lookup;
    }
    Vec headLocal(Vec p)const{Vec d=p-head;return {dot(d,headForward),dot(d,headDown),dot(d,headSide)};}
    Vec headWorld(Vec p)const{return head+headForward*p.x+headDown*p.y+headSide*p.z;}
    void buildBodySections(){
        // Tail, rounded pelvis, back, waist, shoulder, neck. These curves are
        // authored separately; in particular the belly is not a mirrored back.
        static const BodySection rest[]={
            {-1,0,0,.2,.2},{-.96,-4.5,5,5.7,5.7},{-.85,-10,11,10.5,10.5},
            {-.65,-16,16,16.7,16.7},{-.38,-19.5,19.6,19.8,19.8},
            {0,-20,19.5,20,20},{.28,-18.5,17,18.5,18.5},{.55,-15,14,15.7,15.7},
            {.8,-9,9,10,10},{.96,-3,3,3.8,3.8},{1,0,0,.2,.2}};
        static const BodySection run[]={
            {-1,0,0,.2,.2},{-.96,-5,4,5,5},{-.85,-11,8.5,11,11},
            {-.65,-17.5,13.5,19.5,19.5},{-.38,-20.5,15.5,22,22},
            {0,-21.5,16,18.5,18.5},{.28,-20,15,15,15},{.55,-16.5,13.5,14.5,14.5},
            {.8,-9.5,8,9.5,9.5},{.96,-3,3,3,3},{1,0,0,.2,.2}};
        BodySection controls[11];
        for(int i=0;i<11;i++){
            auto mix=[&](double a,double b){return a+(b-a)*runShape;};
            controls[i]={rest[i].x,mix(rest[i].back,run[i].back),mix(rest[i].belly,run[i].belly),
                         mix(rest[i].right,run[i].right),mix(rest[i].left,run[i].left)};
            double hip=exp(-pow((controls[i].x+.5)/.32,2));
            double shoulder=exp(-pow((controls[i].x-.45)/.28,2));
            // A planted/stretched hindleg draws its own flank; the opposite hip
            // stays independent. All deformation comes from native joints.
            controls[i].right+=runShape*(.9*extension[2]*hip+.45*extension[0]*shoulder);
            controls[i].left +=runShape*(.9*extension[3]*hip+.45*extension[1]*shoulder);
            // Hindleg reach pulls the lateral flank, not a separate hanging
            // pouch underneath the pelvis. Keep the ventral curve continuous.
        }
        auto value=[&](int i,int component){const auto &s=controls[i];return component==0?s.back:component==1?s.belly:component==2?s.right:s.left;};
        auto slope=[&](int i,int c){
            if(i==0)return (value(1,c)-value(0,c))/(controls[1].x-controls[0].x);
            if(i==10)return (value(10,c)-value(9,c))/(controls[10].x-controls[9].x);
            double a=(value(i,c)-value(i-1,c))/(controls[i].x-controls[i-1].x);
            double b=(value(i+1,c)-value(i,c))/(controls[i+1].x-controls[i].x);
            return a*b>0?2*a*b/(a+b):0.0;
        };
        for(int j=0;j<=256;j++){
            double x=double(j)/128-1;int i=0;while(i<9&&x>controls[i+1].x)i++;
            double width=controls[i+1].x-controls[i].x,t=std::clamp((x-controls[i].x)/width,0.0,1.0),t2=t*t,t3=t2*t;
            auto interpolate=[&](int c){return value(i,c)*(2*t3-3*t2+1)+slope(i,c)*width*(t3-2*t2+t)
                +value(i+1,c)*(-2*t3+3*t2)+slope(i+1,c)*width*(t3-t2);};
            bodySections[j]={x,interpolate(0),interpolate(1),std::max(.2,interpolate(2)),std::max(.2,interpolate(3))};
        }
    }
    double torso(Vec p)const{
        Vec d=p-center;
        double x=dot(d,axis),y=dot(d,down),z=dot(d,side);
        double sample=std::clamp((x/torsoLength+1)*128,0.0,256.0);
        int i=std::min(255,int(sample));double t=sample-i;
        const auto &a=bodySections[i],&b=bodySections[i+1];
        auto mix=[&](double v,double w){return v+(w-v)*t;};
        double back=mix(a.back,b.back),belly=mix(a.belly,b.belly);
        double cy=(back+belly)*.5,ry=std::max(.2,(belly-back)*.5);
        double rz=z>=0?mix(a.right,b.right):mix(a.left,b.left);
        double radial=(sqrt(pow((y-cy)/ry,2)+pow(z/rz,2))-1)*std::min(ry,rz);
        return std::max(radial,std::abs(x)-torsoLength);
    }
    static Profile profile(double x){
        static const Profile p[]={
            {-15,0,.2,.2},{-10,0,11,12},{0,0,15,18},{6,-1,15.6,17},
            {13,-1.5,15,14},{23,0,12.5,8},{29,2,8.5,4.5},
            {34,3,3.5,1.6},{35.5,3.8,.4,.4},{36,3.8,.1,.1}};
        int i=0;while(i<8&&x>p[i+1].x)i++;
        double t=std::clamp((x-p[i].x)/(p[i+1].x-p[i].x),0.0,1.0);
        auto value=[](const Profile &s,int component){return component==0?s.cy:component==1?s.ry:s.rz;};
        auto slope=[&](int at,int component){
            if(at==0)return (value(p[1],component)-value(p[0],component))/(p[1].x-p[0].x);
            if(at==9)return (value(p[9],component)-value(p[8],component))/(p[9].x-p[8].x);
            double left=(value(p[at],component)-value(p[at-1],component))/(p[at].x-p[at-1].x);
            double right=(value(p[at+1],component)-value(p[at],component))/(p[at+1].x-p[at].x);
            return left*right>0?2*left*right/(left+right):0.0;
        };
        auto interpolate=[&](int component){
            double t2=t*t,t3=t2*t,width=p[i+1].x-p[i].x;
            return value(p[i],component)*(2*t3-3*t2+1)+slope(i,component)*width*(t3-2*t2+t)
                 +value(p[i+1],component)*(-2*t3+3*t2)+slope(i+1,component)*width*(t3-t2);
        };
        return {x,interpolate(0),std::max(.1,interpolate(1)),std::max(.1,interpolate(2))};
    }
    double skull(Vec world)const{
        Vec p=headLocal(world);
        double sample=std::clamp((p.x+15)*256/51,0.0,256.0);
        int i=std::min(255,int(sample));double t=sample-i;
        const auto &a=headSections[i],&b=headSections[i+1];
        auto mix=[&](double v,double w){return v+(w-v)*t;};
        Profile s={p.x,mix(a.cy,b.cy),mix(a.ry,b.ry),mix(a.rz,b.rz)};
        Vec q={(p.y-s.cy)/s.ry,p.z/s.rz,0};
        double radial=(length(q)-1)*std::min(s.ry,s.rz);
        return std::max(radial,std::max(-15-p.x,p.x-36));
    }
    double operator()(Vec p)const{return smoothMin(torso(p),skull(p),4.0);}
    Vec normal(Vec p)const{
        constexpr double h=.025;
        return unit({(*this)(p+Vec{h,0,0})-(*this)(p-Vec{h,0,0}),
                     (*this)(p+Vec{0,h,0})-(*this)(p-Vec{0,h,0}),
                     (*this)(p+Vec{0,0,h})-(*this)(p-Vec{0,0,h})});
    }
};
}

HamsterBodyField HamsterEngineBuildBodyField(void *engine){
    using namespace hamster_body;
    E=static_cast<Engine*>(engine);
    Field field(engine);
    std::vector<double> signature;
    signature.reserve(23);
    for(Vec p:{field.rear,field.front,field.head,field.headForward,field.headDown,field.side}){
        signature.push_back(p.x);signature.push_back(p.y);signature.push_back(p.z);
    }
    signature.push_back(field.runShape);
    for(double extension:field.extension)signature.push_back(extension*field.runShape);
    bool changed=signature.size()!=E->bodyFieldSignature.size();
    if(!changed)for(size_t i=0;i<signature.size();i++)if(std::abs(signature[i]-E->bodyFieldSignature[i])>(i<9?.025:.0008)){changed=true;break;}
    if(changed){
        field.prepare();
        E->bodyFieldSignature=signature;
        Vec extent={std::abs(field.axis.x)*field.torsoLength+24*(std::abs(field.down.x)+std::abs(field.side.x)),
                    std::abs(field.axis.y)*field.torsoLength+24*(std::abs(field.down.y)+std::abs(field.side.y)),
                    std::abs(field.axis.z)*field.torsoLength+24*(std::abs(field.down.z)+std::abs(field.side.z))};
        Vec lo=field.center-extent,hi=field.center+extent;
        for(double x:{-16.,37.})for(double y:{-18.,17.})for(double z:{-20.,20.}){
            Vec p=field.headWorld({x,y,z});
            lo={std::min(lo.x,p.x),std::min(lo.y,p.y),std::min(lo.z,p.z)};
            hi={std::max(hi.x,p.x),std::max(hi.y,p.y),std::max(hi.z,p.z)};
        }
        constexpr double step=1.6;
        lo={floor((lo.x-2)/step)*step,floor((lo.y-2)/step)*step,floor((lo.z-2)/step)*step};
        int nx=int(ceil((hi.x+2-lo.x)/step))+1,ny=int(ceil((hi.y+2-lo.y)/step))+1,nz=int(ceil((hi.z+2-lo.z)/step))+1;
        auto &out=E->bodyField;
        out.clear();out.reserve(524*4);
        auto put=[&](Vec p,double w=0){out.insert(out.end(),{float(p.x),float(p.y),float(p.z),float(w)});};
        put(field.center,field.torsoLength);put(field.axis);put(field.down);put(field.side);
        put(field.head);put(field.headForward);put(field.headDown);put(field.headSide);
        put(lo,step);put({double(nx),double(ny),double(nz)});
        for(const auto &s:field.bodySections)out.insert(out.end(),{float(s.back),float(s.belly),float(s.right),float(s.left)});
        for(const auto &s:field.headSections)out.insert(out.end(),{float(s.cy),float(s.ry),float(s.rz),0});
        ++E->bodyFieldGeneration;
    }
    return {E->bodyField.data(),uint32_t(E->bodyField.size()),E->bodyFieldGeneration};
}

HamsterBodyMesh HamsterEngineBuildBodyMesh(void *engine){
    using namespace hamster_body;
    E=static_cast<Engine*>(engine);
    Field field(engine);
    std::vector<double> signature;
    signature.reserve(23);
    for(Vec p:{field.rear,field.front,field.head,field.headForward,field.headDown,field.side}){
        signature.push_back(p.x);signature.push_back(p.y);signature.push_back(p.z);
    }
    signature.push_back(field.runShape);
    for(double extension:field.extension)signature.push_back(extension*field.runShape);
    bool changed=signature.size()!=E->bodySignature.size();
    if(!changed)for(size_t i=0;i<signature.size();i++)if(std::abs(signature[i]-E->bodySignature[i])>(i<9?.025:.0008)){changed=true;break;}
    auto result=[&](){return HamsterBodyMesh{E->bodyVertices.data(),uint32_t(E->bodyVertices.size()),E->bodyGeneration,
                                           E->bodyIndices.data(),uint32_t(E->bodyIndices.size())};};
    if(!changed)return result();
    field.prepare();
    E->bodySignature=signature;
    E->bodyVertices.clear();
    Vec extent={std::abs(field.axis.x)*field.torsoLength+24*(std::abs(field.down.x)+std::abs(field.side.x)),
                std::abs(field.axis.y)*field.torsoLength+24*(std::abs(field.down.y)+std::abs(field.side.y)),
                std::abs(field.axis.z)*field.torsoLength+24*(std::abs(field.down.z)+std::abs(field.side.z))};
    Vec lo=field.center-extent,hi=field.center+extent;
    for(double x:{-16.,37.})for(double y:{-18.,17.})for(double z:{-20.,20.}){
        Vec p=field.headWorld({x,y,z});
        lo={std::min(lo.x,p.x),std::min(lo.y,p.y),std::min(lo.z,p.z)};
        hi={std::max(hi.x,p.x),std::max(hi.y,p.y),std::max(hi.z,p.z)};
    }
    constexpr double step=1.6;
    lo={floor((lo.x-2)/step)*step,floor((lo.y-2)/step)*step,floor((lo.z-2)/step)*step};
    int nx=int(ceil((hi.x+2-lo.x)/step))+1,ny=int(ceil((hi.y+2-lo.y)/step))+1,nz=int(ceil((hi.z+2-lo.z)/step))+1;
    auto index=[&](int x,int y,int z){return (z*ny+y)*nx+x;};
    std::vector<float> grid(size_t(nx)*ny*nz);
    for(int z=0;z<nz;z++)for(int y=0;y<ny;y++)for(int x=0;x<nx;x++)grid[index(x,y,z)]=float(field(lo+Vec{double(x),double(y),double(z)}*step));
    auto marking=[](double x,double y,const double polygon[][2],int count){
        bool inside=false;double nearest=1e9;
        for(int i=0,j=count-1;i<count;j=i++){
            double ax=polygon[j][0],ay=polygon[j][1],bx=polygon[i][0],by=polygon[i][1];
            if((ay>y)!=(by>y) && x<(bx-ax)*(y-ay)/(by-ay)+ax)inside=!inside;
            double dx=bx-ax,dy=by-ay,l2=dx*dx+dy*dy;
            double t=l2>1e-9?std::clamp(((x-ax)*dx+(y-ay)*dy)/l2,0.0,1.0):0;
            double ex=x-ax-t*dx,ey=y-ay-t*dy;nearest=std::min(nearest,sqrt(ex*ex+ey*ey));
        }
        return std::clamp(.5+(inside?nearest:-nearest)/.35,0.0,1.0);
    };
    static const double sideMark[7][2]={{32,1},{35,2},{33,9},{25,12},{3,11},{8,6},{23,6}};
    static const double frontMark[7][2]={{3,1},{0,2},{0,9},{0,12},{8,11},{15,6},{8,6}};
    struct SkinVertex {Vec p,neighbors,normal;double weight=0;};
    std::vector<SkinVertex> skin;
    auto &triangles=E->bodyIndices;
    triangles.clear();
    // Each lattice point owns seven forward edges (axes and diagonals).
    // Direct addressing avoids a hash lookup/allocation for every triangle corner.
    std::vector<uint32_t> edgeVertices(grid.size()*7,UINT32_MAX);
    skin.reserve(24000);triangles.reserve(72000);
    auto emit=[&](uint32_t a,uint32_t b,uint32_t c,Vec outward){
        Vec normal=cross(skin[b].p-skin[a].p,skin[c].p-skin[a].p);
        if(dot(normal,outward)<0)std::swap(b,c);
        uint32_t indices[]={a,b,c};
        double area=length(normal);
        for(int i=0;i<3;i++){
            triangles.push_back(indices[i]);
            auto &v=skin[indices[i]];
            v.neighbors=v.neighbors+(skin[indices[(i+1)%3]].p+skin[indices[(i+2)%3]].p)*(.5*area);
            v.weight+=area;
        }
    };
    static const int corners[8][3]={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}};
    static const int tetra[6][4]={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}};
    for(int z=0;z<nz-1;z++)for(int y=0;y<ny-1;y++)for(int x=0;x<nx-1;x++){
        Vec p[8];double d[8];uint32_t gridIndex[8];int insideCount=0;
        for(int i=0;i<8;i++){
            int xx=x+corners[i][0],yy=y+corners[i][1],zz=z+corners[i][2];
            gridIndex[i]=uint32_t(index(xx,yy,zz));
            d[i]=grid[gridIndex[i]];insideCount+=d[i]<0;
        }
        if(insideCount==0||insideCount==8)continue;
        // Most cells are empty or internal: only surface cells need positions.
        for(int i=0;i<8;i++)p[i]=lo+Vec{double(x+corners[i][0]),double(y+corners[i][1]),double(z+corners[i][2])}*step;
        auto edge=[&](int a,int b){
            int direction=std::abs(corners[a][0]-corners[b][0])+2*std::abs(corners[a][1]-corners[b][1])+4*std::abs(corners[a][2]-corners[b][2]);
            uint32_t key=std::min(gridIndex[a],gridIndex[b])*7+uint32_t(direction-1);
            auto &cached=edgeVertices[key];
            if(cached!=UINT32_MAX)return cached;
            // Resolve an intersection once, not once per incident triangle.
            double t=d[a]/(d[a]-d[b]);
            cached=uint32_t(skin.size());
            skin.push_back({p[a]+(p[b]-p[a])*t,{},{},0});
            return cached;
        };
        for(auto &t:tetra){
            int in[4],out[4],ni=0,no=0;
            for(int a:t){if(d[a]<0)in[ni++]=a;else out[no++]=a;}
            Vec inside,outside;
            for(int i=0;i<ni;i++)inside=inside+p[in[i]];
            for(int i=0;i<no;i++)outside=outside+p[out[i]];
            Vec outward=ni&&no?outside/double(no)-inside/double(ni):Vec{};
            if(ni==1)emit(edge(in[0],out[0]),edge(in[0],out[1]),edge(in[0],out[2]),outward);
            else if(ni==3)emit(edge(out[0],in[0]),edge(out[0],in[1]),edge(out[0],in[2]),outward);
            else if(ni==2){
                uint32_t a=edge(in[0],out[0]),b=edge(in[0],out[1]),c=edge(in[1],out[0]),d0=edge(in[1],out[1]);
                emit(a,b,c,outward);emit(b,d0,c,outward);
            }
        }
    }
    // Weld shared edges, then relax only a fraction of one grid cell. This removes
    // tetrahedral ripples at bent leg roots without changing the authored curves.
    for(auto &v:skin)if(v.weight>1e-12)v.p=v.p*.85+(v.neighbors/v.weight)*.15;
    for(size_t i=0;i<triangles.size();i+=3){
        auto &a=skin[triangles[i]],&b=skin[triangles[i+1]],&c=skin[triangles[i+2]];
        Vec normal=cross(b.p-a.p,c.p-a.p);
        a.normal=a.normal+normal;b.normal=b.normal+normal;c.normal=c.normal+normal;
    }
    for(auto &v:skin)v.normal=unit(v.normal);
    // Export welded vertices once. Skin and outline share this indexed surface.
    for(const auto &vertex:skin){
        Vec p=vertex.p,n=vertex.normal,local=field.headLocal(p);
        double coat=0;
        if(local.x>0&&local.x<36&&local.y>-.5&&local.y<13){
            double front=std::clamp((dot(n,field.headForward)-std::abs(dot(n,field.headSide))+.2)/.4,0.0,1.0);
            coat=marking(local.x,local.y,sideMark,7)*(1-front)+marking(std::abs(local.z),local.y,frontMark,7)*front;
            if(coat>0)coat*=std::clamp((field.torso(p)-field.skull(p)+2)/4,0.0,1.0);
        }
        E->bodyVertices.push_back({float(p.x),float(p.y),float(p.z),float(n.x),float(n.y),float(n.z),float(coat),.5f});
    }
    ++E->bodyGeneration;
    return result();
}
