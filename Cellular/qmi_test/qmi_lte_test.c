/* LTE band preference probe via QMI NAS Set System Selection Preference. */
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
static uint8_t g_resp[8192];
static size_t g_resp_len;

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

static int qmi_call(qmi_client_type client, uint16_t msg_id, const uint8_t *req, size_t req_len, const char *label) {
    unsigned int got = 0;
    int rc = p_send(client, msg_id, (void *)req, (unsigned int)req_len, g_resp, sizeof(g_resp), &got, 5000);
    if (rc != QMI_NO_ERR) { printf("%s: transport rc=%d\n", label, rc); return rc; }
    g_resp_len = got;
    const uint8_t *r = find_tlv(g_resp, g_resp_len, 0x02, NULL);
    if (r) {
        uint16_t result = (uint16_t)r[0] | ((uint16_t)r[1] << 8);
        uint16_t error  = (uint16_t)r[2] | ((uint16_t)r[3] << 8);
        if (result != 0) {
            printf("%s: QMI result=0x%04x error=0x%04x\n", label, result, error);
            return -1;
        }
    }
    return 0;
}

static void print_lte(void) {
    uint16_t vlen = 0;
    const uint8_t *lte = find_tlv(g_resp, g_resp_len, 0x15, &vlen);
    const uint8_t *ext = find_tlv(g_resp, g_resp_len, 0x23, &vlen);
    if (lte && vlen == 8) {
        uint64_t m = 0; memcpy(&m, lte, 8);
        printf("  LTE 0x15 mask=0x%016llx bands=", (unsigned long long)m);
        for (int i = 0; i < 64; i++) if ((m >> i) & 1) printf("%d ", i + 1);
        printf("\n");
    }
    if (ext && vlen == 32) {
        printf("  LTE 0x23 masks:");
        for (int j = 0; j < 4; j++) {
            uint64_t m = 0; memcpy(&m, ext + j * 8, 8);
            printf(" [%d]=0x%016llx", j, (unsigned long long)m);
        }
        printf("\n");
    }
}

static void print_serving(void) {
    uint16_t vlen = 0;
    const uint8_t *s = find_tlv(g_resp, g_resp_len, 0x01, &vlen);
    if (s && vlen >= 5) {
        printf("  serving: reg=0x%02x cs=0x%02x ps=0x%02x net=0x%02x radios=", s[0], s[1], s[2], s[3]);
        uint8_t n = s[4];
        for (int i = 0; i < n && 5 + i < vlen; i++) printf("0x%02x ", s[5 + i]);
        printf("\n");
    }
    const uint8_t *rf = find_tlv(g_resp, g_resp_len, 0x01, &vlen);
    (void)rf;
}

static void print_rf_band(void) {
    uint16_t vlen = 0;
    const uint8_t *l = find_tlv(g_resp, g_resp_len, 0x01, &vlen);
    if (l && vlen >= 1) {
        uint8_t n = l[0];
        printf("  rf_band: n=%u", n);
        for (int i = 0; i < n && 1 + i * 5 + 5 <= vlen; i++) {
            const uint8_t *e = l + 1 + i * 5;
            uint16_t band = (uint16_t)e[1] | ((uint16_t)e[2] << 8);
            uint16_t chan = (uint16_t)e[3] | ((uint16_t)e[4] << 8);
            printf(" [if=0x%02x band=0x%04x chan=%u]", e[0], band, chan);
        }
        printf("\n");
    }
}

static int set_lte(qmi_client_type client, uint64_t mask, const char *label) {
    uint8_t req[256];
    size_t req_len = 0;
    uint8_t mode[2] = {0x5f, 0x00};
    uint8_t duration = 0x00;
    add_tlv(req, &req_len, 0x11, mode, 2);
    add_tlv(req, &req_len, 0x17, &duration, 1);
    add_tlv(req, &req_len, 0x15, &mask, 8);

    printf("\n--- %s (mask=0x%016llx) ---\n", label, (unsigned long long)mask);
    int rc = qmi_call(client, 0x0033, req, req_len, "set");
    if (rc != 0) return rc;
    sleep(2);
    if (qmi_call(client, 0x0034, NULL, 0, "get_ssp") == 0) print_lte();
    if (qmi_call(client, 0x0024, NULL, 0, "get_serving") == 0) print_serving();
    if (qmi_call(client, 0x0031, NULL, 0, "get_rf_band") == 0) print_rf_band();
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
    qmi_client_type client = NULL;
    int rc = p_init(p_svc(1, 321, 6), QMI_CLIENT_INSTANCE_ANY, NULL, NULL, NULL, 5000, &client);
    printf("init rc=%d client=%p\n", rc, client);
    if (rc || !client) return 1;

    if (qmi_call(client, 0x0034, NULL, 0, "initial get_ssp") != 0) return 1;
    uint16_t vlen = 0;
    const uint8_t *lte = find_tlv(g_resp, g_resp_len, 0x15, &vlen);
    if (!lte || vlen != 8) { printf("no LTE mask\n"); return 1; }
    uint64_t original = 0;
    memcpy(&original, lte, 8);
    printf("original LTE mask=0x%016llx\n", (unsigned long long)original);
    print_lte();
    if (qmi_call(client, 0x0024, NULL, 0, "initial get_serving") == 0) print_serving();
    if (qmi_call(client, 0x0031, NULL, 0, "initial get_rf_band") == 0) print_rf_band();

    set_lte(client, 1ULL << 2, "LTE band 3 only"); /* current band */
    set_lte(client, 1ULL << 0, "LTE band 1 only"); /* different band */
    set_lte(client, original, "restore original LTE mask");

    p_release(client);
    return 0;
}
