# ChipBar 2.0 · Motion-first Preview

**Branch:** `chipbar-2.0-motion-first-preview`  
**Development bundle version:** `2.0.0`  
**Release policy:** development CI artifact only; do **not** merge/publish until user tests UI transitions and authorizes a stable Release.

## Product direction

Keep original two-line status-bar design, signature watts typography and restrained native Liquid Glass. Make the 370-point popup a focused, layered dashboard. Design for comfortable trackpad scrolling and expressive but unobtrusive interactions.

## Implemented in first 2.0 development build

1. **Hierarchy** — power, animated utilization rings, app ranking, and power trend remain immediately visible. A unified System Details disclosure reveals built-in storage, fan telemetry, and external SSD information, while memory/temperature summaries remain visible.
2. **Shared visual components** — `ChipBarMotion`, `ChipBarPressStyle`, `ChipBarSectionToggle`, `PowerMetricCard`, `AnimatedMetricValue`, and `CapacityProgressTrack` replace duplicated, uncoordinated controls. Controls animate press feedback and state transitions, respecting Reduce Motion.
3. **Sampling/view decoupling, phase 1** — `PanelLayoutCoordinator` coalesces expensive `NSHostingView.fittingSize` checks instead of measuring on every sensor update. Bounds notifications defer automatic resizing during scrolling momentum. The internal storage model reuses cached results when its view is remounted.
4. **Motion stability** — preserve the existing animated settings navigation and AppKit window-height easing; wait for the new section spring to settle before measuring, prevent jumping to the top for system disclosure, and preserve scroll offsets.
5. **Automated checks** — unit coverage for sample bursts, scroll deferral and cancelling stale resize requests; existing UI QA checks settings round-trip, disclosure frame integrity and interrupted navigation.

## Stats-inspired per-logical-core CPU overview and refresh-control appearance

- **Native per-core CPU activity:** query `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` from a low-priority Swift actor; compare cumulative USER/SYSTEM/NICE/IDLE ticks over successive samples, wrap-safe using 32-bit differences. Each column is one *logical* CPU, numbered 1..N. Do not infer E/P-core types from enumeration order.
- **Sampling and lifecycle:** CPU-only Mach sampling respects the selected 1/2/5/10-second interval, pauses whenever the monitoring panel is hidden or the power collector is paused/asleep, and requires no subprocess, sudo, Accessibility, Screen Recording or Apple private APIs. Maintain one shared model across quick page transitions, restarting with fresh tick baseline where appropriate.
- **Compact UI:** CPU/GPU/memory rings shrink from 70pt to 52pt, utilizing 5pt strokes and smaller center labels. The main power trend shrinks from 95pt to 64pt. A fixed-height horizontal vertical-bar chart directly below the rings displays every logical core and shows exact rounded percent on hover and VoiceOver. Real-time samples animate bar fill but never alter chart height or the main glass panel geometry.
- **Refresh-rate entry flicker:** replace the native segmented `Picker` (`NSSegmentedControl` under macOS) with a plain SwiftUI-only 4-way segmented button row using stable material-neutral fills (`Color.primary.opacity`), an animated selection track and Reduce Motion support. The original control's momentary dark fill on navigating into Device & Settings should therefore no longer occur. Light/dark navigation needs physical-Mac verification.
- **Regression tests:** CPU tick independent-load computation, wrap-around, zero-elapsed samples, changing CPU counts, and on-device unprivileged Mach reading. Source inspiration: Stats' `Modules/CPU/readers.swift`; no Stats implementation or assets copied.

## Unified Device & Settings page, and minimal application ranking

- Replace separate **System Details** and **Settings** destinations with a single **设备与设置** page accessible from the Home footer. The old `--system-details` automation alias displays the same page; the normal app uses only one visible secondary destination.
- Display nonprivileged **Mac model identifier** (from `hw.model`), **Apple chip name** (from the existing macmon sample), **macOS version**, **installed physical RAM**, and **CPU core count**. Do not infer a marketing model name from an unverified identifier and do not request a serial number or extra permission.
- Keep the hardware section (fans, optional external SSD temperature/I/O/SMART) above the existing settings controls. All internal/external capacity bars remain on Home.
- The secondary page is still inside the same native-glass NSPanel viewport. AppKit's glass, NSHostingView and NSPanel now share one **effective light/dark appearance during each panel session**, so a focus change while opening a settings Picker does not allow the SwiftUI content to briefly disagree with the material. A future OS-level theme change is applied the next time the panel opens; do not force an appearance solely for the navigation state.
- Remove **all per-app percentage bars** from CPU/GPU/Memory/ANE rankings. Icons, index, names, values and 280 ms layered switch animations remain, with a fixed row height and no new samples.
- Test updated Swift data model and first-page reset, then validate live dark/light navigation and rapid switching on the target Mac mini. Ad-hoc CI signing and previously noted OS permission limits are unchanged.

## Home storage capacity grouping and icon-aligned application tracks

- **Home Storage overview:** Built-in macOS boot storage and all *mounted external disk volumes* show availability, used amount, total filesystem capacity and a thin used-space progress track in **one common card**. Capacity is visible immediately on Home, not gated behind System Details or SSD details.
- **Reliable data without SMART:** Internal storage uses macOS APFS Data capacity with internal-device verification. External capacity comes from IOKit + Disk Arbitration rather than from optional `smartctl`, so turning off SSD temperature monitoring does not hide storage space. Both caches refresh around every 30 seconds while visible. Readings do not require administrator rights.
- **APFS shared space:** Shared APFS volumes on the same physical disk with identical reported capacities are displayed only once; never add those filesystem totals together. If independent external volumes exist, show a separate track for each. If none is mounted, indicate that instead of guessing a capacity.
- **Secondary System Details:** Reserved for fans, SSD temperature, disk I/O speed and optional SMART sensors / health. Duplicate capacity labels and redundant volume scans have been removed.
- **Application rank track alignment:** each usage strip begins exactly at the left edge of the 15pt application icon after the 15pt rank number and 7pt HStack spacing. No change to data sampling or layered CPU/GPU/memory/ANE transitions.
- **Validation:** core formatting, macOS volume access and APFS grouping tests; CI build plus actual Mac mini visual check. Disk utility's capacity figures can differ from APFS purgeable space or system storage categories.

## New 2.0 UX preview — system page and layered app switch

This iteration implements the user-approved Stats-inspired information hierarchy while retaining ChipBar's own 370-pt Liquid Glass style and monitoring semantics:

- **Home** — CPU/GPU/ANE power cards now include slim, bounded micro-sparklines sourced from actual recent power samples; utilization rings, application activity, main 10-minute trend, memory pressure, and a compact chevron navigation card remain visible.
- **System Details** — no longer grows a disclosure under the Home page. A dedicated page with a native Back button contains built-in storage, fan and enabled external SSD status (including optional SMART details). Uses the **same fixed AppKit viewport height** as Home, so switching pages does not trigger a separate NSPanel resize or vertical jump.
- **Settings** — same fixed-size navigation behavior and native inertial scrolling, with independent navigation crossfade. The clip view resets to its top when changing pages; history and user preferences are preserved.
- **CPU/GPU/Memory/ANE** — each metric has an independently keyed ranking view with the *correct metric data*. Switching triggers a 280 ms layered transition: the outgoing list recedes to 94% and fades behind, while the incoming list appears above from a 14-point upward offset with a slight scale. The segmented choice retains its spring-moving selection highlight. Reduced Motion disables the spatial transition.
- **Ranked applications** — real app icons are cached (not decoded every power sample), name/number retain consistent geometry, and small per-metric normalized value tracks highlight relative use. Ranking viewport stays fixed at 3/5 row heights so sampling and metric changes do not resize the glass popup.
- **Performance** — curves are limited to the last 24 samples with a single Path per card; no extra system polling. Existing shared sampling and scroll-quiet layout coordination remain intact.

This is a **developer preview**, not stable. Real M5 Pro high-refresh-rate evaluation remains necessary, particularly rapid back-and-forth metric switching, Settings/Home/System navigation, process icon first loading and full-height trackpad scrolling. All sample rates and monitoring data source semantics are unchanged.

## M5 Pro user testing: confirmed and follow-up corrections

The user has checked all six baseline interaction criteria on the first 2.0 preview: quick Settings/Back cycling, smooth System Details frame movement, native trackpad scrolling, updates during scroll, animated rings synchronized with numbers, and dark/light/Reduce Motion compatibility.

The next 2.0 preview preserves that tested motion baseline and addresses reported issues:

- **Every open resets ephemeral UI:** always return to monitoring (not Settings), app top three in CPU mode, System Details closed, SSD subdetails closed and power trend set to chip total. Actual preferences and sampling history are **not erased**. Existing `--apps`, `--apps-gpu`, `--apps-ane`, `--ssd-details` and `--system-details` QA command flags still work.
- **Hide system scroll indicator:** `NSScrollView.hasVerticalScroller = false`, while the native trackpad and momentum scrolling remain enabled. This avoids the bright white indicator obscuring the Liquid Glass edge.
- **Animated app metric selection:** 4-way CPU/GPU/Memory/ANE indicator moves with a spring and presses respond immediately. Ranking contents crossfade within a fixed height, so switching tabs does not resize the window or jolt scroll position.
- **Stable signing support:** by default GitHub builds still use ad-hoc signing. macOS can treat each rebuilt ad-hoc executable as a new code identity and ask for privacy permissions again; the program cannot and must not silently bypass the system prompt. Developers with a valid and persistent macOS code-signing certificate can use `CHIPBAR_CODESIGN_IDENTITY="Apple Development: ..." ./scripts/build.sh` to sign successive local builds with the same Team ID and bundle ID. This is **optional** and does not imply notarization or promise to eliminate all possible consent dialogs. Install/test the same app path, close old ChipBar instances first, and avoid changing the signing identity between builds. No accessibility/screen-capture privilege is requested by a normal ChipBar launch; synthetic mouse-automation QA explicitly needs existing event-posting permission.

## M5 Pro performance follow-up: system details and 1.3.17 comparison

**Observed symptom:** The user reported a noticeable pause when expanding System Details after previously verifying smooth trackpad scrolling, animation synchronization, and rapid settings navigation. A smooth sequence can still *feel* slow if the first visible response is delayed.

**Code-level cause:** The first 2.0 preview ran the `navigateSettings(resetScroll: false)` path on System Details: it slept **420 ms** before measuring `fittingSize.height`, then ran **340 ms** of NSPanel height animation. The popup thus appeared to wait before responding, while mounting internal / external disk views could start IOKit and APFS reads during the transition.

**Change:** Dedicated `animateSystemDisclosure()` predicts the destination immediately: on the first expansion it animates toward the available viewport height, and after the animation caches the real SwiftUI document height for subsequent toggles. It only applies a short (~170 ms) correction if measurement is different. Opening and closing remain cancelable by generation token, use the same timing curve and protect the scroller offset. The internal and external storage cards defer their initial APFS / disk scanning until after the ~340 ms spring and are canceled if collapsed beforehand.

**What this proves:** The prior serialized **420 + 340 ms** wait has been removed from the code. It does **not** prove zero visual hitches on the M5 Pro; actual FPS, frame-time outliers and per-process load require a hardware trace.

### CPU and memory comparison against v1.3.17

Do not claim that the preview uses fewer CPU cycles or less RAM without paired measurements. Most source readers and the 2 s application sampler are still shared with v1.3.17. The 2.0 branch adds UI components and caches and defers some work, so its idle and interactive performance must be measured separately.

Run the bundled lightweight profiler on each version with **only one ChipBar process running**, matching macmon executable, menu display items, sampling frequency, SSD monitoring state and the same workload:

```bash
cd macmon/apps/ChipBar

# First, run ChipBar 1.3.17 (all other versions quit).
bash scripts/profile-chipbar.sh stable-closed 60
# Open its main panel and leave it open.
bash scripts/profile-chipbar.sh stable-open 60

# Quit 1.3.17, start the 2.0 preview; use same conditions:
bash scripts/profile-chipbar.sh preview-closed 60
bash scripts/profile-chipbar.sh preview-open 60
```

The script outputs CSV and mean/peak process CPU (%) and resident memory (MiB) from macOS `ps`, requires no sudo or TCC prompts, and intentionally does not automatically open or control the GUI. The open/closed test does not compare the exact same number of cards across versions; use matched visible widgets for fairer analysis. `%CPU` counts a single logical CPU at roughly 100% and may exceed that for multithreaded apps. These snapshots **do not** measure GPU compositing, Apple Silicon hardware power, entire `macmon` process tree, or animation stutter. For the latter use Instruments Time Profiler / Animation Hitches (recorded during repeatable 10x disclosure toggles on the same machine).

## Known limitation: GitHub preview signing

The CI zip contains ad-hoc signed app code. Because its signed code identity can change with each CI run, TCC approvals may not carry over. Removing OS privacy prompts programmatically would be neither reliable nor appropriate. Use a consistent trusted signing identity for long-term iterative local testing, or accept OS prompts on a new CI build. If prompts continue on an unchanged build, capture the **exact prompt text and the executable requesting consent**, since they may originate from macOS, smartctl/macmon or an external path rather than ChipBar.

## Acceptance criteria for 2.0 stable

- **Tap feedback:** each interactive button gives press-state feedback; radio/picker selection and disclosures have a transition; disabled or Reduce Motion states remain accessible.
- **Scroll:** native macOS inertial scrolling without involuntary jump to top/bottom; no forced window resize during the gesture.
- **Panel:** settings and system-details shrink/expand without old-frame clipping; repeated fast toggles do not flash, overlap or leave phantom scroll offsets.
- **Performance:** compare old 1.3.17 and 2.0 builds *on the same Mac* using Instruments (CPU, main-thread blocking, Core Animation FPS/hitches and memory) under idle/active/scroll/rapid-toggle workloads. Do not claim a fixed FPS until measured.
- **Reliability:** app memory and system disk storage units/values match macOS built-in tooling within metric-definition differences; test wake/sleep, SSD detach/reconnect, and hotplug.
- **Compatibility:** macOS 13+ and 26+ Liquid Glass, light/dark, high/standard refresh rate and Reduce Motion; keep original menu-bar alignment.

## Next implementation phases before stable

- Move remaining storage, network and per-application sampling subscriptions into a shared visibility-aware MonitoringCoordinator rather than binding `.task` lifetimes to cards; retain independent 1/2/5/10-second fast stream and 30-second capacity/SMART cadence.
- Break up the 900+ line MenuController into separate window geometry, navigation/interaction and menu presentation objects after the viewport scheduler is confirmed in the preview.
- Consolidate disclosure frame/height calculations (application rows and SSD details) to eliminate hard-coded deltas and cover animation interruption under changing monitor samples.
- Tune precise spring response and hover states from recorded real-Mac video and an Instruments trace; automated macOS builds alone cannot certify smooth frames.

## Building / manual QA

Download the **ChipBar CI artifact** for this branch, not a GitHub Release. Extract ChipBar.app outside Applications and quit stable ChipBar before launching. CI builds and tests run on GitHub; detailed interaction quality must be reviewed on the target Mac.

To exercise existing UI screenshots/QA, use the project's validated `--disclosure-only`, `--scroll-check` and settings round-trip harness where supported by `scripts/integration.py`.

Stats (https://github.com/exelban/stats) inspires the separation of Reader / Module / Popup / Widget. ChipBar does **not** copy its UI, binary code, or require its privileged helpers.
