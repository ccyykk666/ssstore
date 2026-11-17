#pragma once
#import <Foundation/Foundation.h>
@import IDevice;
#include <stdlib.h>

// Empty Rust boxed slices can use an aligned non-null sentinel (e.g. 0x8).
// That is not an allocation. The pinned FFI frees plist elements only; we own
// the outer storage only when the slice has elements.
static inline void SSDeviceArrayStorageFree(void *storage, size_t count) {
    if (storage && count > 0) free(storage);
}
static inline void SSDevicePlistArrayFree(plist_t *nodes, size_t count) {
    if (!nodes || count == 0) return;
    idevice_plist_array_free(nodes, count);
    SSDeviceArrayStorageFree(nodes, count);
}

// Device/DVT values may contain UIDs and strings forbidden by XML. The pinned
// plist_ffi XML writer unwraps serialization errors and aborts across the C ABI.
// Binary plists preserve these values, including dates/data/non-finite reals.
static inline id SSDevicePlistValue(plist_t node) {
    if (!node) return NSNull.null;
    char *bytes = NULL; uint32_t length = 0;
    plist_err_t result = plist_to_bin(node, &bytes, &length);
    if (result != PLIST_ERR_SUCCESS || !bytes) { free(bytes); return NSNull.null; }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    // The pinned Rust Apple System allocator uses malloc/free. plist_mem_free
    // reconstructs a CString, whose NUL-based length is invalid for binary data.
    free(bytes);
    return [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] ?: NSNull.null;
}
