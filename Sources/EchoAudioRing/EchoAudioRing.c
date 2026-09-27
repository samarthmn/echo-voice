#include "EchoAudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t first, host; uint32_t frames; } Descriptor;
struct EVAudioRing {
    _Alignas(64) _Atomic uint64_t write_index;
    _Alignas(64) _Atomic uint64_t read_index;
    _Alignas(64) _Atomic uint64_t read_frame;
    uint64_t write_frame; // producer-owned
    _Atomic uint64_t overflows, invalid;
    _Atomic uint64_t mute_host;
    uint32_t capacity, bytes, buffers, descriptors;
    unsigned char *samples;
    Descriptor *entries;
};
EVAudioRing *ev_ring_create(uint32_t frames,uint32_t bytes,uint32_t buffers,uint32_t descriptors) {
    uint64_t size=(uint64_t)frames*bytes*buffers;
    uint64_t metadata=(uint64_t)descriptors*sizeof(Descriptor);
    if (!frames || !bytes || !buffers || !descriptors || size+metadata>32u*1024u*1024u) return NULL;
    // C11 atomics are lock-free on supported arm64; never hide a mutex in capture.
    EVAudioRing *r=NULL;
    if(posix_memalign((void**)&r,64,sizeof(*r)))return NULL;
    memset(r,0,sizeof(*r));
    atomic_init(&r->write_index,0); atomic_init(&r->read_index,0);
    atomic_init(&r->read_frame,0); atomic_init(&r->overflows,0); atomic_init(&r->invalid,0);
    atomic_init(&r->mute_host,0);
    if(!atomic_is_lock_free(&r->write_index)){free(r);return NULL;}
    r->capacity=frames;r->bytes=bytes;r->buffers=buffers;r->descriptors=descriptors;
    r->samples=calloc(1,(size_t)size); r->entries=calloc(descriptors,sizeof(Descriptor));
    if(!r->samples || !r->entries){ev_ring_destroy(r);return NULL;} return r;
}
void ev_ring_destroy(EVAudioRing *r){if(r){free(r->samples);free(r->entries);free(r);}}
bool ev_ring_push(EVAudioRing *r,const AudioBufferList *input,uint32_t frames,uint64_t host) {
    // Gate admission before any validation, copying, allocation, or locking.
    // The consumer also trims a queued buffer that straddles this boundary.
    if(atomic_load_explicit(&r->mute_host,memory_order_acquire)!=0)return true;
    if(!frames || frames>r->capacity || !host || input->mNumberBuffers!=r->buffers)goto invalid;
    for(uint32_t b=0;b<r->buffers;b++)
        if(!input->mBuffers[b].mData || input->mBuffers[b].mDataByteSize<(uint64_t)frames*r->bytes)goto invalid;
    uint64_t w=atomic_load_explicit(&r->write_index,memory_order_relaxed);
    uint64_t read=atomic_load_explicit(&r->read_index,memory_order_acquire);
    uint64_t read_frame=atomic_load_explicit(&r->read_frame,memory_order_acquire);
    if(w-read>=r->descriptors || r->write_frame-read_frame+frames>r->capacity){atomic_fetch_add_explicit(&r->overflows,1,memory_order_relaxed);return false;}
    uint32_t offset=(uint32_t)(r->write_frame%r->capacity), first=r->capacity-offset;
    if(first>frames)first=frames;
    for(uint32_t b=0;b<r->buffers;b++){
        unsigned char *base=r->samples+(uint64_t)b*r->capacity*r->bytes;
        const unsigned char *source=input->mBuffers[b].mData;
        memcpy(base+(uint64_t)offset*r->bytes,source,(size_t)first*r->bytes);
        if(first<frames)memcpy(base,source+(uint64_t)first*r->bytes,(size_t)(frames-first)*r->bytes);
    }
    r->entries[w%r->descriptors]=(Descriptor){r->write_frame,host,frames};
    r->write_frame+=frames;
    atomic_store_explicit(&r->write_index,w+1,memory_order_release);return true;
invalid:atomic_fetch_add_explicit(&r->invalid,1,memory_order_relaxed);return false;
}
void ev_ring_mute_at(EVAudioRing *r,uint64_t host){atomic_store_explicit(&r->mute_host,host?host:1,memory_order_release);}
void ev_ring_unmute(EVAudioRing *r){atomic_store_explicit(&r->mute_host,0,memory_order_release);}
uint64_t ev_ring_mute_host(EVAudioRing *r){return atomic_load_explicit(&r->mute_host,memory_order_acquire);}
bool ev_ring_pop(EVAudioRing *r,AudioBufferList *output,uint32_t capacity,uint32_t *frames,uint64_t *host){
    uint64_t read=atomic_load_explicit(&r->read_index,memory_order_relaxed);
    if(read==atomic_load_explicit(&r->write_index,memory_order_acquire))return false;
    Descriptor d=r->entries[read%r->descriptors];
    if(output->mNumberBuffers!=r->buffers || capacity<d.frames)return false;
    for(uint32_t b=0;b<r->buffers;b++)if(!output->mBuffers[b].mData)return false;
    uint32_t offset=(uint32_t)(d.first%r->capacity),first=r->capacity-offset;
    if(first>d.frames)first=d.frames;
    for(uint32_t b=0;b<r->buffers;b++){
        const unsigned char *base=r->samples+(uint64_t)b*r->capacity*r->bytes;
        unsigned char *target=output->mBuffers[b].mData;
        memcpy(target,base+(uint64_t)offset*r->bytes,(size_t)first*r->bytes);
        if(first<d.frames)memcpy(target+(uint64_t)first*r->bytes,base,(size_t)(d.frames-first)*r->bytes);
        output->mBuffers[b].mDataByteSize=d.frames*r->bytes;
    }
    *frames=d.frames;*host=d.host;
    atomic_store_explicit(&r->read_frame,d.first+d.frames,memory_order_release);
    atomic_store_explicit(&r->read_index,read+1,memory_order_release);return true;
}
uint64_t ev_ring_overflows(EVAudioRing *r){return atomic_load_explicit(&r->overflows,memory_order_relaxed);}
uint64_t ev_ring_invalid(EVAudioRing *r){return atomic_load_explicit(&r->invalid,memory_order_relaxed);}
