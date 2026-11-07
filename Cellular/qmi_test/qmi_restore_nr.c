/* Restore the default NR5G SA/NSA band preference masks. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void *qmi_client_type;
typedef void *qmi_idl_service_object_type;
typedef int qmi_client_error_type;
#define QMI_NO_ERR 0
#define QMI_CLIENT_INSTANCE_ANY 0xffff

typedef qmi_client_error_type (*init_fn)(qmi_idl_service_object_type, unsigned int, void *, void *, void *, uint32_t, qmi_client_type *);
typedef qmi_client_error_type (*send_fn)(qmi_client_type, unsigned int, void *, unsigned int, void *, unsigned int, unsigned int *, unsigned int);
typedef qmi_client_error_type (*release_fn)(qmi_client_type);
typedef qmi_idl_service_object_type (*svc_fn)(int, int, int);

static send_fn p_send;

static void add_tlv(uint8_t *buf, size_t *len, uint8_t type, const void *val, uint16_t vlen) {
    buf[*len + 0] = type;
    buf[*len + 1] = (uint8_t)(vlen & 0xff);
    buf[*len + 2] = (uint8_t)(vlen >> 8);
    if (vlen && val) memcpy(buf + *len + 3, val, vlen);
    *len += 3 + vlen;
}

int main(void) {
    void *h_cci = dlopen("/vendor/lib64/libqmi_cci.so", RTLD_NOW);
    void *h_svc = dlopen("/vendor/lib64/libqmiservices.so", RTLD_NOW);
    if (!h_cci || !h_svc) { printf("dlopen: %s\n", dlerror()); return 1; }
    init_fn p_init = (init_fn)dlsym(h_cci, "qmi_client_init_instance");
    p_send = (send_fn)dlsym(h_cci, "qmi_client_send_raw_msg_sync");
    release_fn p_release = (release_fn)dlsym(h_cci, "qmi_client_release");
    svc_fn p_svc = (svc_fn)dlsym(h_svc, "nas_get_service_object_internal_v01");
    if (!p_init || !p_send || !p_release || !p_svc) { printf("dlsym failed\n"); return 1; }
    qmi_client_type client = NULL;
    int rc = p_init(p_svc(1, 321, 6), QMI_CLIENT_INSTANCE_ANY, NULL, NULL, NULL, 5000, &client);
    printf("init rc=%d client=%p\n", rc, client);
    if (rc || !client) return 1;

    uint8_t req[512];
    size_t req_len = 0;
    uint8_t mode[2] = {0x5f, 0x00};
    uint8_t duration = 0x00;
    uint64_t sa[8] = {0x0000010008000005ULL, 0x0000000000006000ULL, 0, 0, 0, 0, 0, 0};
    uint64_t nsa[8] = {0x0000010000000000ULL, 0x0000000000006000ULL, 0, 0, 0, 0, 0, 0};
    add_tlv(req, &req_len, 0x11, mode, 2);
    add_tlv(req, &req_len, 0x17, &duration, 1);
    add_tlv(req, &req_len, 0x2F, sa, 64);
    add_tlv(req, &req_len, 0x30, nsa, 64);

    uint8_t resp[4096];
    unsigned int got = 0;
    rc = p_send(client, 0x0033, req, (unsigned int)req_len, resp, sizeof(resp), &got, 5000);
    printf("set rc=%d got=%u\n", rc, got);
    for (unsigned int i = 0; i + 3 <= got; ) {
        uint8_t t = resp[i];
        uint16_t l = (uint16_t)resp[i+1] | ((uint16_t)resp[i+2] << 8);
        printf("  TLV 0x%02x len=%u", t, l);
        if (t == 0x02 && l >= 4)
            printf(" result=0x%04x error=0x%04x", (uint16_t)resp[i+3] | ((uint16_t)resp[i+4] << 8), (uint16_t)resp[i+5] | ((uint16_t)resp[i+6] << 8));
        printf("\n");
        i += 3 + l;
    }
    sleep(2);
    got = 0;
    rc = p_send(client, 0x0034, NULL, 0, resp, sizeof(resp), &got, 5000);
    printf("get rc=%d got=%u\n", rc, got);
    for (unsigned int i = 0; i + 3 <= got; ) {
        uint8_t t = resp[i];
        uint16_t l = (uint16_t)resp[i+1] | ((uint16_t)resp[i+2] << 8);
        if ((t == 0x2C || t == 0x2D) && l == 64) {
            printf("  %s:", t == 0x2C ? "SA " : "NSA");
            for (int j = 0; j < 8; j++) {
                uint64_t m = 0; memcpy(&m, resp + i + 3 + j * 8, 8);
                printf(" [%d]=0x%016llx", j, (unsigned long long)m);
            }
            printf("\n");
        }
        i += 3 + l;
    }
    p_release(client);
    return 0;
}
