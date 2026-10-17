#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct CatLiveDocument CatLiveDocument;
// All calls on a handle must be serialized by the control thread. No calls
// from the real-time audio callback. UTF-8 is used on every platform.
CatLiveDocument* catlive_document_create(void);
void catlive_document_destroy(CatLiveDocument* document);
// Returns an owned, nul-terminated JSON {ok,data} or {ok:false,error} response.
// Null means allocation failure. No C++ exception crosses this boundary.
char* catlive_document_request(CatLiveDocument* document, const char* request, size_t length);
void catlive_document_free_response(char* response);
#ifdef __cplusplus
}
#endif
