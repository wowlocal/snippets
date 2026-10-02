/* Public fictional PAM module. Tests load it only through a private confdir.
 * It never accesses authentication databases, keyrings or host PAM policy. */
#define _GNU_SOURCE
#include <security/pam_modules.h>
#include <security/pam_appl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int pam_sm_authenticate(pam_handle_t *handle, int flags, int argc, const char **argv) {
    const char *mode = argc == 1 ? argv[0] : "password";
    if (!(flags & PAM_DISALLOW_NULL_AUTHTOK)) return PAM_SERVICE_ERR;
    if (!strcmp(mode, "cached")) return PAM_SUCCESS;
    if (!strcmp(mode, "sleep")) usleep(1000000);
    const void *item = NULL;
    if (pam_get_item(handle, PAM_CONV, &item) != PAM_SUCCESS || !item) return PAM_SYSTEM_ERR;
    const struct pam_conv *conversation = item;
    struct pam_message message = { PAM_PROMPT_ECHO_OFF, "Public fictional password prompt" };
    if (!strcmp(mode, "echo")) message.msg_style = PAM_PROMPT_ECHO_ON;
    const struct pam_message *messages[] = { &message };
    struct pam_response *responses = NULL;
    int status = conversation->conv(1, messages, &responses, conversation->appdata_ptr);
    if (status != PAM_SUCCESS) return status;
    int valid = responses && responses[0].resp
        && !strcmp(responses[0].resp, "Public fictional password");
    if (responses) {
        if (responses[0].resp) {
            explicit_bzero(responses[0].resp, strlen(responses[0].resp));
            free(responses[0].resp);
        }
        free(responses);
    }
    if (!strcmp(mode, "second")) {
        responses = NULL;
        status = conversation->conv(1, messages, &responses, conversation->appdata_ptr);
        if (responses) { free(responses[0].resp); free(responses); }
        return status;
    }
    return valid ? PAM_SUCCESS : PAM_AUTH_ERR;
}
int pam_sm_acct_mgmt(pam_handle_t *handle, int flags, int argc, const char **argv) {
    if (!(flags & PAM_DISALLOW_NULL_AUTHTOK)) return PAM_SERVICE_ERR;
    const char *mode = argc == 1 ? argv[0] : "valid";
    if (!strcmp(mode, "expired")) return PAM_ACCT_EXPIRED;
    if (!strcmp(mode, "change")) return PAM_NEW_AUTHTOK_REQD;
    if (!strcmp(mode, "identity")) return pam_set_item(handle, PAM_USER, "public-other-user");
    if (!strcmp(mode, "conversation")) {
        /* A broken account module ignores the refused second prompt. The
         * owning adapter must still refuse, even if PAM reports success. */
        const void *item = NULL;
        if (pam_get_item(handle, PAM_CONV, &item) != PAM_SUCCESS || !item)
            return PAM_SYSTEM_ERR;
        const struct pam_conv *conversation = item;
        struct pam_message message = { PAM_PROMPT_ECHO_OFF, "Public second prompt" };
        const struct pam_message *messages[] = { &message };
        struct pam_response *responses = NULL;
        conversation->conv(1, messages, &responses, conversation->appdata_ptr);
        if (responses) { free(responses[0].resp); free(responses); }
    }
    return PAM_SUCCESS;
}
