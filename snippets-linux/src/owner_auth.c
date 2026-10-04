/* Linux-PAM is used only by the bounded, unprivileged owner-auth helper.
 * No raw module messages, passwords or user names leave this adapter. */
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <pwd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { OWNER_OK = 0, OWNER_UNAVAILABLE = 1, OWNER_DENIED = 2,
       OWNER_ACCOUNT = 3, OWNER_IDENTITY = 4, OWNER_CONVERSATION = 5 };
typedef struct {
    const uint8_t *password;
    size_t length;
    unsigned supplied;
    int refused;
} Conversation;
static int converse(int count, const struct pam_message **messages,
        struct pam_response **output, void *data) {
    Conversation *state = data;
    if (count < 1 || count > PAM_MAX_NUM_MSG || !messages || !output || !state)
        return PAM_CONV_ERR;
    struct pam_response *responses = calloc((size_t)count, sizeof(*responses));
    if (!responses) return PAM_BUF_ERR;
    for (int i = 0; i < count; ++i) {
        if (!messages[i]) goto refuse;
        switch (messages[i]->msg_style) {
        case PAM_PROMPT_ECHO_OFF:
            /* One new password, never reuse it for a second factor or change. */
            if (state->supplied != 0) goto refuse;
            responses[i].resp = malloc(state->length + 1);
            if (!responses[i].resp) goto refuse;
            memcpy(responses[i].resp, state->password, state->length);
            responses[i].resp[state->length] = 0;
            state->supplied += 1;
            break;
        case PAM_ERROR_MSG:
        case PAM_TEXT_INFO:
            /* Module text is untrusted and can contain private account data. */
            break;
        default:
            goto refuse;
        }
    }
    *output = responses;
    return PAM_SUCCESS;
refuse:
    state->refused = 1;
    for (int i = 0; i < count; ++i) {
        if (responses[i].resp) {
            explicit_bzero(responses[i].resp, state->length + 1);
            free(responses[i].resp);
        }
    }
    free(responses);
    return PAM_CONV_ERR;
}
static int authenticate_current(uint32_t expected_uid, const uint8_t *password,
        size_t length) {
    if (getuid() != geteuid() || getgid() != getegid() || geteuid() != expected_uid)
        return OWNER_IDENTITY;
    if (!password || length == 0 || length > 4096 || memchr(password, 0, length))
        return OWNER_CONVERSATION;
    long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t size = suggested > 0 ? (size_t)suggested : 16384;
    if (size > 1024 * 1024) return OWNER_UNAVAILABLE;
    char *buffer = malloc(size);
    if (!buffer) return OWNER_UNAVAILABLE;
    struct passwd entry, *found = NULL;
    int result = OWNER_UNAVAILABLE;
    pam_handle_t *handle = NULL;
    Conversation state = { password, length, 0, 0 };
    struct pam_conv conversation = { converse, &state };
    if (getpwuid_r((uid_t)expected_uid, &entry, buffer, size, &found) != 0
            || !found || !found->pw_name || found->pw_uid != expected_uid)
        goto done;
#ifdef SNIP_OWNER_FIXTURE_MAIN
    int status = pam_start_confdir("system-auth", found->pw_name, &conversation,
        SNIP_OWNER_FIXTURE_MAIN, &handle);
#else
    int status = pam_start("system-auth", found->pw_name, &conversation, &handle);
#endif
    if (status != PAM_SUCCESS) goto done;
    status = pam_authenticate(handle, PAM_SILENT | PAM_DISALLOW_NULL_AUTHTOK);
    if (status == PAM_SUCCESS && !state.refused && state.supplied == 1) {
        status = pam_acct_mgmt(handle, PAM_SILENT | PAM_DISALLOW_NULL_AUTHTOK);
        if (state.refused || state.supplied != 1) result = OWNER_CONVERSATION;
        else if (status == PAM_SUCCESS) {
            const void *user = NULL;
            status = pam_get_item(handle, PAM_USER, &user);
            result = status == PAM_SUCCESS && user
                && strcmp(user, found->pw_name) == 0
                && getuid() == expected_uid && geteuid() == expected_uid
                && getgid() == getegid() ? OWNER_OK : OWNER_IDENTITY;
        } else result = OWNER_ACCOUNT;
    } else if (state.refused || state.supplied != 1) result = OWNER_CONVERSATION;
    else if (status == PAM_AUTH_ERR || status == PAM_USER_UNKNOWN
            || status == PAM_MAXTRIES || status == PAM_CRED_INSUFFICIENT)
        result = OWNER_DENIED;
    int ended = pam_end(handle, status);
    handle = NULL;
    if (ended != PAM_SUCCESS && result == OWNER_OK) result = OWNER_UNAVAILABLE;
done:
    if (handle) pam_end(handle, PAM_ABORT);
    explicit_bzero(buffer, size);
    free(buffer);
    return result;
}
int snip_owner_authenticate(uint32_t expected_uid, const uint8_t *password, size_t length) {
    /* The application has no configurable service or alternate configuration. */
    return authenticate_current(expected_uid, password, length);
}

/* This entry point is compiled only into a disposable fixture executable.
 * Cargo and installed application binaries never define this macro. */
#ifdef SNIP_OWNER_FIXTURE_MAIN
#include <sys/prctl.h>
static int read_exact(void *bytes, size_t length) {
    uint8_t *p = bytes;
    while (length) {
        ssize_t n = read(STDIN_FILENO, p, length);
        if (n <= 0) return 0;
        p += n; length -= (size_t)n;
    }
    return 1;
}
int main(void) {
    uint8_t header[8], password[4096], reply = OWNER_UNAVAILABLE;
    if (prctl(PR_SET_DUMPABLE, 0) != 0 || !read_exact(header, sizeof(header))) goto finish;
    uint32_t uid = ((uint32_t)header[0]<<24) | ((uint32_t)header[1]<<16)
        | ((uint32_t)header[2]<<8) | header[3];
    uint32_t length = ((uint32_t)header[4]<<24) | ((uint32_t)header[5]<<16)
        | ((uint32_t)header[6]<<8) | header[7];
    if (length > sizeof(password) || !read_exact(password, length)) goto finish;
    reply = (uint8_t)authenticate_current(uid, password, length);
finish:
    explicit_bzero(password, sizeof(password));
    return write(STDOUT_FILENO, &reply, 1) == 1 ? 0 : 1;
}
#endif
