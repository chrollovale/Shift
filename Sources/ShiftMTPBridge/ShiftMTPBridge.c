#include "ShiftMTPBridge.h"
#include <libmtp.h>

#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
    LIBMTP_mtpdevice_t *device;
} ShiftMTPHandle;

typedef struct {
    ShiftMTPProgress callback;
    void *context;
} ShiftMTPProgressContext;

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} ShiftMTPString;

static pthread_once_t initialization = PTHREAD_ONCE_INIT;

static void initialize_libmtp(void) {
    LIBMTP_Init();
}

static void ensure_initialized(void) {
    pthread_once(&initialization, initialize_libmtp);
}

static void append_raw(ShiftMTPString *string, const char *bytes, size_t count) {
    if (!string || !bytes || count == 0) return;
    size_t required = string->length + count + 1;
    if (required > string->capacity) {
        size_t capacity = string->capacity ? string->capacity : 256;
        while (capacity < required) capacity *= 2;
        char *next = realloc(string->bytes, capacity);
        if (!next) return;
        string->bytes = next;
        string->capacity = capacity;
    }
    memcpy(string->bytes + string->length, bytes, count);
    string->length += count;
    string->bytes[string->length] = '\0';
}

static void append(ShiftMTPString *string, const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int count = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (count > 0) {
        char *buffer = malloc((size_t)count + 1);
        if (buffer) {
            vsnprintf(buffer, (size_t)count + 1, format, args);
            append_raw(string, buffer, (size_t)count);
            free(buffer);
        }
    }
    va_end(args);
}

static void append_json_string(ShiftMTPString *string, const char *value) {
    append_raw(string, "\"", 1);
    const unsigned char *cursor = (const unsigned char *)(value ? value : "");
    while (*cursor) {
        unsigned char c = *cursor++;
        switch (c) {
            case '"': append_raw(string, "\\\"", 2); break;
            case '\\': append_raw(string, "\\\\", 2); break;
            case '\b': append_raw(string, "\\b", 2); break;
            case '\f': append_raw(string, "\\f", 2); break;
            case '\n': append_raw(string, "\\n", 2); break;
            case '\r': append_raw(string, "\\r", 2); break;
            case '\t': append_raw(string, "\\t", 2); break;
            default:
                if (c < 0x20) append(string, "\\u%04x", c);
                else append_raw(string, (const char *)&c, 1);
        }
    }
    append_raw(string, "\"", 1);
}

static char *finish(ShiftMTPString *string) {
    if (!string->bytes) {
        string->bytes = calloc(1, 1);
    }
    return string->bytes;
}

static void set_error(char **output, const char *message) {
    if (!output) return;
    const char *text = message;
    if (!text || !*text) text = "MTP operation failed.";
    *output = strdup(text);
}

static void set_device_error(char **output, LIBMTP_mtpdevice_t *device, const char *fallback) {
    if (!output) return;
    LIBMTP_error_t *error = device ? LIBMTP_Get_Errorstack(device) : NULL;
    if (error && error->error_text && *error->error_text) set_error(output, error->error_text);
    else set_error(output, fallback);
    if (device) LIBMTP_Clear_Errorstack(device);
}

static int progress_trampoline(uint64_t sent, uint64_t total, const void *data) {
    ShiftMTPProgressContext *context = (ShiftMTPProgressContext *)data;
    if (!context || !context->callback) return 0;
    return context->callback(sent, total, context->context);
}

char *shift_mtp_detect_devices_json(void) {
    ensure_initialized();
    ShiftMTPString output = {0};
    append_raw(&output, "[", 1);

    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if (result == LIBMTP_ERROR_NONE && devices) {
        for (int index = 0; index < count; index++) {
            if (index) append_raw(&output, ",", 1);
            append(&output, "{\"id\":\"%u:%u\",\"bus\":%u,\"device\":%u,\"name\":",
                   devices[index].bus_location, devices[index].devnum,
                   devices[index].bus_location, devices[index].devnum);
            ShiftMTPString name = {0};
            if (devices[index].device_entry.vendor && *devices[index].device_entry.vendor) {
                append(&name, "%s", devices[index].device_entry.vendor);
                if (devices[index].device_entry.product && *devices[index].device_entry.product) {
                    append(&name, " %s", devices[index].device_entry.product);
                }
            } else if (devices[index].device_entry.product && *devices[index].device_entry.product) {
                append(&name, "%s", devices[index].device_entry.product);
            } else {
                append(&name, "Android device");
            }
            append_json_string(&output, finish(&name));
            free(name.bytes);
            append_raw(&output, "}", 1);
        }
    }
    if (devices) LIBMTP_FreeMemory(devices);
    append_raw(&output, "]", 1);
    return finish(&output);
}

void *shift_mtp_open_device(const char *device_id, char **error_message) {
    ensure_initialized();
    unsigned int wanted_bus = 0;
    unsigned int wanted_device = 0;
    if (!device_id || sscanf(device_id, "%u:%u", &wanted_bus, &wanted_device) != 2) {
        set_error(error_message, "Invalid MTP device identifier.");
        return NULL;
    }

    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if (result != LIBMTP_ERROR_NONE || !devices) {
        if (devices) LIBMTP_FreeMemory(devices);
        set_error(error_message, "No MTP device was found. Unlock the phone and choose File transfer (MTP) in USB settings.");
        return NULL;
    }

    LIBMTP_mtpdevice_t *device = NULL;
    for (int index = 0; index < count; index++) {
        if (devices[index].bus_location == wanted_bus && devices[index].devnum == wanted_device) {
            device = LIBMTP_Open_Raw_Device_Uncached(&devices[index]);
            break;
        }
    }
    LIBMTP_FreeMemory(devices);
    if (!device) {
        set_error(error_message, "Couldn't open the MTP device. Make sure it is unlocked and not in use by another app.");
        return NULL;
    }

    LIBMTP_Clear_Errorstack(device);
    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        set_device_error(error_message, device, "Couldn't read storage on the MTP device.");
        LIBMTP_Release_Device(device);
        return NULL;
    }

    ShiftMTPHandle *handle = calloc(1, sizeof(ShiftMTPHandle));
    if (!handle) {
        LIBMTP_Release_Device(device);
        set_error(error_message, "Couldn't allocate an MTP connection.");
        return NULL;
    }
    handle->device = device;
    return handle;
}

void shift_mtp_close_device(void *opaque_handle) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle) return;
    if (handle->device) LIBMTP_Release_Device(handle->device);
    free(handle);
}

char *shift_mtp_storages_json(void *opaque_handle, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device) {
        set_error(error_message, "The MTP device is disconnected.");
        return NULL;
    }

    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Storage(handle->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        set_device_error(error_message, handle->device, "Couldn't refresh storage on the MTP device.");
        return NULL;
    }

    ShiftMTPString output = {0};
    append_raw(&output, "[", 1);
    int first = 1;
    for (LIBMTP_devicestorage_t *storage = handle->device->storage; storage; storage = storage->next) {
        if (!first) append_raw(&output, ",", 1);
        first = 0;
        append(&output, "{\"id\":%u,\"name\":", storage->id);
        append_json_string(&output,
                           storage->StorageDescription && *storage->StorageDescription
                             ? storage->StorageDescription
                             : "Phone storage");
        append(&output, ",\"freeBytes\":%llu,\"maxCapacity\":%llu}",
               (unsigned long long)(storage->FreeSpaceInBytes == UINT64_MAX ? 0 : storage->FreeSpaceInBytes),
               (unsigned long long)(storage->MaxCapacity == UINT64_MAX ? 0 : storage->MaxCapacity));
    }
    append_raw(&output, "]", 1);
    return finish(&output);
}

char *shift_mtp_list_json(void *opaque_handle, uint32_t storage_id, uint32_t parent_id, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device) {
        set_error(error_message, "The MTP device is disconnected.");
        return NULL;
    }

    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(handle->device, storage_id, parent_id);
    LIBMTP_error_t *last_error = LIBMTP_Get_Errorstack(handle->device);
    if (!files && last_error) {
        set_device_error(error_message, handle->device, "Couldn't list this folder on the MTP device.");
        return NULL;
    }

    ShiftMTPString output = {0};
    append_raw(&output, "[", 1);
    int first = 1;
    while (files) {
        LIBMTP_file_t *current = files;
        files = files->next;
        if (!first) append_raw(&output, ",", 1);
        first = 0;
        append(&output, "{\"id\":%u,\"parentId\":%u,\"storageId\":%u,\"name\":",
               current->item_id, current->parent_id, current->storage_id);
        append_json_string(&output, current->filename ? current->filename : "");
        uint64_t file_size = current->filesize;
        if (file_size == UINT64_MAX || file_size == UINT32_MAX) file_size = 0;
        append(&output, ",\"isDirectory\":%s,\"size\":%llu,\"modified\":%lld}",
               current->filetype == LIBMTP_FILETYPE_FOLDER ? "true" : "false",
               (unsigned long long)file_size,
               (long long)current->modificationdate);
        LIBMTP_destroy_file_t(current);
    }
    append_raw(&output, "]", 1);
    return finish(&output);
}

int shift_mtp_download(void *opaque_handle, uint32_t object_id, const char *local_path,
                       ShiftMTPProgress progress, void *context, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device || !local_path) {
        set_error(error_message, "The MTP device is disconnected.");
        return -1;
    }
    ShiftMTPProgressContext progress_context = { progress, context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_File_To_File(handle->device, object_id, local_path,
                                        progress ? progress_trampoline : NULL,
                                        progress ? &progress_context : NULL);
    if (result != 0) {
        set_device_error(error_message, handle->device, "Couldn't download the file from the MTP device.");
        return -1;
    }
    return 0;
}

int shift_mtp_upload(void *opaque_handle, const char *local_path, const char *remote_name,
                     uint32_t parent_id, uint32_t storage_id,
                     ShiftMTPProgress progress, void *context, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device || !local_path || !remote_name) {
        set_error(error_message, "The MTP device is disconnected.");
        return -1;
    }

    struct stat attributes;
    if (stat(local_path, &attributes) != 0 || !S_ISREG(attributes.st_mode)) {
        set_error(error_message, "Couldn't read the local file for transfer.");
        return -1;
    }

    LIBMTP_file_t *metadata = LIBMTP_new_file_t();
    if (!metadata) {
        set_error(error_message, "Couldn't allocate transfer metadata.");
        return -1;
    }
    metadata->filesize = (uint64_t)attributes.st_size;
    metadata->filename = strdup(remote_name);
    if (!metadata->filename) {
        LIBMTP_destroy_file_t(metadata);
        set_error(error_message, "Couldn't allocate the remote file name.");
        return -1;
    }
    metadata->filetype = LIBMTP_FILETYPE_UNKNOWN;
    metadata->parent_id = parent_id;
    metadata->storage_id = storage_id;

    ShiftMTPProgressContext progress_context = { progress, context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_File_From_File(handle->device, local_path, metadata,
                                            progress ? progress_trampoline : NULL,
                                            progress ? &progress_context : NULL);
    LIBMTP_destroy_file_t(metadata);
    if (result != 0) {
        set_device_error(error_message, handle->device, "Couldn't upload the file to the MTP device.");
        return -1;
    }
    return 0;
}

int64_t shift_mtp_make_directory(void *opaque_handle, const char *name, uint32_t parent_id,
                                 uint32_t storage_id, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device || !name) {
        set_error(error_message, "The MTP device is disconnected.");
        return -1;
    }
    char *owned_name = strdup(name);
    if (!owned_name) {
        set_error(error_message, "Couldn't allocate the folder name.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    uint32_t id = LIBMTP_Create_Folder(handle->device, owned_name, parent_id, storage_id);
    free(owned_name);
    if (id == 0) {
        set_device_error(error_message, handle->device, "Couldn't create the folder on the MTP device.");
        return -1;
    }
    return (int64_t)id;
}

int shift_mtp_rename(void *opaque_handle, uint32_t object_id, const char *name, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device || !name) {
        set_error(error_message, "The MTP device is disconnected.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Object_Filename(handle->device, object_id, (char *)name);
    if (result != 0) {
        set_device_error(error_message, handle->device, "Couldn't rename this item on the MTP device.");
        return -1;
    }
    return 0;
}

int shift_mtp_delete(void *opaque_handle, uint32_t object_id, char **error_message) {
    ShiftMTPHandle *handle = (ShiftMTPHandle *)opaque_handle;
    if (!handle || !handle->device) {
        set_error(error_message, "The MTP device is disconnected.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Delete_Object(handle->device, object_id) != 0) {
        set_device_error(error_message, handle->device, "Couldn't delete this item from the MTP device.");
        return -1;
    }
    return 0;
}

void shift_mtp_free(void *pointer) {
    free(pointer);
}
