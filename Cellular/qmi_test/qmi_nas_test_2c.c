/*
 * Minimal QMI NAS test for SM8350 / OnePlus 9 Pro.
 *
 * Uses the vendor libqmi_cci + libqmiservices service object and raw QMI
 * messages, so it does not need /dev/diag or the generated NAS headers.
 *
 * Build:
 *   aarch64-linux-android21-clang -O2 -o qmi_nas_test qmi_nas_test.c -ldl
 * Run as root:
 *   /data/local/tmp/qmi_nas_test
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <errno.h>

typedef void *qmi_client_type;
typedef void *qmi_idl_service_object_type;
typedef int qmi_client_error_type;

#define QMI_NO_ERR 0
#define QMI_CLIENT_INSTANCE_ANY 0xffff

typedef qmi_client_error_type (*qmi_client_init_instance_fn)(
        qmi_idl_service_object_type service_obj,
        unsigned int instance_id,
        void *ind_cb,
        void *ind_cb_data,
        void *os_params,
        uint32_t timeout,
        qmi_client_type *user_handle);

typedef qmi_client_error_type (*qmi_client_send_raw_msg_sync_fn)(
        qmi_client_type user_handle,
        unsigned int msg_id,
        void *req_buf,
        unsigned int req_buf_len,
        void *resp_buf,
        unsigned int resp_buf_len,
        unsigned int *resp_buf_recv_len,
        unsigned int timeout_msecs);

typedef qmi_client_error_type (*qmi_client_release_fn)(qmi_client_type user_handle);

typedef qmi_idl_service_object_type (*nas_get_service_object_fn)(int config, int service_id, int idl_version);

static qmi_client_send_raw_msg_sync_fn p_send_raw;
static qmi_client_release_fn p_release;

static uint8_t g_ssp[8192];
static size_t g_ssp_len;

static const uint8_t *find_tlv(const uint8_t *buf, size_t len, uint8_t type, uint16_t *vlen) {
    size_t off = 0;
    while (off + 3 <= len) {
        uint8_t t = buf[off];
        uint16_t l = (uint16_t)buf[off + 1] | ((uint16_t)buf[off + 2] << 8);
        if (off + 3 + l > len)
            return NULL;
        if (t == type) {
            if (vlen) *vlen = l;
            return buf + off + 3;
        }
        off += 3 + l;
    }
    return NULL;
}

static void hexdump(const void *data, size_t len) {
    const uint8_t *p = data;
    for (size_t i = 0; i < len; i++) {
        if (i && (i % 16) == 0) printf("\n");
        printf("%02x ", p[i]);
    }
    printf("\n");
}

static void add_tlv(uint8_t *buf, size_t *len, uint8_t type, const void *val, uint16_t vlen) {
    buf[*len + 0] = type;
    buf[*len + 1] = (uint8_t)(vlen & 0xff);
    buf[*len + 2] = (uint8_t)(vlen >> 8);
    if (vlen && val)
        memcpy(buf + *len + 3, val, vlen);
    *len += 3 + vlen;
}

static int parse_result(const uint8_t *buf, size_t len, uint16_t *result, uint16_t *error) {
    size_t off = 0;
    *result = 0xffff;
    *error = 0xffff;
    while (off + 3 <= len) {
        uint8_t type = buf[off];
        uint16_t vlen = (uint16_t)buf[off + 1] | ((uint16_t)buf[off + 2] << 8);
        const uint8_t *val = buf + off + 3;
        if (off + 3 + vlen > len) {
            printf("  [bad TLV: type=0x%02x len=%u remaining=%zu]\n", type, vlen, len - off - 3);
            return -1;
        }
        printf("  TLV 0x%02x len=%u", type, vlen);
        if (type == 0x02 && vlen >= 4) {
            *result = (uint16_t)val[0] | ((uint16_t)val[1] << 8);
            *error  = (uint16_t)val[2] | ((uint16_t)val[3] << 8);
            printf("  result=0x%04x error=0x%04x", *result, *error);
        } else if (vlen == 64) {
            printf("\n    masks:");
            for (int i = 0; i < 8; i++) {
                uint64_t m = 0;
                memcpy(&m, val + i * 8, 8);
                printf(" [%d]=0x%016llx", i, (unsigned long long)m);
            }
        } else if (vlen <= 32) {
            printf("  value=");
            for (uint16_t i = 0; i < vlen; i++) printf("%02x", val[i]);
        }
        printf("\n");
        off += 3 + vlen;
    }
    return 0;
}

static int send_msg(qmi_client_type client, uint16_t msg_id,
                    const uint8_t *req, size_t req_len,
                    uint8_t *resp, size_t resp_cap, size_t *resp_len) {
    unsigned int got = 0;
    int rc = p_send_raw(client, msg_id, (void *)req, (unsigned int)req_len,
                        resp, (unsigned int)resp_cap, &got, 5000);
    if (rc != QMI_NO_ERR) {
        printf("send msg 0x%04x failed: rc=%d (%s)\n", msg_id, rc, strerror(-rc));
        return rc;
    }
    *resp_len = got;
    printf("msg 0x%04x response %zu bytes\n", msg_id, *resp_len);
    uint16_t result = 0, error = 0;
    parse_result(resp, *resp_len, &result, &error);
    if (result != 0) {
        printf("  QMI result failure: result=0x%04x error=0x%04x\n", result, error);
        return -1;
    }
    return 0;
}

static int get_ssp(qmi_client_type client) {
    printf("\n=== Get System Selection Preference (0x0034) ===\n");
    int rc = send_msg(client, 0x0034, NULL, 0, g_ssp, sizeof(g_ssp), &g_ssp_len);
    return rc;
}

static int get_rf_band_info(qmi_client_type client) {
    uint8_t resp[8192];
    size_t resp_len = 0;
    printf("\n=== Get RF Band Information (0x0031) ===\n");
    return send_msg(client, 0x0031, NULL, 0, resp, sizeof(resp), &resp_len);
}

static int get_serving_system(qmi_client_type client) {
    uint8_t resp[8192];
    size_t resp_len = 0;
    printf("\n=== Get Serving System (0x0024) ===\n");
    return send_msg(client, 0x0024, NULL, 0, resp, sizeof(resp), &resp_len);
}

static void set_bit(uint64_t *mask, unsigned int band) {
    if (band < 512)
        mask[band / 64] |= (uint64_t)1 << (band % 64);
}

static int set_ssp(qmi_client_type client, int do_lte, int do_sa, int do_nsa,
                   const unsigned int *bands, size_t nbands, int permanent) {
    uint8_t req[1024];
    size_t req_len = 0;
    memset(req, 0, sizeof(req));

    /* Mode preference: LTE + 5GNR (0x10 | 0x40).  If only SA is wanted,
     * use 0x40 instead; if NSA is wanted, LTE must also be enabled. */
    uint16_t mode = 0x10 | 0x40;
    add_tlv(req, &req_len, 0x11, &mode, sizeof(mode));

    /* Change duration: 0x00 = power cycle, 0x01 = permanent. */
    uint8_t duration = permanent ? 0x01 : 0x00;
    add_tlv(req, &req_len, 0x17, &duration, sizeof(duration));

    uint64_t lte_mask[4] = {0};
    uint64_t nr_mask[8] = {0};
    for (size_t i = 0; i < nbands; i++)
        set_bit(nr_mask, bands[i]);

    if (do_lte) {
        /* LTE band 1/3/8/28/41/78?  Keep a broad mask; the NR mask is the
         * interesting part.  Bit N-1 corresponds to EUTRAN band N. */
        const unsigned int lte_bands[] = {1, 3, 5, 8, 28, 34, 38, 39, 40, 41};
        for (size_t i = 0; i < sizeof(lte_bands)/sizeof(lte_bands[0]); i++) {
            unsigned int b = lte_bands[i];
            if (b >= 1 && b <= 256)
                lte_mask[(b - 1) / 64] |= (uint64_t)1 << ((b - 1) % 64);
        }
        add_tlv(req, &req_len, 0x24, lte_mask, sizeof(lte_mask));
    }
    if (do_sa)
        add_tlv(req, &req_len, 0x2F, nr_mask, sizeof(nr_mask));
    if (do_nsa)
        add_tlv(req, &req_len, 0x30, nr_mask, sizeof(nr_mask));

    printf("\n=== Set System Selection Preference (0x0033) ===\n");
    printf("  mode=0x%04x duration=%u lte=%d sa=%d nsa=%d bands=", mode, duration, do_lte, do_sa, do_nsa);
    for (size_t i = 0; i < nbands; i++) printf("n%u ", bands[i]);
    printf("\n  request TLVs:\n");
    hexdump(req, req_len);

    uint8_t resp[4096];
    size_t resp_len = 0;
    return send_msg(client, 0x0033, req, req_len, resp, sizeof(resp), &resp_len);
}

static int probe_band_mask(qmi_client_type client) {
    uint16_t vlen = 0;
    const uint8_t *mode = find_tlv(g_ssp, g_ssp_len, 0x11, &vlen);
    const uint8_t *lte = find_tlv(g_ssp, g_ssp_len, 0x15, &vlen);
    const uint8_t *lte_ext = find_tlv(g_ssp, g_ssp_len, 0x23, &vlen);
    const uint8_t *sa = find_tlv(g_ssp, g_ssp_len, 0x2C, &vlen);
    const uint8_t *nsa = find_tlv(g_ssp, g_ssp_len, 0x2D, &vlen);
    if (!mode || !lte || !lte_ext || !sa || !nsa) {
        printf("probe: missing TLVs in current SSP (mode=%p lte=%p lte_ext=%p sa=%p nsa=%p)\n",
               mode, lte, lte_ext, sa, nsa);
        return -1;
    }

    uint8_t orig_sa[64], orig_nsa[64];
    memcpy(orig_sa, sa, 64);
    memcpy(orig_nsa, nsa, 64);

    uint8_t req[1024];
    size_t req_len = 0;
    uint8_t duration = 0x00; /* power cycle */
    uint64_t nr[8] = {0};
    nr[78 / 64] |= (uint64_t)1 << (78 % 64); /* n78 only */

    add_tlv(req, &req_len, 0x11, mode, 2);
    add_tlv(req, &req_len, 0x17, &duration, 1);
    add_tlv(req, &req_len, 0x15, lte, 8);
    add_tlv(req, &req_len, 0x24, lte_ext, 32);
    add_tlv(req, &req_len, 0x2C, nr, 64);
    add_tlv(req, &req_len, 0x2D, nr, 64);

    printf("\n=== PROBE: set NR5G SA+NSA mask to n78 only (TLV 0x2F/0x30) ===\n");
    uint8_t resp[4096];
    size_t resp_len = 0;
    int rc = send_msg(client, 0x0033, req, req_len, resp, sizeof(resp), &resp_len);
    if (rc != 0) return rc;

    get_ssp(client);
    const uint8_t *new_sa = find_tlv(g_ssp, g_ssp_len, 0x2C, &vlen);
    const uint8_t *new_nsa = find_tlv(g_ssp, g_ssp_len, 0x2D, &vlen);
    if (new_sa && new_nsa) {
        printf("probe: readback SA  mask0=0x%016llx mask1=0x%016llx\n",
               (unsigned long long)((const uint64_t *)new_sa)[0],
               (unsigned long long)((const uint64_t *)new_sa)[1]);
        printf("probe: readback NSA mask0=0x%016llx mask1=0x%016llx\n",
               (unsigned long long)((const uint64_t *)new_nsa)[0],
               (unsigned long long)((const uint64_t *)new_nsa)[1]);
    }

    /* Restore the original masks. */
    req_len = 0;
    add_tlv(req, &req_len, 0x11, mode, 2);
    add_tlv(req, &req_len, 0x17, &duration, 1);
    add_tlv(req, &req_len, 0x15, lte, 8);
    add_tlv(req, &req_len, 0x24, lte_ext, 32);
    add_tlv(req, &req_len, 0x2F, orig_sa, 64);
    add_tlv(req, &req_len, 0x30, orig_nsa, 64);
    printf("\n=== RESTORE original NR5G masks ===\n");
    rc = send_msg(client, 0x0033, req, req_len, resp, sizeof(resp), &resp_len);
    if (rc != 0) return rc;
    get_ssp(client);
    return 0;
}

int main(int argc, char **argv) {
    void *h_cci = dlopen("/vendor/lib64/libqmi_cci.so", RTLD_NOW);
    void *h_svc = dlopen("/vendor/lib64/libqmiservices.so", RTLD_NOW);
    if (!h_cci || !h_svc) {
        printf("dlopen failed: %s\n", dlerror());
        return 1;
    }

    qmi_client_init_instance_fn p_init = (qmi_client_init_instance_fn)dlsym(h_cci, "qmi_client_init_instance");
    p_send_raw = (qmi_client_send_raw_msg_sync_fn)dlsym(h_cci, "qmi_client_send_raw_msg_sync");
    p_release = (qmi_client_release_fn)dlsym(h_cci, "qmi_client_release");
    nas_get_service_object_fn p_get_svc = (nas_get_service_object_fn)dlsym(h_svc, "nas_get_service_object_internal_v01");
    if (!p_init || !p_send_raw || !p_release || !p_get_svc) {
        printf("dlsym failed: init=%p send=%p release=%p svc=%p (%s)\n",
               p_init, p_send_raw, p_release, p_get_svc, dlerror());
        return 1;
    }

    int err = 0;
    (void)err;
    qmi_idl_service_object_type svc = p_get_svc(1, 321, 6);
    printf("NAS service object=%p\n", svc);
    if (!svc) {
        printf("NAS service object accessor returned NULL (wrong config/id/version?)\n");
        return 1;
    }

    qmi_client_type client = NULL;
    int rc = p_init(svc, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, NULL, 5000, &client);
    printf("qmi_client_init_instance rc=%d client=%p\n", rc, client);
    if (rc != QMI_NO_ERR || !client) return 1;

    get_ssp(client);
    get_serving_system(client);
    get_rf_band_info(client);

    if (argc >= 2 && strcmp(argv[1], "probe") == 0) {
        probe_band_mask(client);
    } else if (argc >= 2 && strcmp(argv[1], "set") == 0) {
        unsigned int bands[16];
        size_t n = 0;
        for (int i = 2; i < argc && n < 16; i++) {
            int b = atoi(argv[i]);
            if (b > 0) bands[n++] = (unsigned int)b;
        }
        if (n == 0) { bands[n++] = 78; }
        int do_sa = 1, do_nsa = 1, do_lte = 1;
        int permanent = 0;
        set_ssp(client, do_lte, do_sa, do_nsa, bands, n, permanent);
        printf("\n--- readback after set ---\n");
        get_ssp(client);
        get_serving_system(client);
        get_rf_band_info(client);
    }

    p_release(client);
    return 0;
}
