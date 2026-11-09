#pragma once
// Match the physical board's 100 Hz tick rate, not a convenient 1 ms mock.
#define pdMS_TO_TICKS(ms) ((ms) / 10)
#ifndef portMUX_TYPE
#define portMUX_TYPE int
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) ((void)(lock))
#define portEXIT_CRITICAL(lock) ((void)(lock))
#endif
