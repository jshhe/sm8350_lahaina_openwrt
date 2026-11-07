# qmi_test

QMI NAS band-lock experiments for OnePlus 9 Pro `LE2120` (SM8350 `lahaina`).

**Read the full handoff document first:**

- [`../README.md`](../README.md)

It covers:

- why `/dev/diag` is not needed for QMI band preference;
- the correct Set/Get TLV IDs (`0x2F`/`0x30` vs `0x2C`/`0x2D`);
- the NR5G / LTE bit mapping;
- async readback and reselection;
- SELinux / vendor-lib caveats;
- restore and safety rules;
- next development backlog.

## Files

| File | Purpose |
|---|---|
| `qmi_nas_test.c` | Read SSP / Serving / RF Band. `set` mode is destructive. |
| `qmi_band_set.c` | Set SA/NR band masks for CA tests (n41 / n41+n79 / restore). |
| `qmi_probe.c` | TLV probe for `0x2F/0x30`, `0x2C/0x2D`, LTE `0x15/0x24`. Destructive. |
| `qmi_lte_test.c` | LTE band 3 / band 1 test. Restores only `0x15`. |
| `qmi_restore_lte.c` | Restore full LTE extended mask via `0x24`. |
| `qmi_restore_nr.c` | Restore SA/NSA masks. |
| `qmi_set_n78.c` | Verify n78 mapping (`mask[1] bit 13 = 0x2000`) and restore. |
| `dlopen_test.c` | Check whether vendor libs can be `dlopen`ed. |
| `qmi_nas_test_2c.c` | Negative test: `0x2C` in Set. |

## Build

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Or set `ANDROID_NDK_HOME` first:

```powershell
$env:ANDROID_NDK_HOME = "$env:LOCALAPPDATA\Android\Sdk\ndk\<version>"
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

## Safety

Do **not** run the destructive tools until you have read the handoff document and saved the current masks.
