/* QMI NAS Set System Selection Preference TLV probe. */
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
static release_fn p_release;
static uint8_t g_ssp[8192];
static size_t g_ssp_len;

struct tlv { uint8_t type; const void *val; uint16_t len; };

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

static void add_tlv(uint8_t *buf, size_t *len, uint8_t type, const void *val, uint16_t vlen) {
    buf[*len + 0] = type;
    buf[*len + 1] = (uint8_t)(vlen & 0xff);
    buf[*len + 2] = (uint8_t)(vlen >> 8);
    if (vlen && val) memcpy(buf + *len + 3, val, vlen);
    *len += 3 + vlen;
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

static int get_ssp(qmi_client_type client) {
    unsigned int got = 0;
    int rc = p_send(client, 0x0034, NULL, 0, g_ssp, sizeof(g_ssp), &got, 5000);
    if (rc != QMI_NO_ERR) { printf("  get_ssp rc=%d\n", rc); return rc; }
    g_ssp_len = got;
    return 0;
}

static int do_set(qmi_client_type client, const char *label, struct tlv *tlvs, int n) {
    uint8_t req[2048];
    size_t req_len = 0;
    for (int i = 0; i < n; i++)
        add_tlv(req, &req_len, tlvs[i].type, tlvs[i].val, tlvs[i].len);
    uint8_t resp[4096];
    unsigned int got = 0;
    printf("\n--- %s ---\n", label);
    int rc = p_send(client, 0x0033, req, (unsigned int)req_len, resp, sizeof(resp), &got, 5000);
    if (rc != QMI_NO_ERR) { printf("  transport rc=%d\n", rc); return rc; }
    uint16_t result = 0xffff, error = 0xffff;
    const uint8_t *r = find_tlv(resp, got, 0x02, NULL);
    if (r) {
        result = (uint16_t)r[0] | ((uint16_t)r[1] << 8);
        error  = (uint16_t)r[2] | ((uint16_t)r[3] << 8);
    }
    printf("  QMI result=0x%04x error=0x%04x\n", result, error);
    if (result != 0) return -1;
    sleep(2);
    get_ssp(client);
    uint16_t vlen;
    const uint8_t *sa = find_tlv(g_ssp, g_ssp_len, 0x2C, &vlen);
    const uint8_t *nsa = find_tlv(g_ssp, g_ssp_len, 0x2D, &vlen);
    if (sa) print_masks("readback SA ", sa);
    if (nsa) print_masks("readback NSA", nsa);
    return 0;
}

int main(void) {
    void *h_cci = dlopen("/vendor/lib64/libqmi_cci.so", RTLD_NOW);
    void *h_svc = dlopen("/vendor/lib64/libqmiservices.so", RTLD_NOW);
    if (!h_cci || !h_svc) { printf("dlopen: %s\n", dlerror()); return 1; }
    init_fn p_init = (init_fn)dlsym(h_cci, "qmi_client_init_instance");
    p_send = (send_fn)dlsym(h_cci, "qmi_client_send_raw_msg_sync");
    p_release = (release_fn)dlsym(h_cci, "qmi_client_release");
    svc_fn p_svc = (svc_fn)dlsym(h_svc, "nas_get_service_object_internal_v01");
    if (!p_init || !p_send || !p_release || !p_svc) { printf("dlsym failed\n"); return 1; }
    qmi_idl_service_object_type svc = p_svc(1, 321, 6);
    qmi_client_type client = NULL;
    int rc = p_init(svc, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, NULL, 5000, &client);
    printf("init rc=%d client=%p\n", rc, client);
    if (rc || !client) return 1;

    get_ssp(client);
    uint16_t vlen;
    const uint8_t *mode = find_tlv(g_ssp, g_ssp_len, 0x11, &vlen);
    const uint8_t *lte = find_tlv(g_ssp, g_ssp_len, 0x15, &vlen);
    const uint8_t *lte_ext = find_tlv(g_ssp, g_ssp_len, 0x23, &vlen);
    const uint8_t *sa = find_tlv(g_ssp, g_ssp_len, 0x2C, &vlen);
    const uint8_t *nsa = find_tlv(g_ssp, g_ssp_len, 0x2D, &vlen);
    if (!mode || !lte || !lte_ext || !sa || !nsa) { printf("missing TLVs\n"); return 1; }

    uint8_t mode_buf[2], lte_buf[8], lte_ext_buf[32], sa_buf[64], nsa_buf[64];
    memcpy(mode_buf, mode, 2);
    memcpy(lte_buf, lte, 8);
    memcpy(lte_ext_buf, lte_ext, 32);
    memcpy(sa_buf, sa, 64);
    memcpy(nsa_buf, nsa, 64);
    uint8_t duration = 0x00;
    uint64_t n78[8] = {0};
    n78[78 / 64] |= (uint64_t)1 << (78 % 64);

    struct tlv base[] = {
        {0x11, mode_buf, 2},
        {0x17, &duration, 1},
    };
    struct tlv lte_tlvs[] = {
        {0x11, mode_buf, 2},
        {0x17, &duration, 1},
        {0x15, lte_buf, 8},
        {0x24, lte_ext_buf, 32},
    };
    struct tlv sa_orig[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x2F, sa_buf, 64},
    };
    struct tlv sa_n78[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x2F, n78, 64},
    };
    struct tlv nsa_orig[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x30, nsa_buf, 64},
    };
    struct tlv nsa_n78[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x30, n78, 64},
    };
    struct tlv both_n78[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x2F, n78, 64}, {0x30, n78, 64},
    };
    struct tlv sa2c_n78[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x2C, n78, 64},
    };
    struct tlv sa2d_n78[] = {
        {0x11, mode_buf, 2}, {0x17, &duration, 1}, {0x2D, n78, 64},
    };

    uint64_t lte_b3[4] = {1ULL << 2, 0, 0, 0};
    uint64_t lte_zero[4] = {0, 0, 0, 0};

    do_set(client, "base (mode+duration only)", base, 2);
    do_set(client, "base + LTE 0x15/0x24", lte_tlvs, 4);
    do_set(client, "LTE 0x15 original mask", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x15,lte_buf,8}}, 3);
    do_set(client, "LTE 0x24 original mask", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x24,lte_ext_buf,32}}, 3);
    do_set(client, "LTE 0x15 band3 only", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x15,lte_b3,8}}, 3);
    do_set(client, "LTE 0x24 band3 only", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x24,lte_b3,32}}, 3);
    do_set(client, "LTE 0x15 zero mask", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x15,lte_zero,8}}, 3);
    do_set(client, "LTE 0x24 zero mask", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x24,lte_zero,32}}, 3);
    do_set(client, "restore LTE 0x15 original", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x15,lte_buf,8}}, 3);
    do_set(client, "restore LTE 0x24 original", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x24,lte_ext_buf,32}}, 3);
    do_set(client, "SA 0x2F original mask", sa_orig, 3);
    do_set(client, "SA 0x2F n78 only", sa_n78, 3);
    do_set(client, "restore SA 0x2F original", sa_orig, 3);
    do_set(client, "NSA 0x30 original mask", nsa_orig, 3);
    do_set(client, "NSA 0x30 n78 only", nsa_n78, 3);
    do_set(client, "restore NSA 0x30 original", nsa_orig, 3);
    do_set(client, "SA+NSA 0x2F/0x30 n78 only", both_n78, 4);
    do_set(client, "restore SA+NSA 0x2F/0x30 original", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x2F,sa_buf,64},{0x30,nsa_buf,64}}, 4);
    do_set(client, "SA 0x2C n78 only (wrong id?)", sa2c_n78, 3);
    do_set(client, "SA 0x2D n78 only (wrong id?)", sa2d_n78, 3);
    do_set(client, "final restore SA+NSA 0x2F/0x30 original", (struct tlv[]){{0x11,mode_buf,2},{0x17,&duration,1},{0x2F,sa_buf,64},{0x30,nsa_buf,64}}, 4);

    p_release(client);
    return 0;
}
