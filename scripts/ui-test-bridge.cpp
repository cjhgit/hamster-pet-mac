// This diagnostic bridge is compiled only by snapshot-native.sh, never by Xcode.
#include "../hamster-mac/Native/HamsterEngine.cpp"
extern "C" int HamsterTestFoodCount(){return int(number(G(G(E->root,P_freshFood),P_length)));}
extern "C" int HamsterTestDragging(){return bool(G(G(E->root,P_food),P_drag));}
extern "C" double HamsterTestFoodX(){return number(G(G(G(E->root,P_food),P_pos),P_x));}
extern "C" void HamsterTestStep(){HamsterEngineStep(E,1000.0/30);}

extern "C" int HamsterTestWatermarkVisible(){return bool(G(G(E->root,P_txt),P__visible));}
extern "C" HamsterSceneState HamsterEngineGetSceneStateForTest(){return HamsterEngineGetSceneState(E);}
static V testIdleDecision(V,const Args&){return {};}
extern "C" void HamsterTestConfigureScenario(int scenario,double heading){
    V h=G(E->root,P_ham);
    R(h,P_decideWhatToDo)=function(scenario==0?testIdleDecision:Hamster_decideWhatToDo);
    R(h,P_runAt)=V(1e9);
    E->timers.clear();
    R(E->root,P_mouseActive)=V(false);R(E->root,P_mouseActiveUntil)=V(-1);
    R(h,P__x)=V(180);R(h,P__y)=V(182);R(h,P_ang)=V(heading);R(h,P__rotation)=V(0);
    R(h,P_headAng)=V(0);call(h,P_tiltHead,{V(0)});
    R(h,P_isOnWheel)=V(false);R(h,P_getOnWheel)=V(false);R(h,P_getOffWheel)=V(false);
    R(h,P_sleeping)=V(false);R(h,P_sleepAtDest)=V(false);R(h,P_eating)=V(false);
    R(h,P_cleaning)=V(false);R(h,P_drinking)=V(false);R(h,P_isTired)=V(false);
    R(h,P_eyesCloseFrac)=V(1);R(h,P_eyesClosed)=V(false);
    R(h,P_dest)=V();R(h,P_goingTo)=G(G(E->globals,P_Hamster),P_NOTHING);
    R(h,P_gotoRandomAt)=V(1e9);R(h,P_lookRandomAt)=V(1e9);R(h,P_waterLevel)=V(10);
    R(h,P_lookHere)=object({{P_x,V(180+cos(heading)*80)},{P_y,V(155)}});
    call(h,P_stand,{V(2*M_PI)});
    if(scenario==1 || scenario==7){
        R(h,P__x)=V(scenario==7?220:65);
        R(h,P_dest)=object({{P_x,V(scenario==7?40:255)},{P_y,V(205)}});
        R(h,P_lookHere)=G(h,P_dest);R(h,P_goingTo)=G(G(E->globals,P_Hamster),P_RANDOM);
    }else if(scenario==2){
        R(h,P__x)=V(167);R(h,P__y)=V(175);R(h,P_isOnWheel)=V(true);
        R(h,P_tarWheelAng)=V(heading<M_PI/2?0:M_PI);R(h,P_legVel)=V(.15);
        R(h,P_angVel)=V(0);R(h,P_restAt)=V(1e9);R(h,P_maxRun)=V(1e9);
    }else if(scenario==3){
        R(h,P_eating)=V(true);R(h,P_foodInMouth)=V(false);
        R(h,P_food)=call(G(E->globals,P_Food),P_create,{h,G(h,P_foodDepth),object({{P_color,G(E->root,P_foodColor)},{P_radius,V(4)}})});
    }else if(scenario==4){
        R(h,P_cleaning)=V(true);R(h,P_stopCleanAt)=V(1e9);
    }else if(scenario==5){
        R(h,P__x)=V(94);R(h,P_ang)=V(M_PI);R(h,P_waterLevel)=V(0);
        R(h,P_dest)=G(E->root,P_waterPos);R(h,P_lookHere)=G(h,P_dest);
        R(h,P_goingTo)=G(G(E->globals,P_Hamster),P_WATER);
        R(h,P_stopDrinkAt)=V(1e9);R(h,P_drinkStartAt)=V(0);
    }else if(scenario==6){
        R(h,P_sleepAtDest)=V(true);call(h,P_sleep,{});
    }
    for(int i=0;i<30;i++)HamsterEngineStep(E,1000.0/30);
}
extern "C" void HamsterTestSet3DPose(int pose){HamsterTestConfigureScenario(pose==1?3:pose==2?4:0,M_PI/2);}
extern "C" void HamsterTestDrawHamster(CGContextRef context){
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextSetFillColorSpace(context,space);CGContextSetStrokeColorSpace(context,space);CGColorSpaceRelease(space);
    drawClip(G(E->root,P_ham),context,1,false);
}
extern "C" HamsterRigPoint HamsterTestRigPoint(int index){return HamsterEngineGetRigPoint(E,index);}

extern "C" void HamsterTestRetarget(double x,double y){
    V h=G(E->root,P_ham);R(h,P_dest)=object({{P_x,V(x)},{P_y,V(y)}});
    R(h,P_lookHere)=G(h,P_dest);R(h,P_goingTo)=G(G(E->globals,P_Hamster),P_RANDOM);
    R(h,P_cleaning)=V(false);
}
