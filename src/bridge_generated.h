#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct _Dart_Handle* Dart_Handle;

#define VIDEO_QUEUE_SIZE 120

#define AUDIO_BUFFER_MS 3000

#define CLIPBOARD_INTERVAL 333

#define ERR_SUCCESS 0

#define ERR_ANUVADINI_HANDLE_BASE 10000

#define ERR_PLUGIN_LOAD 10001

#define ERR_PLUGIN_MSG_INIT 10101

#define ERR_PLUGIN_MSG_INIT_INVALID 10102

#define ERR_PLUGIN_MSG_GET_LOCAL_PEER_ID 10103

#define ERR_PLUGIN_SIGNATURE_NOT_VERIFIED 10104

#define ERR_PLUGIN_SIGNATURE_VERIFICATION_FAILED 10105

#define ERR_CALL_UNIMPLEMENTED 10201

#define ERR_CALL_INVALID_METHOD 10202

#define ERR_CALL_NOT_SUPPORTED_METHOD 10203

#define ERR_CALL_INVALID_PEER 10204

#define ERR_CALL_INVALID_ARGS 10301

#define ERR_PEER_ID_MISMATCH 10302

#define ERR_CALL_CONFIG_VALUE 10303

#define ERR_NOT_HANDLED 10401

#define ERR_CALLBACK_HANDLE_BASE 20000

#define ERR_CALLBACK_PLUGIN_ID 20001

#define ERR_CALLBACK_INVALID_ARGS 20002

#define ERR_CALLBACK_INVALID_MSG 20003

#define ERR_CALLBACK_TARGET 20004

#define ERR_CALLBACK_TARGET_TYPE 20005

#define ERR_CALLBACK_PEER_NOT_FOUND 20006

#define ERR_CALLBACK_FAILED 21001

#define ERR_PLUGIN_HANDLE_BASE 30000

#define EER_CALL_FAILED 30021

#define ERR_PEER_ON_FAILED 40012

#define ERR_PEER_OFF_FAILED 40012

#define INVALID_PRIVACY_MODE_CONN_ID 0

typedef struct DartCObject DartCObject;

typedef struct Display Display;

typedef int64_t DartPort;

typedef bool (*DartPostCObjectFnType)(DartPort port_id, void *message);

typedef struct DartCObject *WireSyncReturn;

typedef unsigned long XID;

typedef XID XserverRegion;

typedef struct XRectangle {
  short x;
  short y;
  unsigned short width;
  unsigned short height;
} XRectangle;

#define CONFIG_INPUT_SOURCE_DEFAULT CONFIG_INPUT_SOURCE_1

#define INJECTED_PROCESS_EXE WIN_TOPMOST_INJECTED_PROCESS_EXE

void store_dart_post_cobject(DartPostCObjectFnType ptr);

Dart_Handle get_dart_object(uintptr_t ptr);

void drop_dart_object(uintptr_t ptr);

uintptr_t new_dart_opaque(Dart_Handle handle);

intptr_t init_frb_dart_api_dl(void *obj);

void free_WireSyncReturn(WireSyncReturn ptr);

/**
 * FFI for anuvadini core's main entry.
 * Return true if the app should continue running with UI(possibly Flutter), false if the app should exit.
 */
bool anuvadini_core_main(void);

void handle_applicationShouldOpenUntitledFile(void);

char **anuvadini_core_main_args(int *args_len);

void free_c_args(char **ptr, int len);

int32_t get_anuvadini_app_name(uint16_t *buffer, int32_t length);

const uint8_t *session_get_rgba(const uint32_t *session_uuid_str, uintptr_t display);

extern XserverRegion XFixesCreateRegion(Display *dpy,
                                        struct XRectangle *rectangles,
                                        int nrectangles);

extern void XFixesDestroyRegion(Display *dpy, XserverRegion region);

extern void XFixesSetWindowShapeRegion(Display *dpy,
                                       XID win,
                                       int shape_kind,
                                       int x_off,
                                       int y_off,
                                       XserverRegion region);

extern bool MacSetPrivacyMode(bool on);

static int64_t dummy_method_to_enforce_bundling(void) {
    int64_t dummy_var = 0;
    dummy_var ^= ((int64_t) (void*) free_WireSyncReturn);
    dummy_var ^= ((int64_t) (void*) store_dart_post_cobject);
    dummy_var ^= ((int64_t) (void*) get_dart_object);
    dummy_var ^= ((int64_t) (void*) drop_dart_object);
    dummy_var ^= ((int64_t) (void*) new_dart_opaque);
    return dummy_var;
}
