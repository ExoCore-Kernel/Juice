/* Shared Juice host-input protocol. LGPL-2.1-or-later. */
#ifndef __WINE_JUICEINPUT_H
#define __WINE_JUICEINPUT_H

#include <stdint.h>

#define JUICE_GAMEPAD_MAGIC 0x3147504au /* "JPG1" */
#define JUICE_GAMEPAD_VERSION 1u
#define JUICE_GAMEPAD_SHARED_SIZE 64u
#define JUICE_GAMEPAD_WINDOWS_PATH "Z:\\var\\mobile\\Documents\\JuiceData\\controller-v1.bin"

/* The button bits intentionally match XINPUT_GAMEPAD_* exactly. */
struct juice_gamepad_shared_state
{
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    volatile uint32_t sequence;
    uint32_t connected;
    uint32_t packet;
    uint16_t buttons;
    uint8_t left_trigger;
    uint8_t right_trigger;
    int16_t thumb_lx;
    int16_t thumb_ly;
    int16_t thumb_rx;
    int16_t thumb_ry;
    uint32_t capabilities;
    uint32_t battery_level;
    uint64_t timestamp_ns;
    uint8_t reserved[16];
};

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(struct juice_gamepad_shared_state) == JUICE_GAMEPAD_SHARED_SIZE,
               "Juice gamepad protocol layout changed");
#endif

#endif
