#ifndef SHIFT_MTP_BRIDGE_H
#define SHIFT_MTP_BRIDGE_H

#include <stdint.h>

typedef int (*ShiftMTPProgress)(uint64_t sent, uint64_t total, void *context);

char *shift_mtp_detect_devices_json(void);
void *shift_mtp_open_device(const char *device_id, char **error_message);
void shift_mtp_close_device(void *handle);
char *shift_mtp_storages_json(void *handle, char **error_message);
char *shift_mtp_list_json(void *handle, uint32_t storage_id, uint32_t parent_id, char **error_message);
int shift_mtp_download(void *handle, uint32_t object_id, const char *local_path,
                       ShiftMTPProgress progress, void *context, char **error_message);
int shift_mtp_upload(void *handle, const char *local_path, const char *remote_name,
                     uint32_t parent_id, uint32_t storage_id,
                     ShiftMTPProgress progress, void *context, char **error_message);
int64_t shift_mtp_make_directory(void *handle, const char *name, uint32_t parent_id,
                                 uint32_t storage_id, char **error_message);
int shift_mtp_rename(void *handle, uint32_t object_id, const char *name, char **error_message);
int shift_mtp_delete(void *handle, uint32_t object_id, char **error_message);
void shift_mtp_free(void *pointer);

#endif
