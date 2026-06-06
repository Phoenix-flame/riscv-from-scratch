/* main.c - a small FreeRTOS demo for this core: a producer task feeds a
 * queue, a consumer task prints what it receives. Proves tasks, the
 * scheduler tick (CLINT), queues, and delays all link against this port. */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "firmware.h"     /* kprintf / UART, halt() */

static QueueHandle_t xQueue;

static void vProducer( void *pv ){
    ( void ) pv;
    unsigned n = 0;
    for( ;; ){
        xQueueSend( xQueue, &n, portMAX_DELAY );
        n++;
        vTaskDelay( pdMS_TO_TICKS( 10 ) );
    }
}

static void vConsumer( void *pv ){
    ( void ) pv;
    unsigned v;
    for( ;; ){
        if( xQueueReceive( xQueue, &v, portMAX_DELAY ) == pdPASS ){
            kprintf( "consumer got %d\n", v );
            if( v >= 9 ){ kprintf( "FreeRTOS demo done\n" ); halt( 0 ); }
        }
    }
}

int main( void ){
    kprintf( "FreeRTOS starting on RV32IMA core...\n" );
    xQueue = xQueueCreate( 4, sizeof( unsigned ) );
    configASSERT( xQueue != NULL );
    xTaskCreate( vProducer, "prod", configMINIMAL_STACK_SIZE, NULL, 2, NULL );
    xTaskCreate( vConsumer, "cons", configMINIMAL_STACK_SIZE + 64, NULL, 2, NULL );
    vTaskStartScheduler();          /* never returns */
    for( ;; ){ }
}

/* Minimal hooks the kernel may reference depending on config. */
void vApplicationMallocFailedHook( void ){ kprintf("malloc failed\n"); halt(1); }
