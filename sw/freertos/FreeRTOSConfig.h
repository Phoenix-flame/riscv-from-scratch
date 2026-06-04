/* FreeRTOSConfig.h - configuration for this RV32IMA core + soc_rtos.
 * The CLINT timer lives at 0x10010000 (mtime) / 0x10010008 (mtimecmp). */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* --- machine timer (CLINT) addresses on soc_rtos --- */
#define configMTIME_BASE_ADDRESS        ( 0x10010000UL )
#define configMTIMECMP_BASE_ADDRESS     ( 0x10010008UL )

/* --- core/scheduler --- */
#define configCPU_CLOCK_HZ              ( 10000000UL )   /* 10k cyc/tick (set to real clk on HW) */
#define configTICK_RATE_HZ             ( ( TickType_t ) 1000 )
#define configUSE_PREEMPTION            1
#define configUSE_TIME_SLICING          1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configMAX_PRIORITIES            ( 5 )
#define configMINIMAL_STACK_SIZE        ( ( unsigned short ) 128 )
#define configMAX_TASK_NAME_LEN         ( 12 )
#define configUSE_16_BIT_TICKS          0
#define configIDLE_SHOULD_YIELD         1
#define configUSE_MUTEXES               1
#define configUSE_RECURSIVE_MUTEXES     0
#define configUSE_COUNTING_SEMAPHORES   1
#define configQUEUE_REGISTRY_SIZE       0
#define configUSE_TASK_NOTIFICATIONS    1

/* --- memory --- */
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configSUPPORT_STATIC_ALLOCATION  0
#define configTOTAL_HEAP_SIZE           ( ( size_t ) ( 16 * 1024 ) )
#define configISR_STACK_SIZE_WORDS      ( 512 )          /* port allocates its own ISR stack */

/* --- hooks / checks (all off to stay minimal) --- */
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configCHECK_FOR_STACK_OVERFLOW  0
#define configUSE_MALLOC_FAILED_HOOK    0
#define configUSE_TRACE_FACILITY        0
#define configUSE_TIMERS                0

/* --- API subset we use --- */
#define INCLUDE_vTaskPrioritySet        0
#define INCLUDE_uxTaskPriorityGet       0
#define INCLUDE_vTaskDelete             0
#define INCLUDE_vTaskSuspend            1
#define INCLUDE_vTaskDelayUntil         1
#define INCLUDE_vTaskDelay              1
#define INCLUDE_xTaskGetSchedulerState  1

/* assert: stop and spin so a sim/JTAG can catch it */
#define configASSERT( x ) if( ( x ) == 0 ) { taskDISABLE_INTERRUPTS(); for( ;; ); }

#endif /* FREERTOS_CONFIG_H */
