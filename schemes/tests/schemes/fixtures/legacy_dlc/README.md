# Historical catalog validator fixtures

`cn_dlc.lua` and `stellae_dlc.lua` retain the earlier guarded catalog implementation for `Test-ChineseDlc.ps1` and `Test-ShardedDlc.ps1`. They are test fixtures and are excluded from production profiles.

Current Chinese DLC uses native dictionary pack activation. `Test-DlcProfile.ps1` checks the distributed profile and installed catalogs. `Test-EnglishDlc.ps1` checks the current English DLC reader.
