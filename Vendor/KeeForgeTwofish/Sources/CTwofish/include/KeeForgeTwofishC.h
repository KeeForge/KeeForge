#ifndef KEEFORGE_TWOFISH_C_H
#define KEEFORGE_TWOFISH_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KeeForgeTwofishContext *KeeForgeTwofishContextRef;

/* Runs the upstream table generation and self-tests. Call exactly once. */
int kf_twofish_initialize(void);

/* Creates a per-operation expanded key for a 16, 24, or 32-byte key. */
int kf_twofish_context_create(
    const uint8_t *key,
    size_t key_length,
    KeeForgeTwofishContextRef *context
);

int kf_twofish_encrypt_block(
    KeeForgeTwofishContextRef context,
    const uint8_t input[16],
    uint8_t output[16]
);

int kf_twofish_decrypt_block(
    KeeForgeTwofishContextRef context,
    const uint8_t input[16],
    uint8_t output[16]
);

/* Wipes the expanded key before releasing its allocation. */
void kf_twofish_context_destroy(KeeForgeTwofishContextRef context);

/* Volatile byte-wise clearing for temporary key and plaintext buffers. */
void kf_twofish_secure_zero(void *buffer, size_t length);

#ifdef __cplusplus
}
#endif

#endif
