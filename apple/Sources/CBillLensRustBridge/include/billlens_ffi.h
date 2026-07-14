#ifndef BILLLENS_FFI_H
#define BILLLENS_FFI_H

#include <stdint.h>

char *billlens_handle_request(const char *request_json);
void billlens_free_string(char *value);

typedef int32_t (*billlens_stt_start_fn)(void);
typedef char *(*billlens_stt_stop_fn)(void);
typedef void (*billlens_stt_cancel_fn)(void);
typedef void (*billlens_stt_free_string_fn)(char *);

void billlens_register_stt_backend(billlens_stt_start_fn start_fn,
                                   billlens_stt_stop_fn stop_fn,
                                   billlens_stt_cancel_fn cancel_fn,
                                   billlens_stt_free_string_fn free_fn);

typedef char *(*billlens_local_llm_run_fn)(const char *request_json);
typedef void (*billlens_local_llm_cancel_fn)(void);
typedef void (*billlens_local_llm_unload_fn)(void);
typedef void (*billlens_local_llm_free_string_fn)(char *);

int32_t billlens_register_local_llm_backend(billlens_local_llm_run_fn run_fn,
                                            billlens_local_llm_cancel_fn cancel_fn,
                                            billlens_local_llm_unload_fn unload_fn,
                                            billlens_local_llm_free_string_fn free_fn);

/* Swift @_cdecl exports — implemented in BillLensAppleServices/SpeechFFIExports.swift,
   declared here so Swift modules outside BillLensAppleServices can take their address. */
int32_t billlens_swift_stt_start(void);
char *billlens_swift_stt_stop(void);
void billlens_swift_stt_cancel(void);
void billlens_swift_stt_free_string(char *ptr);

char *billlens_swift_local_llm_run(const char *request_json);
void billlens_swift_local_llm_cancel(void);
void billlens_swift_local_llm_unload(void);
void billlens_swift_local_llm_free_string(char *ptr);

#endif
