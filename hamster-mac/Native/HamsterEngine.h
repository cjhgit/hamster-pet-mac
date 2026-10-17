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
void HamsterEngineStep(void *engine, double elapsedMilliseconds);
void HamsterEngineMouse(void *engine, double x, double y, int action);
void HamsterEngineDraw(void *engine, CGContextRef context);
#ifdef __cplusplus
}
#endif

#endif // HAMSTER_ENGINE_H
