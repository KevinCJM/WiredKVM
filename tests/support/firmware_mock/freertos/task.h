#pragma once
void vTaskDelay(unsigned ticks);
int xTaskCreate(void (*task)(void *), const char *name, unsigned stack,
                void *arg, unsigned priority, void *handle);
void vTaskDelete(void *task);
void wk_test_task_yield(void);
#define taskYIELD() wk_test_task_yield()
