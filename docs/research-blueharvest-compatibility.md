# BlueHarvest compatibility research

**Date:** 2026-09-02  
**Scope:** BlueHarvest’s documented behavior compared with DriveSweep’s macOS target. This is a source-based product-scope note; it does not change product code.

## Executive conclusion

BlueHarvest is broader than a physical-drive cleaner. Its vendor documentation describes:

- continuous deletion of `.DS_Store` and `._*` files as they are created or modified;
- connection-time policies for non-Mac disks and network disks, including an “ask what to do” mode;
- per-volume and per-folder clean/ignore rules, plus type/extension whitelisting;
- manual Finder/menu-bar cleaning, clean-and-eject, ZIP cleanup, scheduled cleaning, and a sizeable optional blacklist.

DriveSweep can be compatible with the useful part of that experience while remaining safer by keeping a deliberately smaller contract: physical, local, external, writable, mounted volumes only; fixed-name cleanup categories; explicit per-volume exclusions; mount-time reconciliation plus a user-invoked final pass; and no privileged helper or network-volume writes.

The most important safety boundary is AppleDouble. Apple documents that a `._name` sidecar can hold a resource fork, Finder information, extended attributes, or other metadata. BlueHarvest itself warns that deleting these files can make legacy fonts or EPS files unusable. Therefore, deleting `._*` is not a non-destructive operation even when the ordinary data file remains. It should be clearly labeled, previewable, and either disabled for automatic cleanup by default or enabled only for a user-selected portability volume with a whitelist.

## What BlueHarvest documents

The following is the vendor’s public contract, not an inference from third-party reviews.

### Core behavior and user-visible entry points

The [BlueHarvest product page](https://www.zeroonetwenty.com/blueharvest/index.html) says that it automatically removes `.DS_Store` and `._` AppleDouble files from USB keys, SD cards, music players, file servers, and other non-Mac disks, and removes them as they are created or modified. It also advertises a Finder control-click action, “Clean using BlueHarvest,” for a disk or folder, including ZIP archives; the archive action removes macOS metadata from the archive.

The [How To guide](https://www.zeroonetwenty.com/blueharvest/how-to.html) documents a menu-bar application, manual cleaning, and an option-key variant that ejects a disk after cleaning. It also documents clean/ignore rules for a particular disk or folder and a whitelist that can preserve AppleDouble files by file extension, macOS type code, folder, or volume.

### Volume classes and connection-time decisions

The [How To guide](https://www.zeroonetwenty.com/blueharvest/how-to.html) divides automatic policy into:

- **Non-Mac disks:** MS-DOS/FAT, ExFAT, and NTFS; the user chooses “Clean MacOS data” or “Ask what to do” when a disk connects.
- **Network disks:** SMB/CIFS, NFS, WebDAV, and AFP; the user chooses the same clean/ask policy, and the vendor says to contact the network administrator before use.
- **Specific disks/folders:** the user adds a source and chooses whether to ignore or clean it.

The [BlueHarvest FAQ](https://www.zeroonetwenty.com/blueharvest/frequently-asked-questions.html) makes the default boundary explicit: it removes metadata from non-Mac disks or servers, and does not remove `.DS_Store` from Mac disks unless the disk is explicitly added. This differs from a blanket “all external volumes” policy.

Apple’s [Disk Utility file-system guide](https://support.apple.com/en-gb/guide/disk-utility/dsku19ed921c/mac) describes APFS as the macOS file system and says APFS also works on external direct-attached storage; it identifies MS-DOS (FAT) and ExFAT as Windows-compatible formats. Apple also notes that built-in macOS can read NTFS but cannot write it in the ordinary case ([external-drive write support](https://support.apple.com/en-gb/101830)). A cleaner should therefore use the volume’s actual writability at runtime: do not assume that BlueHarvest’s NTFS support implies that every macOS installation can write NTFS.

### Documented cleanup categories

The [BlueHarvest FAQ](https://www.zeroonetwenty.com/blueharvest/frequently-asked-questions.html) lists these selectable items:

| Category | Vendor-documented names | Compatibility/safety interpretation |
| --- | --- | --- |
| Apple metadata | `._*`, `.DS_Store`, `.apdisk`, `.VolumeIcon.icns` | `._*` can carry meaningful Mac metadata; `.DS_Store` carries Finder presentation state. Do not treat either as universally disposable. |
| Mac/system folders | `.fseventsd` (disks only), `.Spotlight-V100` (disks only), `.TemporaryItems` (disks only), `.Trashes` (disks only) | These are volume-level state or recoverability-related folders, not ordinary clutter. Keep them opt-in; never empty `.Trashes` silently. |
| NAS/network | `.AppleDouble` folders (NAS/*NIX) | Network-server semantics differ from a local AppleDouble sidecar. Keep network cleanup outside the initial DriveSweep contract. |
| Windows/foreign OS | `Desktop.ini`, `Thumbs.ini`, `$Recycle.bin`, plus `System Volume Information` in the release notes | These can be useful to the other OS or to the device. Require an explicit “portable/share cleanup” policy rather than a global default. |
| User-defined | UNIX wildcard patterns, blacklist items, and (in v8.0) age-based blacklist deletion | Too broad for a safe first release; exact fixed names or a previewed allowlist are safer. |

The [release notes](https://www.zeroonetwenty.com/blueharvest/release-notes.html) add important version details:

- v7 added `Icon?`, `.com.apple.timemachine.donotpresent`, removable `.AppleDouble` folders, scheduled cleaning (every day, weekdays, or weekends), enabled/disabled blacklist items, an “Examine” preview, a built-in log viewer, and simultaneous cleaning of multiple sources.
- v7.2 added an option to keep custom icons and resources.
- v8.0 added storage cleanup for application caches/logs, age-based blacklist deletion, and `System Volume Information` deletion.
- v8.4 added `__MACOSX` deletion **off by default**, better deletion errors, more reliable clean-and-eject, and corrected `System Volume Information` handling.
- v8.2 added a user-visible “Force Eject” path for a busy disk; that is a compatibility feature, not a safe default.
- v8.5 added support for disks mounted in the user’s Application Support folder, which is outside DriveSweep’s proposed direct-attached `/Volumes` scope.

### Safety, permissions, and observability

BlueHarvest explicitly answers “Can BlueHarvest cause data loss?” **Yes.** Its [FAQ](https://www.zeroonetwenty.com/blueharvest/frequently-asked-questions.html) gives legacy Mac fonts and EPS files as examples and points to Advanced → Types for preserving selected types. The same FAQ says it logs deletions to Console and documents that deleting Spotlight folders may require Full Disk Access.

The vendor’s [support notice](https://www.zeroonetwenty.com/contact-support/) reports “Operation not permitted” failures for the App Store build on macOS Sequoia, while saying the direct-download build is not affected, and says the App Store listing was temporarily removed. This is a reason to handle permission failures visibly and to avoid promising that a particular distribution channel bypasses macOS privacy controls.

## macOS facts that constrain a compatible implementation

### AppleDouble is metadata, not merely junk

Apple’s archived but first-party [Files and the Finder](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFileSystem/Articles/FilesAndFinder.html) documentation explains that when Finder copies a file from a format that supports resource forks to one that does not, it writes the extra information to a hidden dot-underscore file such as `._MyMug.jpg`. When copying back, Finder looks for that sidecar and uses it to recreate resource forks and Finder attributes; if it is absent, those attributes are not recreated.

Apple’s first-party [`copyfile` manual page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/copyfile_state_free.3.html) defines metadata as permissions, extended attributes, ACLs, and related information. Its AppleDouble pack/unpack flags specifically include extended attributes, ACLs, resource forks, and FinderInfo. Apple’s [QA1510](https://developer.apple.com/library/archive/qa/qa1510/_index.html) also identifies `._*` as AppleDouble files produced when copying to a non-HFS+ volume and shows `dot_clean` as the removal tool.

**Implication:** a “remove `._*`” checkbox must be labeled as metadata loss. It should not be bundled into an unreviewed “safe junk” operation. A preview, type/path whitelist, and a post-clean log are appropriate. If an automatic mode is retained, the safest policy is to apply it only to a volume the user has marked for non-Mac sharing.

### `.DS_Store` is Finder state and is especially relevant on network shares

Apple’s [SMB browsing support article](https://support.apple.com/en-us/102064) says that macOS collects file metadata to determine how Finder windows appear and documents `.DS_Store` behavior on SMB shares. It provides a separate setting to stop writing `.DS_Store` files to network stores, which confirms that these files are Finder presentation state rather than user document content, but deleting them can still reset folder views, icon positions, or labels.

**Implication:** `.DS_Store` is lower risk than AppleDouble for ordinary data, but should still be scoped to a portability/share policy or an explicit volume selection. Do not infer that it is safe to write/delete on every network volume.

### Mounted-volume detection and identity

Apple’s [`NSFileManager` mounted-volume API](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls%28includingresourcevaluesforkeys%3Aoptions%3A%29?language=objc) returns URLs for mounted volumes and warns that the call may block while I/O is needed to obtain resource values. `NSVolumeEnumerationSkipHiddenVolumes` [skips hidden volumes](https://developer.apple.com/documentation/foundation/filemanager/volumeenumerationoptions/skiphiddenvolumes?language=objc).

Apple’s [`NSWorkspaceDidMountNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didmountnotification?language=objc) is posted when a new device mounts. The notification’s [`NSWorkspaceVolumeURLKey`](https://developer.apple.com/documentation/appkit/nsworkspace/volumeurluserinfokey?language=objc) contains the mount path. There is a corresponding [did-unmount notification](https://developer.apple.com/documentation/appkit/nsworkspace/didunmountnotification?language=objc).

The Foundation volume resource keys expose the properties needed for a fail-closed policy: [`NSURLVolumeIsInternalKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisinternalkey?language=objc) identifies a volume connected to an internal bus; [`NSURLVolumeIsReadOnlyKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisreadonlykey?language=objc) identifies read-only media; and the [volume status keys](https://developer.apple.com/documentation/foundation/urlresourcekey?language=objc) include local, ejectable, removable, automounted, browsable, root-file-system, type, UUID, and mount-source information.

**Implications:**

1. Reconcile already-mounted volumes at launch as well as observing mount events; a mount notification cannot report a volume that mounted before the app started.
2. Use stable volume identity (prefer the volume UUID/resource identifier) for remembered decisions and exclusions. A display name is not stable; the vendor’s v8.3 release note specifically records a fix for renamed disks being ignored.
3. Treat “external,” “removable,” “local,” “ejectable,” and “automounted” as different properties. An external USB SSD may be non-removable; a network volume may be mounted under `/Volumes`; and a disk image may be writable but still not a physical external disk.
4. Re-check eligibility immediately before deleting. A notification URL can become stale or be unmounted while a scan is queued.

### Privacy and write permission are user-controlled

Apple’s [macOS App Sandbox file-access guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox?changes=_4) says Full Disk Access cannot be granted by an entitlement or programmatically; the user must grant it in Privacy & Security. It also says an app should handle failure when access is not granted and lists POSIX permissions, ACLs, SIP, and data protection as other causes of failure.

Apple’s [security guide](https://support.apple.com/en-ie/guide/security/secddd1d86a6/web) says that, on macOS 10.15 and later, Files and Folders controls include network and removable volumes, while full storage access requires an explicit system privacy setting. Apple’s [Privacy & Security guide](https://support.apple.com/en-gb/guide/mac-help/mchl211c911f/mac) describes Full Disk Access as access to all files, including other apps’ data and Time Machine backups.

**Implication:** DriveSweep should not ask users for Full Disk Access merely to clean an ordinary writable external volume. It should skip or report protected paths, preserve a per-item error count, and never claim “clean” when deletion was denied. Network support should be a separate, explicit feature with an administrator-consent warning.

### Ejection is not a force-delete operation

Apple’s [`NSWorkspace` eject API](https://developer.apple.com/documentation/appkit/nsworkspace/unmountandejectdevice%28at%3A%29?language=objc) attempts to eject the volume and reports errors; Apple documents that it may fail when the volume is not ejectable. Apple’s [storage-device guide](https://support.apple.com/en-gb/guide/mac-help/-mchl027f1d66/mac) says that another app or user may be using files when ejection fails.

**Implication:** “Clean and eject” should first finish the selected cleanup, then request normal unmount/eject, and surface failure with a retry/instructions path. Do not force eject by default. BlueHarvest’s v8.2 Force Eject option should be considered an explicit expert action, if supported at all.

## Recommended compatibility boundary

This is the proposed safe subset for DriveSweep, ordered by priority. “Default” describes the recommended product behavior, not what BlueHarvest currently defaults to in every build.

| Priority | Capability | BlueHarvest compatibility | Recommended DriveSweep behavior | Default/risk |
| --- | --- | --- | --- | --- |
| P0 | Detect physical external volumes | BlueHarvest covers non-Mac disks and servers; its documented set is broader than physical media. | Include only mounted, local, non-root, physical external volumes that are writable. Use volume resource properties and machine-readable disk information; do not rely on a display name or `/Volumes` alone. | Always fail closed for internal, disk-image, network, hidden, or read-only volumes. |
| P0 | Fixed-name metadata cleanup | Core BlueHarvest behavior is `.DS_Store` + `._*`. | Keep separate toggles and separate status counts. Restrict automatic mode to a user-approved portability volume; provide a one-shot manual action for other eligible volumes. | `.DS_Store`: low/medium risk and preferably non-Mac/share scoped. `._*`: high risk; off for unattended cleanup or guarded by explicit opt-in + whitelist. |
| P0 | Manual clean | BlueHarvest exposes menu-bar/Finder clean. | Keep “Clean now” visible for each eligible volume and show what was found/removed/failed. | User initiated; preview or confirmation for high-risk categories. |
| P0 | Clean and eject | BlueHarvest supports an eject-after-clean action. | Clean, then call the normal `NSWorkspace` eject API; handle busy/non-ejectable errors and never imply force eject. | Safe default when invoked by the user; no automatic eject after mount cleanup. |
| P0 | Per-volume exclusion | BlueHarvest supports disk/folder ignore rules. | Persist an exclusion by stable volume UUID plus a user-visible name/path; keep name only as a fallback. Re-evaluate after renames and never clean if the exclusion cannot be resolved confidently. | Exclusions are fail-closed and easy to undo. |
| P1 | `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems` | BlueHarvest exposes them as optional disk-only categories; Spotlight can require Full Disk Access. | Keep as individually selectable advanced options, with explicit destructive/rebuildable descriptions and per-item errors. | Off. Emptying `.Trashes` must be described as deleting recoverable trash. |
| P1 | Whitelist and preview | BlueHarvest supports extension/type/folder/volume whitelisting and “Examine.” | Add a dry-run/preview and path/type exclusions before broadening AppleDouble cleanup. | Preview first for `._*`; preserve custom icons/resources by default. |
| P1 | Mount-time automation | BlueHarvest deletes as items are created/modified and offers clean/ask on connection. | Observe `NSWorkspaceDidMountNotification`, debounce until the volume is ready, clean at most once per mount identity, and reconcile already-mounted volumes at launch. Keep a manual final pass after copying. | Automatic mode is user-controlled; do not continuously race active file copies. |
| P1 | Scheduled scans / launch at login | Release notes document daily, weekday, weekend schedules and Open At Login. | Defer until mount/manual semantics are solid. If added, schedule only eligible user-approved volumes, show next run, and provide pause/disable controls. | Off until enabled; scheduled scans must be idempotent and logged. |
| P1 | File-system portability | BlueHarvest names MS-DOS/FAT, ExFAT, NTFS, SMB/CIFS, NFS, WebDAV, AFP. | Support direct-attached external formats only when the current mount is writable. Treat NTFS as unsupported/read-only unless a driver makes it writable. | Never try a delete on a read-only or permission-denied mount. |
| P2 | Network disks | BlueHarvest supports them but tells users to contact network administration; Apple TCC includes network volumes. | Out of initial scope. Add only with explicit per-share authorization, protocol-aware tests, and an admin warning. | Disabled; no background network writes. |
| P2 | ZIP/`__MACOSX` cleanup | BlueHarvest cleans ZIP archives; `__MACOSX` was added in v8.4 but is off by default. | Out of scope for a physical-volume cleaner. Treat archives as a separate feature with its own preview and atomic-write behavior. | Disabled. |
| P2 | Wildcard blacklist, app caches/logs, foreign-OS folders | BlueHarvest supports these as optional/advanced features. | Do not include in the safe baseline. Exact fixed names are easier to audit than arbitrary patterns; caches/logs are not external-drive metadata cleanup. | Disabled. |
| P2 | Force eject / privileged helper | BlueHarvest has a Force Eject option and a non-App-Store privileged helper. | Do not reproduce either in the baseline. Use user-authorized file operations and normal `NSWorkspace` eject. | Never automatic; avoid entirely unless a separate security review approves it. |

## Specific defaults and wording recommended for the UI

The following wording keeps BlueHarvest-compatible behavior understandable without calling metadata “junk”:

- **Automatic cleanup:** “When enabled, DriveSweep cleans this approved external volume once after it mounts. It does not monitor or delete files continuously.”
- **AppleDouble (`._*`):** “May contain Mac resource forks, Finder information, and extended attributes. Removing it can affect legacy Mac files. Preview and whitelist before enabling.”
- **`.DS_Store`:** “Finder folder-view metadata. Removing it may reset folder views; Finder can recreate it.”
- **`.Trashes`:** “Deletes items currently in the volume’s Trash; this removes their normal recovery path.”
- **Spotlight/events:** “Rebuildable system indexes/logs; macOS may recreate them and may deny access without user privacy approval.”
- **Clean and eject:** “Runs the selected cleanup, then asks macOS to eject. If another app is using the volume, ejection can fail.”
- **Failures:** report “N found, M removed, K skipped/failed” and keep failed paths/reasons in a local log. Never show a clean-success message when all selected operations were denied.

## Scope gaps to track explicitly

The current project README describes a narrower physical-volume product, while the current Objective-C implementation uses `NSFileManager` mounted-volume enumeration, a text match against `diskutil info`, fixed cleanup toggles, comma-separated volume-name exclusions, mount notifications, and a periodic reconciliation timer. Those are useful starting points, but the compatibility requirements above imply several future hardening items: stable volume identity, machine-readable device classification, explicit dry-run/error reporting, and AppleDouble warnings/whitelisting. See the local [README](../README.md) and [implementation](../Sources/main.m) for the baseline.

This note intentionally does not claim undocumented BlueHarvest internals, nor does it treat old reviews or search-result summaries as authoritative. Vendor pages and cached copies can lag one another, so version-specific claims above are anchored to the vendor’s dated [release notes](https://www.zeroonetwenty.com/blueharvest/release-notes.html) and should be rechecked before release.

## Primary sources

### BlueHarvest / zeroonetwenty (vendor)

1. [BlueHarvest product page](https://www.zeroonetwenty.com/blueharvest/index.html)
2. [BlueHarvest How To](https://www.zeroonetwenty.com/blueharvest/how-to.html)
3. [BlueHarvest FAQ](https://www.zeroonetwenty.com/blueharvest/frequently-asked-questions.html)
4. [BlueHarvest release notes](https://www.zeroonetwenty.com/blueharvest/release-notes.html)
5. [BlueHarvest support notice](https://www.zeroonetwenty.com/contact-support/)

### Apple

1. [Files and the Finder](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFileSystem/Articles/FilesAndFinder.html)
2. [`copyfile` AppleDouble/manual-page reference](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/copyfile_state_free.3.html)
3. [Technical Q&A QA1510: resolving invalid-signature failures](https://developer.apple.com/library/archive/qa/qa1510/_index.html)
4. [Adjust SMB browsing behavior in macOS](https://support.apple.com/en-us/102064)
5. [`NSFileManager` mounted-volume enumeration](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls%28includingresourcevaluesforkeys%3Aoptions%3A%29?language=objc)
6. [`NSWorkspaceDidMountNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didmountnotification?language=objc), [`NSWorkspaceVolumeURLKey`](https://developer.apple.com/documentation/appkit/nsworkspace/volumeurluserinfokey?language=objc), and [`NSWorkspaceDidUnmountNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didunmountnotification?language=objc)
7. [Foundation volume resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey?language=objc), including [internal](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisinternalkey?language=objc) and [read-only](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisreadonlykey?language=objc)
8. [`NSWorkspace` unmount/eject](https://developer.apple.com/documentation/appkit/nsworkspace/unmountandejectdevice%28at%3A%29?language=objc)
9. [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox?changes=_4)
10. [Controlling app access to files in macOS](https://support.apple.com/en-ie/guide/security/secddd1d86a6/web)
11. [Change Privacy & Security settings on Mac](https://support.apple.com/en-gb/guide/mac-help/mchl211c911f/mac)
12. [File-system formats available in Disk Utility](https://support.apple.com/en-gb/guide/disk-utility/dsku19ed921c/mac) and [external-drive write support](https://support.apple.com/en-gb/101830)
13. [Connect and use other storage devices with Mac](https://support.apple.com/en-gb/guide/mac-help/-mchl027f1d66/mac)
