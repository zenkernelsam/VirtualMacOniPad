#ifndef VZ_MODERN_PVG_FAULT_OBSERVATION_H
#define VZ_MODERN_PVG_FAULT_OBSERVATION_H
#include <stdbool.h>

// Optional app-private observation. Call after the actual PVG/task classes are
// registered. No constructor, device access, GPU work, reply/status mutation,
// stamp/event write, process signal, timeout or recovery is provided here.
// Backend must be 27. A present VZ_PVG_FAULT_OBSERVE enables only when exactly
// "1"; absent env uses the validated app-private diagnostics/enabled file.
// Default off. Removing the flag then restarting the guest ends observation;
// no live method uninstallation or GPU recovery occurs.
bool VZModernInstallFaultObservation(void);

#endif
