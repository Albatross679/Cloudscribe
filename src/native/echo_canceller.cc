#include "echo_canceller.h"

#include <memory>
#include <optional>

#include <modules/audio_processing/aec3/echo_canceller3.h>
#include <modules/audio_processing/include/audio_processing.h>

namespace {

// Builds AEC3 itself, tuned for dictation, where the person speaking over
// the playback matters more than the last trace of echo. Measured on a real
// MacBook speaker echo with a second voice mixed in at the echo's level, APM's
// own AEC3 build kept 1 to 11 of that voice's 14 words, this one 5 to 14,
// and echo alone still transcribed as nothing.
class EchoCanceller3Factory : public webrtc::EchoControlFactory {
 public:
  std::unique_ptr<webrtc::EchoControl> Create(int sample_rate_hz, int num_render_channels,
                                              int num_capture_channels) override {
    webrtc::EchoCanceller3Config config;
    // Treat the microphone as someone talking once it is louder than the
    // estimated echo (default: 4 times louder) for 16 ms (default: 48 ms),
    // which switches the suppressor to its gentler near-end setting.
    config.suppressor.dominant_nearend_detection.enr_threshold = 1.f;
    config.suppressor.dominant_nearend_detection.trigger_threshold = 4;
    return std::make_unique<webrtc::EchoCanceller3>(config, std::nullopt, sample_rate_hz,
                                                    num_render_channels, num_capture_channels);
  }
};

}  // namespace

struct EchoCanceller {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
};

EchoCanceller *echo_canceller_create(int sample_rate_hz) {
  if (sample_rate_hz < 8000 || sample_rate_hz > 384000 || sample_rate_hz % 100 != 0) {
    return nullptr;
  }
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  rtc::scoped_refptr<webrtc::AudioProcessing> apm =
      webrtc::AudioProcessingBuilder()
          .SetConfig(config)
          .SetEchoControlFactory(std::make_unique<EchoCanceller3Factory>())
          .Create();
  if (!apm) {
    return nullptr;
  }
  return new EchoCanceller{apm, webrtc::StreamConfig(sample_rate_hz, 1)};
}

int echo_canceller_process(EchoCanceller *canceller, const float *speaker, float *microphone) {
  // The render output is unused, but APM writes it, so give it scratch space.
  float render_out[3840];
  if (canceller->stream.num_frames() > sizeof(render_out) / sizeof(render_out[0])) {
    return -1;
  }
  const float *render_in[] = {speaker};
  float *render_dest[] = {render_out};
  int status = canceller->apm->ProcessReverseStream(render_in, canceller->stream,
                                                    canceller->stream, render_dest);
  if (status != webrtc::AudioProcessing::kNoError) {
    return status;
  }
  const float *capture_in[] = {microphone};
  float *capture_dest[] = {microphone};
  return canceller->apm->ProcessStream(capture_in, canceller->stream, canceller->stream,
                                       capture_dest);
}

void echo_canceller_destroy(EchoCanceller *canceller) {
  delete canceller;
}
