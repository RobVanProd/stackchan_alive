# StackChan Speaker Audio Research

Date: 2026-07-07

## Why This Exists

During live voice-uplink validation, StackChan accepted a PC bridge text turn, received
`audio_stream_start`, then started receiving 4096-byte PCM chunks. The device made a harsh
sound and rebooted. The post-event serial log shows a fresh `[boot]` line and uptime under
one second, so the audio-downlink path is not merely low quality; it is currently unsafe on
the live robot.

Local firmware shape at the time:

- `platformio.ini` uses `M5Stack/M5Unified@0.2.17`.
- The live sink uses `M5.Speaker.playRaw()` for each bridge PCM chunk from a separate stream
  task.
- Wake/mic, display, Wi-Fi bridge, and speaker were all active around the response turn.
- The bridge sent PCM16 at 22050 Hz, 4096-byte chunks, up to 65536 bytes.

## Primary Source Findings

### M5Stack StackChan Arduino Docs

StackChan speaker docs say the speaker API is implemented by M5Unified `Speaker_Class` and
show only a simple `M5.Speaker.tone()` test for StackChan. Build requirements are CoreS3,
M5Stack board manager `>= 3.2.2`, and M5Unified `>= 0.2.11`.

Source: https://docs.m5stack.com/en/arduino/stackchan/speaker

StackChan mic docs are more important: the official mic/playback sample explicitly says the
microphone and speaker cannot be used at the same time. The sample starts in record mode by
calling `M5.Speaker.end(); M5.Mic.begin();`, then before playback waits for mic recording to
finish, calls `M5.Mic.end(); M5.Speaker.begin();`, plays with `M5.Speaker.playRaw()`, waits
until `M5.Speaker.isPlaying()` is false, then calls `M5.Speaker.end(); M5.Mic.begin();`.

Source: https://docs.m5stack.com/en/arduino/stackchan/mic

### M5Unified Speaker Class

M5Unified `speaker_config_t` defaults include `sample_rate = 48000`, `magnification = 16`,
`dma_buf_len = 256`, `dma_buf_count = 8`, `task_priority = 2`, and `task_pinned_core = ~0`.

For runtime-generated `playRaw()` data, M5Unified warns to use either three buffers in
sequence or two alternating buffers split in half. It also says that if noise is present,
increase the priority of the task generating the data.

Source: https://github.com/m5stack/M5Unified/blob/master/src/utility/Speaker_Class.hpp

### M5Stack Home Assistant / ESPHome StackChan Docs

The current M5Stack Home Assistant StackChan docs describe StackChan as CoreS3-based with a
1W speaker and dual microphones. They also warn that because of performance reasons, the
voice assistant firmware includes only basic voice, display, touch, and servo control.

The official ESPHome-style hardware mapping uses:

- I2S LRCLK GPIO33, BCLK GPIO34, MCLK GPIO0.
- ES7210 audio ADC at 16 kHz, 16-bit, mic gain 36.
- AW88298 audio DAC at 48 kHz.
- I2S speaker DOUT GPIO13 through AW88298.
- Speaker media player volume range 0.5 to 0.8.
- Announcement pipeline FLAC, 48 kHz, mono.

Source: https://docs.m5stack.com/en/homeassistant/kit/stackchan

### Comparable Project Evidence

The M5Stack CoreS3 ESPHome voice-assistant repo uses a managed `voice_assistant` pipeline
with a microphone and speaker assigned to the assistant, rather than arbitrary concurrent
Arduino speaker calls.

Source: https://github.com/m5stack/M5CoreS3-Esphome/blob/main/voice-assistant/m5stack-cores3.yaml

An ESPHome issue for a single-I2S-bus voice device describes the same class of problem:
ESPHome did not support a shared I2S bus at two different sample rates, and the workaround was
to free the I2S bus and start/stop microphone conditionally so mic and speaker are not running
at the same time. The author reports a crack when the mic restarts before speaker playback is
finished.

Source: https://github.com/esphome/esphome/issues/14016

## Conclusion

The best next approach is not to push more bytes faster or tune volume first. The first fix
is an audio-resource arbiter:

1. Never run M5Unified mic/wake capture and M5Unified speaker playback at the same time.
2. Treat the bridge turn as half-duplex:
   - Listen state: speaker ended, mic/wake running.
   - Response state: mic/wake stopped, speaker running.
   - Recovery state: wait for `M5.Speaker.isPlaying()` false, end speaker, delay briefly,
     restart mic/wake.
3. Normalize robot speaker audio to the board's stable path first:
   - Prefer 48 kHz, mono PCM/WAV for the speaker path because the AW88298 and ESPHome
     reference pipeline use 48 kHz.
   - Keep volume moderate, closer to the ESPHome 0.5-0.8 range than full-scale `255`.
4. Avoid bridge chunk playback until the arbiter is proven:
   - First play a tiny local `playWav()` asset with mic stopped.
   - Then play a complete buffered PCM/WAV response with mic stopped.
   - Only then reintroduce streaming chunks, using the M5Unified buffer guidance and queue
     telemetry.
5. Keep PC bridge audio downlink disabled by default until physical speaker playback passes a
   no-reboot, intelligible-audio test.

## Proposed Validation Ladder

1. Boot with smooth face, Wi-Fi bridge, wake/mic running, no audio downlink.
2. Run a local speaker-only WAV test that explicitly stops mic/wake first and restarts it
   afterward.
3. Run a full-buffer PC TTS playback test, not streaming, with 48 kHz mono PCM/WAV and mic
   stopped.
4. Run a one-turn wake -> upload -> STT -> brain -> response flow with response audio gated
   through the same half-duplex arbiter.
5. Soak for at least 10 minutes with face, wake, Wi-Fi, and periodic text turns, proving no
   display flicker, no reboot, no bridge timeout, and no audio resource deadlock.

## Implemented Guardrail

The bridge and firmware now default to a no-speaker-downlink mode:

- `bridge/lan_service.py` accepts `--disable-audio-downlink`; when enabled, TTS still
  produces response metadata and mouth/viseme beats, but binary `audio_stream_*` frames are
  withheld.
- `tools/start_pc_brain.ps1` adds `--disable-audio-downlink` by default. Use
  `-EnableAudioDownlink` only for an explicit supervised speaker validation.
- `src/main.cpp` adds `STACKCHAN_ENABLE_BRIDGE_AUDIO_DOWNLINK_PLAYBACK`, defaulting to `0`.
  Firmware can still account for incoming bridge audio streams, but bridge PCM chunks are not
  handed to `M5.Speaker.playRaw()` unless this flag is explicitly enabled.
- Runtime/debug telemetry now includes `bridge_downlink_playback_enabled`, so status checks
  can prove the speaker downlink is fenced off.

This is not the final voice-out design. It is the safety baseline before implementing the
half-duplex mic/speaker arbiter.

2026-07-07 hardware validation note: the buffered bridge downlink path completed clean
wake -> upload -> STT -> response -> PCM playback turns on the real robot with
`-EnableAudioDownlink`, `-SelectedVoiceStartBytes 65536`, and
`-DownlinkBinaryFrameDelayMs 20`. Keep the explicit enable flag, but use the faster pacing
for supervised voice-out runs.

## Conversation V2 Interruption Boundary

The 2026-07-12 pinned M5Unified source confirms why physical voice barge-in is a separate
qualification problem. CoreS3 configures both microphone RX and speaker TX on `I2S_NUM_1` with
shared BCLK GPIO34 and word-select GPIO33; mic data enters on GPIO14 and speaker data exits on
GPIO13. The production path intentionally pauses and ends `M5.Mic` before changing speaker
ownership/sample rate, then resumes the mic only after physical speaker drain.

The host bridge can now read a companion `utterance_start` or explicit `cancel` while Gemma/RVC is
running, terminate that process tree, and discard pending unsent audio. That is real host-side
interruption, but it does not prove that the onboard microphones can listen over active 48 kHz
speaker output. Do not remove the arbiter or start simultaneous M5Unified mic/speaker tasks by
assumption. A future physical experiment must first prove a supported same-clock full-duplex path
or another echo/reference design in a no-motion exact-image qualification, with clean audio, wake,
display, power, and reset evidence.
