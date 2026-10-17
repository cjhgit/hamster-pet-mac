// This diagnostic bridge is compiled only by snapshot-native.sh, never by Xcode.
#include "../hamster-mac/Native/HamsterEngine.cpp"
extern "C" int HamsterTestFoodCount(){return int(number(G(G(E->root,P_freshFood),P_length)));}
extern "C" int HamsterTestDragging(){return bool(G(G(E->root,P_food),P_drag));}
extern "C" double HamsterTestFoodX(){return number(G(G(G(E->root,P_food),P_pos),P_x));}
extern "C" void HamsterTestStep(){HamsterEngineStep(E,1000.0/30);}

extern "C" int HamsterTestWatermarkVisible(){return bool(G(G(E->root,P_txt),P__visible));}
