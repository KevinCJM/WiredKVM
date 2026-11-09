#ifndef WK_TRANSFER_TREE_H
#define WK_TRANSFER_TREE_H
#include <stdint.h>
#include <stddef.h>
typedef struct WKTree WKTree;
typedef struct WKTreeCancel WKTreeCancel;
WKTreeCancel *wk_tree_cancel_new(void);
void wk_tree_cancel_set(const WKTreeCancel *token);
void wk_tree_cancel_free(WKTreeCancel *token);
WKTree *wk_tree_create(const char *const *paths, size_t count, const WKTreeCancel *token, int32_t *error);
void wk_tree_free(WKTree *tree);
uint64_t wk_tree_size(const WKTree *tree);
size_t wk_tree_manifest_size(const WKTree *tree);
int32_t wk_tree_manifest_copy(const WKTree *tree, uint8_t *output, size_t size);
int32_t wk_tree_verify(const WKTree *tree);
intptr_t wk_tree_read(const WKTree *tree, uint64_t offset, uint8_t *output, size_t capacity);
int32_t wk_tree_manifest_validate(const uint8_t *data, size_t size, uint64_t total);
#endif
