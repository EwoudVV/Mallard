#pragma once
#ifdef __cplusplus
extern "C" {
#endif
bool mb_init(const char *path);
bool mb_validate(const char *path);
char *mb_request(const char *url,const char *source,const char *kind,const char *method);
char *mb_cosmetic(const char *url,const char *classes,const char *ids);
void mb_free(char *value);
#ifdef __cplusplus
}
#endif
