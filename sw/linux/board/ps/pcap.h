/* pcap.h  -  programming the PL from the PS (Step 56); see pcap.c */
#ifndef PCAP_H
#define PCAP_H
#include <stdint.h>

/* 0, or -1 and *why */
int pcap_load(const uint32_t *bit, uint32_t words, const char **why);
/* 0: PCAP order; 1: words byte-swapped; -1: no sync word */
int pcap_order(const uint32_t *bit, uint32_t words);

#endif
