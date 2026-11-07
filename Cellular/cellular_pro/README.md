# Cellular Pro APK / vendor lib artifacts

These are analysis artifacts pulled from the device for the Cellular Pro investigation.
They are **not** part of the QMI band-lock tool; the main handoff is [`../README.md`](../README.md).

| File | Source / purpose |
|---|---|
| `base.apk` | `make.more.r2d2.cellular_pro` 1.9.10.1, pulled from `/data/app/...` |
| `libQualcommAdapter.so` | App native adapter; packed/obfuscated, strings inspected |
| `libdiag.so` | `/vendor/lib64/libdiag.so`, userspace diag library |
| `libqmi.so` | `/vendor/lib64/libqmi.so`, QMI wrapper |
| `libqmi_cci.so` | `/vendor/lib64/libqmi_cci.so`, QCCI client |
| `libqmiservices.so` | `/vendor/lib64/libqmiservices.so`, generated service objects |
| `libqmi_client_qmux.so` | `/vendor/lib64/libqmi_client_qmux.so`, QMUX transport |
| `apk/` | Extracted APK contents (classes.dex, resources, libs) |

Large binaries (`*.apk`, `*.so`, `apk/`) are ignored by `.gitignore`; only this README and notes should be committed.

Key findings from these artifacts are summarized in [`../README.md`](../README.md):

- `port_init_hint` English is "Port is initializing, please wait a moment."; Chinese is a misleading "设备无法获取到权限".
- `libQualcommAdapter.so` contains `/dev/smd11`, `/dev/smd8`, `DMPortTest`, `LOCK_LTE_BAND`, `LOCK_NR_BAND`, `LA0B0/nv;`.
- The app's pro mode depends on legacy SMD/AT/diag ports; it does not use the QMI NAS path.
