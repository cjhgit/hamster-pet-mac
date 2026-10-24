// Run with clang++ -std=c++17 -O2 scripts/verify-soft-body.cpp
//   -framework CoreGraphics -framework CoreText -framework CoreFoundation -o /tmp/verify-soft-body
#include "ui-test-bridge.cpp"
#include <cassert>
#include <cstdio>

int main(){
    void *engine=HamsterEngineCreate(11042);
    HamsterEngineStart(engine);
    HamsterTestConfigureScenario(2,0);
    V h=G(E->root,P_ham);
    auto sections=[&](double phase,double speed){
        R(h,P_angVel)=V(phase);R(h,P_legVel)=V(speed);
        hamster_body::Field f(engine);f.prepare();return f.bodySections;
    };
    auto rest=sections(0,0);
    auto still=sections(1,0);
    for(int i=0;i<=256;i++){
        assert(rest[i].back==still[i].back && rest[i].belly==still[i].belly);
    }
    double minimum=1e9,maximum=-1e9;
    double backMin=1e9,backMax=-1e9,bellyMin=1e9,bellyMax=-1e9;
    for(int frame=0;frame<=120;frame++){
        double phase=2*M_PI*frame/120;
        auto body=sections(phase,.8);
        double center=(body[128].back+body[128].belly)*.5;
        minimum=std::min(minimum,center);maximum=std::max(maximum,center);
        backMin=std::min(backMin,body[128].back);backMax=std::max(backMax,body[128].back);
        bellyMin=std::min(bellyMin,body[128].belly);bellyMax=std::max(bellyMax,body[128].belly);
        for(const auto &s:body){
            assert(std::isfinite(s.back) && std::isfinite(s.belly));
            assert(s.belly>=s.back && s.right>0 && s.left>0);
        }
        for(int end:{0,256}){
            assert(std::abs(body[end].back)<1e-8 && std::abs(body[end].belly)<1e-8);
        }
        if(frame){
            auto previous=sections(phase-2*M_PI/120,.8);
            assert(std::abs(body[128].back-previous[128].back)<.4);
        }
    }
    assert(backMax-backMin<.35); // Keep the back steady throughout a full stride.
    assert(bellyMax-bellyMin>2); // Retain softness in the belly instead.
    sections(0,.8);
    auto a=HamsterEngineBuildBodyField(engine);
    uint32_t generation=a.generation;
    assert(HamsterEngineBuildBodyField(engine).generation==generation);
    sections(.5,.8);
    assert(HamsterEngineBuildBodyField(engine).generation>generation);
    auto mesh=HamsterEngineBuildBodyMesh(engine);
    assert(mesh.vertexCount>0 && mesh.indexCount>0);
    generation=mesh.generation;
    assert(HamsterEngineBuildBodyMesh(engine).generation==generation);
    sections(1,.8);
    assert(HamsterEngineBuildBodyMesh(engine).generation>generation);
    printf("Soft body: smooth cycle, %.2f waist flex, stable endpoints, CPU/GPU field cache invalidation passed\n",maximum-minimum);
    HamsterEngineDestroy(engine);
}
