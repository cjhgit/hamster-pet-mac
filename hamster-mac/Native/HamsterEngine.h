#ifndef HAMSTER_ENGINE_H
#define HAMSTER_ENGINE_H
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *HamsterEngineCreate(uint32_t seed);
void HamsterEngineDestroy(void *engine);
void HamsterEngineSetColor(void *engine, const char *name, uint32_t color);
void HamsterEngineStart(void *engine);
void HamsterEngineSetWatermarkVisible(void *engine, int visible);
void HamsterEngineStep(void *engine, double elapsedMilliseconds);
int HamsterEngineGetFrameCount(void *engine);
double HamsterEngineGetElapsedMilliseconds(void *engine);
// Read-only simulation data. World geometry is built independently by SceneKit.
typedef struct {
    double x, y, heading, posture, headYaw, headPitch, wheelAngle, legPhase, eyeOpen, waterLevel;
    int onWheel, sleeping, eating, cleaning, moving;
    double rotation, speed;
} HamsterSceneState;
typedef struct { double x, y, z; int curve; } HamsterRigPoint;
// 0 rear torso, 1 front torso, 2 head, 3 tail. Then FR, FL, RR, RL,
// five points each: front attachment, side attachment, rear attachment, wrist, toe.
HamsterRigPoint HamsterEngineGetRigPoint(void *engine, int index);
// Original quadratic feature contours in 3D: eyes 0/1, ears 2/3.
int HamsterEngineGetRigFeatureCount(void *engine, int feature);
HamsterRigPoint HamsterEngineGetRigFeaturePoint(void *engine, int feature, int index);
typedef struct { float x,y,z,nx,ny,nz,u,v; } HamsterBodyVertex;
typedef struct { const HamsterBodyVertex *vertices; uint32_t vertexCount, generation; } HamsterBodyMesh;
HamsterBodyMesh HamsterEngineBuildBodyMesh(void *engine);
typedef struct { double x, y, radius; int visible; } HamsterSceneFood;
HamsterSceneState HamsterEngineGetSceneState(void *engine);
uint32_t HamsterEngineGetSceneColor(void *engine, const char *name);
int HamsterEngineGetSceneFoodCount(void *engine);
HamsterSceneFood HamsterEngineGetSceneFood(void *engine, int index);
void HamsterEngineMouse(void *engine, double x, double y, int action);
// Triangle geometry is owned by the engine and valid until the next export/step.
// kind: 0 = even-odd fill, 1 = stroke union, 2/3 = mask begin/end, 4 = solid quad.
typedef struct { float x, y; } HamsterVertex;
typedef struct {
    uint32_t firstVertex, vertexCount, coverVertex, kind;
    float red, green, blue, alpha;
} HamsterDrawCommand;
typedef struct {
    const HamsterVertex *vertices;
    const HamsterDrawCommand *commands;
    uint32_t vertexCount, commandCount;
} HamsterMetalFrame;
HamsterMetalFrame HamsterEngineBuildMetalFrame(void *engine, int night);
void HamsterEnginePurgeRenderCache(void *engine);
void HamsterEngineDraw(void *engine, CGContextRef context);
void HamsterEngineDrawWithTheme(void *engine, CGContextRef context, int night);
#ifdef __cplusplus
}
#endif

#endif // HAMSTER_ENGINE_H
