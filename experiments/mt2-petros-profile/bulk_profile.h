/* Opt-in polling-owner counters. No file contents, allocation, extra USB
 * transaction or delay. uint32 counters wrap; compare nearby snapshots modulo
 * 2^32. These observations diagnose throughput, not input latency acceptance. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint32_t rx_bytes, rx_packets, tx_bytes, tx_batches, completed;
    uint32_t multi, queue_max, submit_failed, resets;
} wk_bulk_profile_port;
static wk_bulk_profile_port wk_bulk_profile_ports[2];
static uint32_t wk_bulk_profile_loops, wk_bulk_profile_gap, wk_bulk_profile_last;
static bool wk_bulk_profile_started;

static void wk_bulk_profile_loop(uint32_t ticks) {
    if(wk_bulk_profile_started) {
        uint32_t gap=ticks-wk_bulk_profile_last;
        if(gap>wk_bulk_profile_gap)wk_bulk_profile_gap=gap;
    }
    wk_bulk_profile_started=true;wk_bulk_profile_last=ticks;wk_bulk_profile_loops++;
}
static void wk_bulk_profile_rx(unsigned p,size_t bytes) {
    wk_bulk_profile_ports[p].rx_bytes+=(uint32_t)bytes;
    wk_bulk_profile_ports[p].rx_packets++;
}
static void wk_bulk_profile_submit(unsigned p,unsigned cells,unsigned queued,bool accepted) {
    wk_bulk_profile_port *v=&wk_bulk_profile_ports[p];
    if(queued>v->queue_max)v->queue_max=queued;
    if(!accepted){v->submit_failed++;return;}
    v->tx_bytes+=cells*512u;v->tx_batches++;if(cells>1)v->multi++;
}
#define WK_FILE_BATCH_PROFILE_SUBMIT(p,c,q,ok) wk_bulk_profile_submit(p,c,q,ok)

/* Keep the existing MT2 prefix, fields and one newline. If an unexpected long
 * prefix cannot fit, return the original intact rather than a partial record.
 * bpl=loops, bpg=max inter-loop ticks, bph=ticks/second, bpm=firmware ms.
 * bp0/bp1 (hex): OUT bytes:OUT callbacks:IN submitted bytes:IN submits:
 * IN completions:multi-cell submits:max queued cells:submit failures:reset callbacks.
 * OUT counts include program-image cells; measure deltas after image READY.
 * IN submitted != delivered: reset can discard an in-flight DMA transfer. */
static size_t wk_bulk_profile_line(const uint8_t *prefix,size_t n,uint8_t *out,size_t capacity,
                                   uint32_t tick_hz,uint32_t now) {
    if(!prefix||!n||prefix[n-1]!='\n'||capacity<n)return 0;
    memcpy(out,prefix,n);
    const wk_bulk_profile_port *a=&wk_bulk_profile_ports[0],*b=&wk_bulk_profile_ports[1];
    int length=snprintf((char *)out+n-1,capacity-n+1,
        ",bp=1,bpl=%lx,bpg=%lx,bph=%lx,bpm=%lx"
        ",bp0=%lx:%lx:%lx:%lx:%lx:%lx:%lx:%lx:%lx"
        ",bp1=%lx:%lx:%lx:%lx:%lx:%lx:%lx:%lx:%lx\n",
        (unsigned long)wk_bulk_profile_loops,(unsigned long)wk_bulk_profile_gap,
        (unsigned long)tick_hz,(unsigned long)now,
        (unsigned long)a->rx_bytes,(unsigned long)a->rx_packets,(unsigned long)a->tx_bytes,
        (unsigned long)a->tx_batches,(unsigned long)a->completed,(unsigned long)a->multi,
        (unsigned long)a->queue_max,(unsigned long)a->submit_failed,(unsigned long)a->resets,
        (unsigned long)b->rx_bytes,(unsigned long)b->rx_packets,(unsigned long)b->tx_bytes,
        (unsigned long)b->tx_batches,(unsigned long)b->completed,(unsigned long)b->multi,
        (unsigned long)b->queue_max,(unsigned long)b->submit_failed,(unsigned long)b->resets);
    if(length<0||(size_t)length>=capacity-n+1){memcpy(out,prefix,n);return n;}
    return n-1+(size_t)length;
}
