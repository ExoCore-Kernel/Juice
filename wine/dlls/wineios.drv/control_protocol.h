/* Dedicated Juice/UIKit control protocol. LGPL-2.1-or-later. */
#ifndef __JUICE_IOS_CONTROL_PROTOCOL_H
#define __JUICE_IOS_CONTROL_PROTOCOL_H

#include <stdint.h>

#define JUICE_CONTROL_MAGIC 0x4a554354u /* JUCT */
#define JUICE_CONTROL_VERSION 1u
#define JUICE_CONTROL_PATH_MAX 2048u
#define JUICE_CONTROL_DETAIL_MAX 512u

enum juice_control_type
{
    JUICE_CONTROL_IMPORT_REQUEST = 1,
    JUICE_CONTROL_IMPORT_RESPONSE = 2,
    JUICE_CONTROL_HOST_ACTION = 3
};

enum juice_control_status
{
    JUICE_CONTROL_STATUS_PENDING = 1,
    JUICE_CONTROL_STATUS_COMPLETE = 2,
    JUICE_CONTROL_STATUS_CANCELLED = 3,
    JUICE_CONTROL_STATUS_ERROR = 4
};

enum juice_control_filter
{
    JUICE_CONTROL_FILTER_MSI = 0x01,
    JUICE_CONTROL_FILTER_EXE = 0x02,
    JUICE_CONTROL_FILTER_ZIP = 0x04
};

enum juice_control_action
{
    JUICE_CONTROL_ACTION_SHOW_HOST_CONTROLS = 1,
    JUICE_CONTROL_ACTION_LAUNCH_PATH = 2,
    JUICE_CONTROL_ACTION_IMPORT_ZIP = 3
};

struct juice_control_message
{
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t size;
    uint32_t request_id;
    int32_t status;
    uint32_t flags;
    char path[JUICE_CONTROL_PATH_MAX];
    char detail[JUICE_CONTROL_DETAIL_MAX];
};

#endif
