#ifndef ECHO_AUDIO_RING_H
#define ECHO_AUDIO_RING_H
#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>
typedef struct EVAudioRing EVAudioRing;
EVAudioRing *ev_ring_create(uint32_t frames, uint32_t bytes_per_frame, uint32_t buffers, uint32_t descriptors);
void ev_ring_destroy(EVAudioRing *ring);
bool ev_ring_push(EVAudioRing *ring, const AudioBufferList *input, uint32_t frames, uint64_t host);
bool ev_ring_pop(EVAudioRing *ring, AudioBufferList *output, uint32_t capacity, uint32_t *frames, uint64_t *host);
void ev_ring_mute_at(EVAudioRing *ring, uint64_t host);
void ev_ring_unmute(EVAudioRing *ring);
uint64_t ev_ring_mute_host(EVAudioRing *ring);
uint64_t ev_ring_overflows(EVAudioRing *ring);
uint64_t ev_ring_invalid(EVAudioRing *ring);
#endif
