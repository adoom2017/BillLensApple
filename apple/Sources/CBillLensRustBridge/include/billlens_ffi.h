#ifndef BILLLENS_FFI_H
#define BILLLENS_FFI_H

char *billlens_handle_request(const char *request_json);
void billlens_free_string(char *value);

#endif

