#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
typedef struct MixerDSP MixerDSP;
int MixerProcessPath(int pid, char *buffer, uint32_t size);
MixerDSP *MixerDSPCreate(float gain, double sampleRate);
void MixerDSPDestroy(MixerDSP *state);
void MixerDSPSetGain(MixerDSP *state, float gain);
uint64_t MixerDSPCallbacks(MixerDSP *state);
uint64_t MixerDSPFaults(MixerDSP *state);
float MixerDSPInputPeak(MixerDSP *state);
float MixerDSPOutputPeak(MixerDSP *state);
OSStatus MixerDSPAttach(AudioObjectID device, MixerDSP *state, AudioDeviceIOProcID *proc);
OSStatus MixerDSPCallback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
