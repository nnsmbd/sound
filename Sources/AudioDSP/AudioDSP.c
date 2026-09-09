#include "AudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <libproc.h>
int MixerProcessPath(int pid, char *buffer, uint32_t size) { return proc_pidpath(pid, buffer, size); }
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Realtime state requires lock-free atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Realtime counters require lock-free atomics");
struct MixerDSP {
    _Atomic(uint32_t) target, inputPeak, outputPeak;
    _Atomic(uint64_t) callbacks, faults;
    float current, step;
};
static uint32_t bits(float value) { uint32_t result; memcpy(&result, &value, 4); return result; }
static float value(uint32_t bitsValue) { float result; memcpy(&result, &bitsValue, 4); return result; }
static float bounded(float gain) { return isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 1; }
MixerDSP *MixerDSPCreate(float gain, double sampleRate) {
    MixerDSP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->current = bounded(gain); s->step = 1.0f / (float)(fmax(8000, sampleRate) * 0.01);
    atomic_init(&s->target, bits(s->current)); atomic_init(&s->inputPeak, 0); atomic_init(&s->outputPeak, 0);
    atomic_init(&s->callbacks, 0); atomic_init(&s->faults, 0); return s;
}
void MixerDSPDestroy(MixerDSP *s) { free(s); }
void MixerDSPSetGain(MixerDSP *s, float gain) { atomic_store_explicit(&s->target, bits(bounded(gain)), memory_order_relaxed); }
uint64_t MixerDSPCallbacks(MixerDSP *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
uint64_t MixerDSPFaults(MixerDSP *s) { return atomic_load_explicit(&s->faults, memory_order_relaxed); }
float MixerDSPInputPeak(MixerDSP *s) { return value(atomic_load_explicit(&s->inputPeak, memory_order_relaxed)); }
float MixerDSPOutputPeak(MixerDSP *s) { return value(atomic_load_explicit(&s->outputPeak, memory_order_relaxed)); }
OSStatus MixerDSPAttach(AudioObjectID device, MixerDSP *state, AudioDeviceIOProcID *proc) { return AudioDeviceCreateIOProcID(device, MixerDSPCallback, state, proc); }
// Supports Float32 stereo: one interleaved buffer or two mono buffers.
// No allocation, locks, Objective-C, Swift runtime, logging, or I/O here.
static int stereo(const AudioBufferList *list, float **left, float **right, uint32_t *stride, uint32_t *frames) {
    if (!list) return 0;
    if (list->mNumberBuffers == 1 && list->mBuffers[0].mNumberChannels == 2 && list->mBuffers[0].mData) {
        *left = list->mBuffers[0].mData; *right = *left + 1; *stride = 2; *frames = list->mBuffers[0].mDataByteSize / 8; return 1;
    }
    if (list->mNumberBuffers == 2 && list->mBuffers[0].mNumberChannels == 1 && list->mBuffers[1].mNumberChannels == 1 && list->mBuffers[0].mData && list->mBuffers[1].mData && list->mBuffers[0].mDataByteSize == list->mBuffers[1].mDataByteSize) {
        *left = list->mBuffers[0].mData; *right = list->mBuffers[1].mData; *stride = 1; *frames = list->mBuffers[0].mDataByteSize / 4; return 1;
    }
    return 0;
}
OSStatus MixerDSPCallback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    MixerDSP *s = context;
    if (!s || !output) return noErr;
    float *il, *ir, *ol, *orr; uint32_t ins, outs, inf, outf;
    if (!stereo(input, &il, &ir, &ins, &inf) || !stereo(output, &ol, &orr, &outs, &outf) || inf != outf) {
        for (uint32_t b = 0; b < output->mNumberBuffers; b++) if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        atomic_fetch_add_explicit(&s->faults, 1, memory_order_relaxed); return noErr;
    }
    float target = value(atomic_load_explicit(&s->target, memory_order_relaxed)), ip = 0, op = 0;
    for (uint32_t f = 0; f < inf; f++) {
        s->current += fmaxf(-s->step, fminf(s->step, target - s->current));
        float l = il[f * ins], r = ir[f * ins];
        if (!isfinite(l)) l = 0; if (!isfinite(r)) r = 0;
        ol[f * outs] = l * s->current; orr[f * outs] = r * s->current;
        ip = fmaxf(ip, fmaxf(fabsf(l), fabsf(r))); op = fmaxf(op, fmaxf(fabsf(ol[f * outs]), fabsf(orr[f * outs])));
    }
    atomic_store_explicit(&s->inputPeak, bits(ip), memory_order_relaxed); atomic_store_explicit(&s->outputPeak, bits(op), memory_order_relaxed);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed); return noErr;
}
