#pragma once
#include <stddef.h>
#include <stdint.h>
void *wk407_sim_create(void);
void wk407_sim_destroy(void *sim);
size_t wk407_sim_write(void *sim,unsigned source,const void *data,size_t size);
size_t wk407_sim_read(void *sim,unsigned destination,void *data,size_t size);
void wk407_sim_connect(void *sim,unsigned port,int connected,uint32_t now);
unsigned wk407_sim_hid_probe(void *sim,uint32_t now);
unsigned wk407_sim_peak(void *sim);
size_t wk407_sim_size(void);
int wk407_sim_control(void *sim, unsigned source, const void *report);
