#pragma once
#import <Foundation/Foundation.h>
@import IDevice;
#include <stdlib.h>

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
