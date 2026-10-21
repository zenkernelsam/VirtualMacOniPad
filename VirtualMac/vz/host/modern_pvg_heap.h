#include <stdbool.h>

// Complete the macOS 27 legacy heap resource's missing buffer accessor using
// the actual offset-zero buffer already owned by Apple's implementation. Also
// expose that measured base on marked heaps whose old driver reports zero.
// Call only inside the separately launched modern GPU task process.
bool VZModernInstallHeapCompatibility(void);
