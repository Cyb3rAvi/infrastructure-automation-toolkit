# HP driver update loop (error 0x80246007)

Intune Remediation scripts for a Windows Update loop where the same HP printer driver is offered again and again.

## The problem

Windows Update keeps re-offering `Hewlett-Packard - USB - 4/8/2019 - 1.0.0.237` (HP LaserJet over USB). The install fails with `0x80246007`, then reports success, then comes back about every 6 days. Users see a daily update popup and a long "Working on updates" screen at restart. A newer copy of the driver is usually already in the driver store, so the repeated offer does nothing useful. It is a known HP and Windows Update issue with no published root cause.

## The fix

Hide only those driver updates on the affected devices, the same as Microsoft's "Show or hide updates" tool (`IUpdate.IsHidden = $true`). This is narrower than the Intune setting "Exclude WU drivers", which blocks every driver update.

| Script | Role | Changes anything? |
|--------|------|-------------------|
| `Detect-HpDriverUpdateLoop.ps1` | Survey (detection only, no remediation attached). Prints one line with a verdict: Looping, Pending, Hidden, PastFailures, Clean or Unknown. | No |
| `Detect-HpLoopUpdatesVisible.ps1` | Detection half of the fix. Exit 1 if a loop update is still visible. | No |
| `Remediate-HpLoopUpdatesHide.ps1` | Remediation half. Hides the matching updates and re-checks. | Hides updates in Windows Update only. No driver, policy or registry change. Reversible. |

The hide scope is only `Hewlett-Packard - USB - ...` and `HP Inc. - WSD Printer - HP Printer (BIDI)` driver updates.

## Intune settings

Run as SYSTEM (not logged-on credentials), 64-bit PowerShell, signature check off. Assign the survey to a broad group and the hide pair only to a small group of confirmed-affected devices.

`IsHidden` can only be set as SYSTEM on the device itself. Over PowerShell remoting it fails with `E_ACCESSDENIED`, so test through a temporary SYSTEM scheduled task or through Intune.
