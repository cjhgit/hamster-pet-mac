#include "../hamster-mac/Native/HamsterEngine.h"
int HamsterTestFoodCount(void);
int HamsterTestDragging(void);
double HamsterTestFoodX(void);
void HamsterTestStep(void);

int HamsterTestWatermarkVisible(void);
HamsterSceneState HamsterEngineGetSceneStateForTest(void);
void HamsterTestSet3DPose(int pose);

void HamsterTestConfigureScenario(int scenario, double heading);
void HamsterTestDrawHamster(CGContextRef context);
HamsterRigPoint HamsterTestRigPoint(int index);
void HamsterTestRetarget(double x, double y);
