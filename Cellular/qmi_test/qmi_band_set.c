/*
 * qmi_band_set - set NR5G SA/NSA band preference via QMI NAS.
 *
 * Usage:
 *   qmi_band_set <sa_bands> <nsa_bands> [duration]
 *
 * Examples:
 *   qmi_band_set 41,79 41,79 0     # allow n41 + n79, power-cycle duration
 *   qmi_band_set 41 41 0           # n41 only
 *   qmi_band_set 41,78,79 41,78,79 0
 *
 * Bands are comma-separated NR band numbers. The QMI bit mapping is:
 *   band = 1 + bit + 64 * mask_index
 * so n78 -> mask[1] bit 13 (0x2000), n79 -> mask[1] bit 14 (0x4000).
 *
 * Build:
 *   aarch64-linux-android21-clang -O2 -o qmi_band_set qmi_band_set.c -ldl
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
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

static const uint8_t *find_tlv(const uint8_t *buf, size_t len, uint8_t type, uint16_t *vlen) {
    size_t off = 0;
    while (off + 3 <= len) {
        uint8_t t = buf[off];
        uint16_t l = (uint16_t)buf[off + 1] | ((uint16_t)buf[off + 2] << 8);
        if (off + 3 + l > len) return NULL;
        if (t == type) { if (vlen) *vlen = l; return buf + off + 3; }
        off += 3 + l;
    }
    return NULL;
}

static int parse_bands(const char *s, uint64_t mask[8]) {
    char *copy = strdup(s);
    char *tok, *save = NULL;
    memset(mask, 0, 8 * sizeof(uint64_t));
    for (tok = strtok_r(copy, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        int band = atoi(tok);
        if (band <= 0 || band > 512) {
            fprintf(stderr, "invalid NR band: %s\n", tok);
            free(copy);
            return -1;
        }
        int idx = (band - 1) / 64;
        int bit = (band - 1) % 64;
        mask[idx] |= (uint64_t)1 << bit;
    }
    free(copy);
    return 0;
}

static void print_masks(const char *name, const uint8_t *m) {
    printf("  %s:", name);
    for (int i = 0; i < 8; i++) {
        uint64_t v = 0;
        memcpy(&v, m + i * 8, 8);
        printf(" [%d]=0x%016llx", i, (unsigned long long)v);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <sa_bands> <nsa_bands> [duration]\n", argv[0]);
        fprintf(stderr, "  e.g. %s 41,79 41,79 0\n", argv[0]);
        return 1;
    }

    uint64_t sa[8], nsa[8];
    if (parse_bands(argv[1], sa) != 0 || parse_bands(argv[2], nsa) != 0)
        return 1;
    uint8_t duration = (argc >= 4) ? (uint8_t)atoi(argv[3]) : 0;

    void *h_cci = dlopen("/vendor/lib64/libqmi_cci.so", RTLD_NOW);
    void *h_svc = dlopen("/vendor/lib64/libqmiservices.so", RTLD_NOW);
    if (!h_cci || !h_svc) { printf("dlopen: %s\n", dlerror()); return 1; }

    init_fn p_init = (init_fn)dlsym(h_cci, "qmi_client_init_instance");
    p_send = (send_fn)dlsym(h_cci, "qmi_client_send_raw_msg_sync");
    release_fn p_release = (release_fn)dlsym(h_cci, "qmi_client_release");
    svc_fn p_svc = (svc_fn)dlsym(h_svc, "nas_get_service_object_internal_v01");
    if (!p_init || !p_send || !p_release || !p_svc) {
        printf("dlsym failed: init=%p send=%p release=%p svc=%p\n",
               p_init, p_send, p_release, p_svc);
        return 1;
    }

    qmi_client_type client = NULL;
    int rc = p_init(p_svc(1, 321, 6), QMI_CLIENT_INSTANCE_ANY, NULL, NULL, NULL, 5000, &client);
    printf("init rc=%d client=%p\n", rc, client);
    if (rc || !client) return 1;

    uint8_t req[512];
    size_t req_len = 0;
    uint8_t mode[2] = {0x5f, 0x00};
    add_tlv(req, &req_len, 0x11, mode, 2);
    add_tlv(req, &req_len, 0x17, &duration, 1);
    add_tlv(req, &req_len, 0x2F, sa, 64);
    add_tlv(req, &req_len, 0x30, nsa, 64);

    printf("set SA=%s NSA=%s duration=%u\n", argv[1], argv[2], duration);
    uint8_t resp[4096];
    unsigned int got = 0;
    rc = p_send(client, 0x0033, req, (unsigned int)req_len, resp, sizeof(resp), &got, 5000);
    printf("set rc=%d got=%u\n", rc, got);
    for (unsigned int i = 0; i + 3 <= got; ) {
        uint8_t t = resp[i];
        uint16_t l = (uint16_t)resp[i+1] | ((uint16_t)resp[i+2] << 8);
        if (t == 0x02 && l >= 4)
            printf("  result=0x%04x error=0x%04x\n",
                   (uint16_t)resp[i+3] | ((uint16_t)resp[i+4] << 8),
                   (uint16_t)resp[i+5] | ((uint16_t)resp[i+6] << 8));
        i += 3 + l;
    }

    sleep(2);
    got = 0;
    rc = p_send(client, 0x0034, NULL, 0, resp, sizeof(resp), &got, 5000);
    printf("get rc=%d got=%u\n", rc, got);
    uint16_t vlen = 0;
    const uint8_t *r_sa = find_tlv(resp, got, 0x2C, &vlen);
    const uint8_t *r_nsa = find_tlv(resp, got, 0x2D, &vlen);
    if (r_sa) print_masks("SA ", r_sa);
    if (r_nsa) print_masks("NSA", r_nsa);

    p_release(client);
    return 0;
}
