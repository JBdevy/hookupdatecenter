#pragma once
// Signalsmith's FFT backend and optional DSP features change its C++ object
// layout. Live voices and offline renders must include exactly the same type.
#if defined(__APPLE__)
#define SIGNALSMITH_USE_ACCELERATE 1
#define CATLIVE_SIGNALSMITH_NEUTRAL_SYNTHESIS 1
#endif
#define CATLIVE_SIGNALSMITH_NEUTRAL_WARMUP 1
#define CATLIVE_SIGNALSMITH_BATCH_OUTPUT 1
#define CATLIVE_SIGNALSMITH_STATE_COPY 1
#include "../../Windows/ThirdParty/Signalsmith/signalsmith-stretch.h"
