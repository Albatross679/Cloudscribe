// C interface to the WebRTC echo canceller (AEC3), callable from Swift.
//
// Audio is mono float in [-1, 1], in 10 ms frames of sample_rate_hz / 100
// samples. Only echo cancellation is enabled: no noise suppression, gain
// control or high-pass filter, so the microphone keeps its own level.
#ifndef ECHO_CANCELLER_H
#define ECHO_CANCELLER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EchoCanceller EchoCanceller;

/// Returns NULL if the sample rate is not supported.
EchoCanceller *echo_canceller_create(int sample_rate_hz);

/// Feeds one frame of the audio sent to the speakers, then removes its echo
/// from one frame of microphone audio in place. Returns 0 on success.
int echo_canceller_process(EchoCanceller *canceller, const float *speaker, float *microphone);

void echo_canceller_destroy(EchoCanceller *canceller);

#ifdef __cplusplus
}
#endif

#endif
