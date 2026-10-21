#pragma once
#include <stdbool.h>

// Only the isolated macOS 27 runtime installs this process transport.
bool VZModernInstallTaskTransport(void);
