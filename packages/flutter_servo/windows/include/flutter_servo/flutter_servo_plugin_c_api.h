#ifndef FLUTTER_SERVO_PLUGIN_C_API_H_
#define FLUTTER_SERVO_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_SERVO_EXPORT __declspec(dllexport)
#else
#define FLUTTER_SERVO_EXPORT __declspec(dllimport)
#endif

extern "C" FLUTTER_SERVO_EXPORT void
FlutterServoPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif
