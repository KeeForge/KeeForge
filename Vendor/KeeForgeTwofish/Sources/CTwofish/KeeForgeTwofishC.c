#include "KeeForgeTwofishC.h"

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "twofish.h"

struct KeeForgeTwofishContext {
    Twofish_key expanded_key;
};

static _Thread_local jmp_buf *fatal_target = NULL;

/* Called by the single documented integration change in upstream twofish.c. */
_Noreturn void kf_twofish_report_fatal(const char *message)
{
    (void)message;
    if (fatal_target != NULL) {
        longjmp(*fatal_target, 1);
    }

    /* All upstream entry points are private and wrapped below. */
    abort();
}

void kf_twofish_secure_zero(void *buffer, size_t length)
{
    if (buffer == NULL) {
        return;
    }

    volatile uint8_t *bytes = (volatile uint8_t *)buffer;
    while (length > 0) {
        *bytes++ = 0;
        --length;
    }
}

int kf_twofish_initialize(void)
{
    jmp_buf target;
    jmp_buf *previous_target = fatal_target;
    fatal_target = &target;
    if (setjmp(target) != 0) {
        fatal_target = previous_target;
        return 0;
    }

    Twofish_initialise();
    fatal_target = previous_target;
    return 1;
}

int kf_twofish_context_create(
    const uint8_t *key,
    size_t key_length,
    KeeForgeTwofishContextRef *context
)
{
    if (key == NULL || context == NULL ||
        (key_length != 16 && key_length != 24 && key_length != 32)) {
        return 0;
    }

    *context = NULL;
    struct KeeForgeTwofishContext *created = calloc(1, sizeof(*created));
    if (created == NULL) {
        return 0;
    }

    Twofish_Byte key_copy[32] = {0};
    memcpy(key_copy, key, key_length);

    jmp_buf target;
    jmp_buf *previous_target = fatal_target;
    fatal_target = &target;
    if (setjmp(target) != 0) {
        fatal_target = previous_target;
        kf_twofish_secure_zero(key_copy, sizeof(key_copy));
        kf_twofish_secure_zero(created, sizeof(*created));
        free(created);
        return 0;
    }

    Twofish_prepare_key(key_copy, (int)key_length, &created->expanded_key);
    fatal_target = previous_target;
    kf_twofish_secure_zero(key_copy, sizeof(key_copy));

    *context = created;
    return 1;
}

int kf_twofish_encrypt_block(
    KeeForgeTwofishContextRef context,
    const uint8_t input[16],
    uint8_t output[16]
)
{
    if (context == NULL || input == NULL || output == NULL) {
        return 0;
    }

    jmp_buf target;
    jmp_buf *previous_target = fatal_target;
    fatal_target = &target;
    if (setjmp(target) != 0) {
        fatal_target = previous_target;
        kf_twofish_secure_zero(output, 16);
        return 0;
    }

    Twofish_encrypt(&context->expanded_key, (Twofish_Byte *)input, output);
    fatal_target = previous_target;
    return 1;
}

int kf_twofish_decrypt_block(
    KeeForgeTwofishContextRef context,
    const uint8_t input[16],
    uint8_t output[16]
)
{
    if (context == NULL || input == NULL || output == NULL) {
        return 0;
    }

    jmp_buf target;
    jmp_buf *previous_target = fatal_target;
    fatal_target = &target;
    if (setjmp(target) != 0) {
        fatal_target = previous_target;
        kf_twofish_secure_zero(output, 16);
        return 0;
    }

    Twofish_decrypt(&context->expanded_key, (Twofish_Byte *)input, output);
    fatal_target = previous_target;
    return 1;
}

void kf_twofish_context_destroy(KeeForgeTwofishContextRef context)
{
    if (context == NULL) {
        return;
    }

    kf_twofish_secure_zero(context, sizeof(*context));
    free(context);
}
