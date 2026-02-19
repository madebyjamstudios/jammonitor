# DEVLOG — JamMonitor Build Journal

> A narrative record of how JamMonitor was built, reconstructed from 222 git commits across 9 development days. Each entry tells the real story of what happened — the decisions, the rabbit holes, the iteration cycles, and the midnight pivots.
>
> Entries are in reverse chronological order. The current day is never included.

---

## Day 9 — The Meta-Feature
**Jan 11–12, 2026 | 22 commits | `d21cf31`..`98a9115`**

### Summary
JamMonitor learned how to update itself. The session started with a GitHub-based version check, escalated into a full Settings popup with one-click auto-update, and then spiraled into an eight-commit alignment saga trying to make a gear icon sit properly in the sidebar. The night ended at 4:47 AM with a comprehensive bandwidth tracking overhaul.

### The Story
Mario had been deploying JamMonitor manually for over a week — SCP files, clear caches, restart services. It was time for the tool to handle its own updates. The first commit added a version check against GitHub, comparing the installed commit hash to the latest on the remote. Simple enough.

But a version check without an update button is just anxiety. Within forty minutes, a full Settings popup appeared with a one-click auto-update mechanism. Now JamMonitor could pull its own code from GitHub, replace its own files, and restart itself. The tool had become self-aware of its own deployment.

Then came the sidebar. The Settings gear icon needed a label next to it, and what followed was a masterclass in CSS frustration. Eight commits over thirty-five minutes tried every trick — vertical alignment, margin-top, transform, inline text — just to get a wrench icon and the word "Settings" to sit on the same visual baseline. The icon changed from a gear to a wrench mid-struggle. The button needed to fill to the bottom of the sidebar. The hover state needed to reach the edges. Each fix revealed a new misalignment.

With the sidebar finally tamed, attention turned to cleanup: a universal CSS close button replaced the inconsistent X buttons across all popups, boot time and uptime displays got fixed (they'd silently broken at some point), and the language dropdown lost its duplicate arrow. The final commit at 4:47 AM added comprehensive bandwidth tracking for all traffic sources — a substantial feature quietly dropped as a nightcap.

### Battles
- **Settings icon alignment** (8 commits): `8e2366b`→`0a8cf80` — gear icon, label alignment, margin-top, transform, inline text, icon swap to wrench
- **Language dropdown arrow** (2 commits): native browser arrow conflicting with custom grey arrow
- **Sidebar height**: dynamic vs fixed, min-height vs fill-to-bottom

### What Got Done
- GitHub-based version check system
- Settings popup with one-click auto-update
- Settings button in sidebar (wrench icon, bottom-anchored)
- Universal CSS close button across all popups
- Boot time / local time display fixes
- Comprehensive bandwidth tracking for all traffic sources

<details>
<summary>Commits (22)</summary>

| Hash | Time | Message |
|------|------|---------|
| `d21cf31` | Jan 11 20:07 | Add GitHub-based version check feature |
| `073a39b` | Jan 11 20:47 | Add Settings popup with one-click auto-update |
| `8e2366b` | Jan 11 22:06 | Add Settings label next to gear icon in sidebar |
| `edfe489` | Jan 11 22:08 | Fix Settings icon and label alignment |
| `8cf258e` | Jan 11 22:10 | Fix Settings icon vertical alignment with label |
| `ba7dfbc` | Jan 11 22:14 | Adjust Settings label alignment - add margin-top |
| `a17ea8d` | Jan 11 22:21 | Fix Settings icon alignment with transform |
| `4945ee9` | Jan 11 22:23 | Move Settings label up to align with icon |
| `ad857ac` | Jan 11 22:26 | Fix Settings alignment - use inline text like sidebar items |
| `0a8cf80` | Jan 11 22:29 | Make Settings tab bigger and change icon to wrench |
| `939a7ef` | Jan 11 22:44 | Fix uptime box, settings icon, and language dropdown |
| `a14bb4a` | Jan 11 22:45 | Fix settings button not at bottom of sidebar |
| `d363c59` | Jan 11 22:53 | Fix settings button to fill to bottom of sidebar & dropdown overflow |
| `3369c59` | Jan 11 22:58 | Fix settings button - push to bottom with hover to edge |
| `f22cddb` | Jan 11 23:01 | Remove duplicate dropdown arrow from language select |
| `d3bec34` | Jan 11 23:03 | Keep custom grey arrow, hide native browser arrow |
| `aa5f339` | Jan 11 23:07 | Add universal CSS close button icon across all popups |
| `bff6916` | Jan 11 23:09 | Fix boot time and local time not populating |
| `de78370` | Jan 11 23:19 | Add debug logging and parseFloat for uptime/date fix |
| `42bf40b` | Jan 11 23:21 | Fix null element error for uptime-tooltip |
| `995cdfb` | Jan 11 23:28 | Revert sidebar to dynamic height with min-height |
| `98a9115` | Jan 12 04:47 | Add comprehensive bandwidth tracking for all traffic sources |

</details>

### Notes
The auto-update feature is recursive in the best way — it was deployed manually for the last time. Every future version of JamMonitor can update itself. The 4:47 AM bandwidth commit suggests either a second wind or a "one more thing" that turned into a real feature.

---

## Day 8 — One and Done
**Jan 10, 2026 | 1 commit | `a045b58`**

### Summary
A single commit. Ping graph timeouts now drop to the bottom of the chart instead of disappearing, making network outages visually dramatic and impossible to miss.

### The Story
Some days produce fifty commits. Some days produce one. Day 8 was a one-commit day, and the commit was surgical: when a ping times out, the graph used to just... skip it. The line would have a gap, or the point would vanish. Now timeouts slam the line to the bottom of the chart — a sharp cliff that screams "something went wrong here."

It's the kind of change that takes five minutes to implement and makes everyone wonder why it wasn't always like that. A timeout isn't missing data — it's the worst possible data point, and it should look like it.

### Battles
None. Clean in, clean out.

### What Got Done
- Ping graph timeouts drop to bottom of chart for visual drama

<details>
<summary>Commits (1)</summary>

| Hash | Time | Message |
|------|------|---------|
| `a045b58` | Jan 10 23:18 | Make ping graph timeouts visually dramatic by dropping to bottom |

</details>

### Notes
The commit message says it all: "visually dramatic." Not "fix timeout display" or "improve graph accuracy." Sometimes the commit message is the whole story.

---

## Day 7 — Tightening the Bolts
**Jan 9, 2026 | 7 commits | `87de12f`..`8291f96`**

### Summary
A day of fixes and refinements. History export files were bloated by syslog encoding, the packet loss algorithm got replaced with a rolling window, translation inconsistencies got cleaned up, and the speed test gained regional server fallback — including a special case for China.

### The Story
Mario opened a history export and noticed the file was way bigger than expected. The culprit: syslog data was being encoded in a way that ballooned the file size. One commit fixed the encoding, a second adjusted the size estimates to account for syslog overhead. Two commits, problem solved.

The packet loss display had been bothering him. The existing algorithm was counting total losses over the entire session, which meant a brief outage twenty minutes ago would still drag the loss percentage up long after the connection recovered. A rolling window algorithm replaced it — now packet loss reflects what's happening recently, not what happened historically.

Three translation strings for "Tunnel" were inconsistent across Thai, Vietnamese, and Indonesian. A quick fix. Then attention turned to the speed test: users in different regions were hitting servers that gave misleading results. A regional fallback system was added — and China specifically got CacheFly CDN because the default servers were unreachable behind the Great Firewall. The last commit fixed a UI bug where the upload button wouldn't re-enable after a test completed.

### Battles
- **Syslog encoding bloat**: the fix was straightforward, but the size estimate needed a second pass
- **China speed test**: default servers don't work behind the GFW, needed a CDN fallback

### What Got Done
- Fixed history export syslog encoding (smaller files)
- Rolling window packet loss algorithm
- Translation fixes (Thai, Vietnamese, Indonesian)
- Regional speed test server fallback
- China-specific CDN server for speed tests
- Upload button re-enable fix

<details>
<summary>Commits (7)</summary>

| Hash | Time | Message |
|------|------|---------|
| `87de12f` | Jan 9 12:06 | Fix history export syslog encoding bloating file size |
| `e648c85` | Jan 9 12:11 | Include syslog overhead in file size estimate |
| `fa994b0` | Jan 9 14:06 | Change packet loss to rolling window algorithm |
| `f7ad9f6` | Jan 9 14:29 | Fix inconsistent Tunnel translations in Thai, Vietnamese, Indonesian |
| `c3eb1f0` | Jan 9 15:37 | Add regional speed test server fallback |
| `cae99cb` | Jan 9 15:40 | Fix China speed test server - use CacheFly CDN |
| `8291f96` | Jan 9 15:44 | Fix upload button re-enabling after test & add visual indicators |

</details>

### Notes
Seven commits across three and a half hours. Every one of them ships a fix or improvement. No reverts, no alignment struggles, no rabbit holes. This is what a polish day looks like.

---

## Day 6 — Twenty Languages Before Midnight
**Jan 8, 2026 | 18 commits | `296c9cc`..`d96b539`**

### Summary
JamMonitor went from English-only to supporting 20 languages in a single day. The i18n blitz happened in waves: first the HTML elements, then the dynamic JavaScript strings, then tab-by-tab coverage — WiFi, speed test, Overview, Diagnostics, Interface, Clients. The day ended with a USB Storage Setup wizard.

### The Story
The first commit landed at 2:28 AM and it was ambitious: internationalization support for 20 languages, all at once. Not a framework-first approach where you add the plumbing and fill in translations later — this was the whole thing. Translation files, a `translatePage()` function to handle static HTML elements, and initial coverage for the core UI.

But "initial coverage" meant about 60% of the strings. The rest of the day was a methodical march through every corner of the interface. Phase by phase, tab by tab, every hardcoded string got wrapped in a translation function. Debug logging went in early to catch strings that slipped through. An escaped-quote bug in Chinese broke things briefly. The speed test buttons needed special handling. Some tabs had been forgotten entirely.

By 9 PM, thirteen languages had gaps filled, nine languages got new Overview translations, and every dynamic string in the Diagnostics and Interface tabs was wrapped and translated. The commit messages read like a checklist being worked through with relentless focus: "Add WiFi APs section translations to all 20 languages." "Add Connected Clients translations for all languages." "Wrap chart empty state strings with `_()` for translation."

The session's final commit pivoted away from i18n entirely — a USB Storage Setup wizard for the Diagnostics tab, presumably because after a full day of translation work, building a new feature felt like a break.

### Battles
- **Unescaped quotes in Chinese** (`fc949b6`): broke the i18n file, caught and fixed quickly
- **Coverage gaps**: each new pass through the UI revealed strings that hadn't been wrapped
- **Speed test buttons**: needed special handling for dynamic text that changes during tests

### What Got Done
- Full i18n framework with 20 language support
- Static HTML translation via `data-i18n` attributes
- Dynamic JavaScript string wrapping with `_()`
- Complete translation coverage across all tabs: Overview, WAN Policy, WiFi APs, Diagnostics, Interface, Connected Clients
- USB Storage Setup wizard

<details>
<summary>Commits (18)</summary>

| Hash | Time | Message |
|------|------|---------|
| `296c9cc` | Jan 8 02:28 | Add internationalization (i18n) support with 20 languages |
| `2473a30` | Jan 8 02:28 | Fix i18n: add translatePage() to translate static HTML elements on load |
| `0469170` | Jan 8 02:37 | Add debug logging for i18n troubleshooting |
| `cf871f9` | Jan 8 03:03 | Expand i18n translations to ~90% coverage with Diagnostics section |
| `2cbfad9` | Jan 8 03:27 | Add WAN Policy translations to all 20 languages |
| `d40e80d` | Jan 8 08:48 | Phase 2 i18n: Translate all dynamic JavaScript strings |
| `a2053dd` | Jan 8 13:14 | Add WiFi APs section translations to all 20 languages |
| `fc949b6` | Jan 8 14:31 | Fix unescaped quotes in Chinese i18n string |
| `74d4d00` | Jan 8 14:40 | Add data-i18n attributes to WiFi tab and new translations |
| `54f045a` | Jan 8 16:10 | i18n: Add data-i18n to remaining HTML elements and wrap JS strings |
| `65ee8e0` | Jan 8 16:55 | i18n: Fix speed test buttons and add missing translations to 13 languages |
| `157832d` | Jan 8 18:15 | Add missing Overview translations (CPU Temperature, Load, Usage) to 9 languages |
| `7d46a7e` | Jan 8 20:24 | Add Diagnostics translations and fix dynamic strings for all languages |
| `72bd41c` | Jan 8 21:17 | Add Interface tab translations for all languages |
| `3f5c191` | Jan 8 21:19 | Add Connected Clients translations for all languages |
| `9a5a674` | Jan 8 21:32 | Add missing Diagnostics dynamic strings to all 21 languages |
| `9c3f6a7` | Jan 8 21:33 | Wrap chart empty state strings with _() for translation |
| `d96b539` | Jan 8 22:08 | Add USB Storage Setup wizard for Diagnostics tab |

</details>

### Notes
Twenty languages in one day. The supported languages: English plus Arabic, Chinese (Simplified/Traditional), Dutch, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Malay, Polish, Portuguese, Russian, Spanish, Swedish, Thai, Turkish, and Vietnamese. The commit at `9a5a674` references "21 languages" — the count grew during the day as coverage was audited.

---

## Day 5 — The Pixel Police
**Jan 7, 2026 | 24 commits | `10c5cf0`..`fdfb94a`**

### Summary
A polish day. Compact tables everywhere, subnet groups for the client list, IP lease tooltips, and the legendary Yesterday separator font size saga — four commits in five minutes cycling through 24px, 18px, 14px, and finally 12px. Also: a black background test that lasted exactly 52 seconds.

### The Story
The session opened with a monthly bandwidth display fix and a date format consistency change (slashes to dashes). Then Mario did something developers do when they're not sure if their deploy pipeline is working: he set the background to black. Commit `f3aba74` at 15:16:15 — "Test: black background." Commit `2b50e33` at 15:16:50 — "Revert black background test." Thirty-five seconds of darkness. Pipeline confirmed working.

A three-hour gap followed, then the VPS Bypass toggle went on a journey. It had been placed below the explanation text yesterday, but that didn't feel right. Three commits over thirty-seven minutes moved it below Advanced Settings, then between the Disabled section and the explanation, trying to find its natural home in the UI hierarchy.

The client list got a major organizational upgrade: collapsible subnet groups that auto-sort devices by network, plus sortable columns with arrow indicators. Then the hover effects needed tuning — too bright, then too dark, settling on a specific blue. IP addresses gained mouse-following tooltips showing DHCP lease expiry times.

Then the compactification wave hit. Client list rows got compact. Then bandwidth tables. Then WiFi tables. Then the bandwidth popup. Everything tightened up. And then came the Yesterday separator. It had been added the previous night to divide today's hourly bandwidth entries from yesterday's. But how big should it be? The font size went 24px → 18px → 14px → 12px in four commits between 20:57 and 21:01. Four minutes, four commits, each one basically saying "no, smaller." It finally landed at 12px, left-aligned to match the timestamps.

### Battles
- **Yesterday separator font size** (4 commits in 5 min): `df69909`→`fdfb94a` — 24→18→14→12px, then left-aligned
- **VPS Bypass positioning** (3 commits): below explanation → below Advanced Settings → between Disabled and explanation
- **Client list hover brightness** (2 commits): too bright → darker blue
- **Black background test** (2 commits, 35 seconds): deployed and reverted

### What Got Done
- Monthly bandwidth display and tooltip positioning fixes
- Collapsible subnet groups for client list
- Sortable columns with arrow indicators
- Client list hover style refinement
- Mouse-following tooltip for IP lease expiry
- Compact table styling across all tables
- Yesterday separator finalized at 12px left-aligned
- Date format consistency (slash → dash)

<details>
<summary>Commits (24)</summary>

| Hash | Time | Message |
|------|------|---------|
| `10c5cf0` | Jan 7 14:59 | Fix monthly bandwidth display and improve tooltip positioning |
| `bf19b4d` | Jan 7 15:05 | Change daily date format from slash to dash for consistency |
| `f3aba74` | Jan 7 15:16 | Test: black background |
| `2b50e33` | Jan 7 15:16 | Revert black background test |
| `7d8c9b2` | Jan 7 18:01 | Add margin-top to VPS bypass banner for spacing |
| `b6074da` | Jan 7 18:06 | Move VPS Bypass toggle below Advanced Settings |
| `591d551` | Jan 7 18:39 | Move VPS Bypass between Disabled section and explanation |
| `543d631` | Jan 7 19:08 | Add collapsible subnet groups and sortable columns to Client List |
| `2e743b2` | Jan 7 19:15 | Remove sortable/hover from Type columns |
| `572354d` | Jan 7 19:23 | Fix sort arrow wrapping and Source column |
| `42b9af1` | Jan 7 19:28 | Fix column shifting when sorting - always show arrow placeholder |
| `554e89d` | Jan 7 19:31 | Reduce client list hover brightness for better readability |
| `08451ca` | Jan 7 19:33 | Use darker blue for client list hover |
| `321526a` | Jan 7 20:33 | Add mouse-following tooltip for IP address lease expiry |
| `d6fa2da` | Jan 7 20:45 | Add tooltip for Tailscale peers on IP hover |
| `8befc68` | Jan 7 20:47 | Remove Tailscale tooltip - keep lease expiry only |
| `d81baf3` | Jan 7 20:51 | Make client list rows more compact |
| `0eb9a7d` | Jan 7 20:54 | Make all tables compact (bandwidth, wifi, bucket popup) |
| `336312e` | Jan 7 20:56 | Increase Yesterday separator font size |
| `df69909` | Jan 7 20:57 | Double Yesterday separator font size to 24px |
| `17020d2` | Jan 7 20:58 | Set Yesterday separator to 18px |
| `824950f` | Jan 7 20:59 | Set Yesterday separator to 14px |
| `f551549` | Jan 7 21:00 | Left-align Yesterday separator to match timestamps |
| `fdfb94a` | Jan 7 21:01 | Set Yesterday separator to 12px |

</details>

### Notes
The Tailscale tooltip had a two-minute lifespan — added at 20:45, removed at 20:47. The black background test is a classic "is my pipeline working?" move. And the Yesterday separator font size saga is a perfect microcosm of UI development: you never know the right size until you've tried four wrong ones.

---

## Day 4 — The Marathon
**Jan 6–7, 2026 | 49 commits | `4a7bc71`..`bb487d3`**

### Summary
The longest session yet. A per-WAN speed test feature, bandwidth breakdown popups, client name inline editing (with a ten-commit button positioning struggle), sort arrow icon exploration across five different styles, line chart conversion, and the birth of the Yesterday separator — all in one fifteen-hour stretch.

### The Story
The day opened with ambition: a per-WAN speed test in the Diagnostics tab. Each WAN interface could now run independent speed tests, showing download and upload speeds side by side. But the column alignment wouldn't cooperate. Six commits wrestled with fixed widths, flex values, column swapping, and truncation before the layout stabilized. A hover tooltip for long WAN interface names was the finishing touch.

After fixing a historical collector bug (it was spawning multiple instances), the bandwidth charts gained loading spinners and then a major new feature: per-device bandwidth breakdown popups. Click on any hourly or daily entry and see exactly which device used how much. The popup needed its own set of fixes — column naming, device type display, sort functionality.

Then came the client name editing saga. The inline edit concept was simple: click a client name, type a new one, hit save. The implementation was anything but. Ten commits over an hour fought with layout shift, button positioning, vertical alignment, padding vs margin, and the eternal question of when edit buttons should appear and disappear. The buttons went below the input, then needed margin adjustments, then vertical-align top on all cells, then padding-bottom instead of margin, then a row-editing CSS class, then input repositioning. The Reset button didn't update the UI. Unnamed devices showed an asterisk that got changed to "Tap to name."

The sort arrows were their own subplot. The bandwidth popup table needed sortable columns, and the arrow indicators went through five visual styles in seven commits: small triangles (▴▾), then only on active columns with wider triangles, then flat arrow icons (⌃⌄), then larger text with fixed widths, and finally CSS-drawn triangles for pixel-perfect identical up/down arrows.

Midnight brought the charts conversion from bar to line charts with hover tooltips, a new color palette (Blue/Orange/Purple), and the Yesterday separator — a horizontal divider in the hourly bandwidth table separating today's entries from yesterday's. The separator's hover style conflicted with the table's general hover rule, requiring a CSS specificity fix. The VPS Bypass toggle got repositioned one more time before the session ended at 1:27 AM.

### Battles
- **Speed test column alignment** (6 commits): `034ddc9`→`ea66620` — fixed widths, flex values, column order, truncation
- **Client edit button positioning** (10 commits): `e2be35b`→`0f9a0bc` — layout shift, vertical alignment, padding, visibility
- **Sort arrow icons** (5 styles in 7 commits): ▴▾ → wide triangles → ⌃⌄ → large fixed-width → CSS triangles
- **Yesterday separator hover** (2 commits): CSS specificity conflict with table hover rules
- **Hourly data merging**: same hours from different days were being combined

### What Got Done
- Per-WAN speed test in Diagnostics tab
- Per-device bandwidth breakdown popups (hourly/daily/monthly)
- Client name inline editing with Save/Cancel workflow
- Sortable columns with CSS triangle arrows
- Line chart conversion with hover tooltips
- Blue/Orange/Purple chart color palette
- Yesterday separator in hourly bandwidth table
- "Tap to name" placeholder for unnamed devices
- Loading spinners for bandwidth charts

<details>
<summary>Commits (49)</summary>

| Hash | Time | Message |
|------|------|---------|
| `4a7bc71` | Jan 6 10:43 | Add Per-WAN Speed Test feature to Diagnostics tab |
| `0d78588` | Jan 6 11:00 | Fix atomic_write function order in jammonitor.lua |
| `eb9cc5f` | Jan 6 11:06 | Speed test: show active WAN policy interfaces instead of hardcoded filter |
| `c35b2d2` | Jan 6 11:14 | Improve WAN Speed Test UI layout |
| `57ba43e` | Jan 6 11:16 | Change Emergency Snapshot icon to alarm |
| `034ddc9` | Jan 6 11:16 | Fix speed test column alignment with fixed widths |
| `a9ae5c6` | Jan 6 11:17 | Swap IP and interface name columns in speed test |
| `1b86f2e` | Jan 6 11:18 | Fix interface name column alignment in speed test |
| `cef0419` | Jan 6 11:23 | Fix speed test column alignment with flex: 0 0 Xpx |
| `ea66620` | Jan 6 11:29 | Add hover tooltip for truncated WAN names in speed test |
| `4187c69` | Jan 6 12:55 | Fix historical collector running multiple instances |
| `996fec1` | Jan 6 13:08 | Fix speed test size button losing default selection |
| `4ae7f78` | Jan 6 13:13 | Add loading spinners to bandwidth charts |
| `4027d22` | Jan 6 13:16 | Add missing @keyframes for chart spinner animation |
| `5af4f92` | Jan 6 14:48 | Add per-device bandwidth breakdown popup for hourly/daily/monthly views |
| `b27d81d` | Jan 6 23:05 | Make only time column text clickable with underline |
| `1bacb34` | Jan 6 23:09 | Change bandwidth popup columns to MAC Address and device Type |
| `b4951b7` | Jan 6 23:12 | Show dash instead of Unknown for undetected device types |
| `e2be35b` | Jan 6 23:31 | Fix client name edit: no layout shift, no kick-out during editing |
| `51f0110` | Jan 6 23:36 | Move edit buttons below input, push rows down when editing |
| `8525105` | Jan 6 23:38 | Remove extra top padding from edit buttons |
| `d9404ad` | Jan 6 23:40 | Fix edit buttons: restore 32px margin, add vertical-align top |
| `0d0ce74` | Jan 6 23:42 | Apply vertical-align top to ALL cells in clients table |
| `4bd69e4` | Jan 6 23:45 | Fix edit buttons: use padding-bottom instead of margin |
| `5f14a10` | Jan 6 23:48 | Add row-editing class to keep cells aligned during edit |
| `0188335` | Jan 6 23:51 | Fix input positioning and button spacing |
| `0f9a0bc` | Jan 6 23:56 | Fix Reset button not updating UI |
| `d69d49b` | Jan 6 23:59 | Change unnamed device display from '*' to 'Tap to name' placeholder |
| `2e5e1c7` | Jan 7 00:00 | Sort bandwidth data by timestamp before displaying |
| `bafc9e9` | Jan 7 00:18 | Fix bandwidth popup data and add sortable columns |
| `0566c77` | Jan 7 00:23 | Add "Yesterday" separator row in Hourly bandwidth table |
| `d2c8e66` | Jan 7 00:28 | Make day separator row more subtle and boring |
| `dca50aa` | Jan 7 00:29 | Simplify separator to always show "Yesterday" |
| `dfe1aa2` | Jan 7 00:31 | Fix separator hover with higher CSS specificity |
| `9221ece` | Jan 7 00:32 | Improve sortable column arrows and fix table layout shift |
| `3360442` | Jan 7 00:32 | Use small triangle arrows (▴▾) for sort indicators |
| `d3b4ba0` | Jan 7 00:35 | Show sort arrows only on active column with wider triangles |
| `bb1bf1e` | Jan 7 00:37 | Fix hourly popup by using vnstat timestamp directly |
| `03e24f8` | Jan 7 00:38 | Use wider flat arrow icons (⌃⌄) for sort indicators |
| `c17c43e` | Jan 7 00:43 | Fix popup table: larger text, fixed widths, stable sort icon |
| `c22cf46` | Jan 7 00:45 | Use CSS triangles for identical up/down sort arrows |
| `eb6e6a6` | Jan 7 01:00 | Convert all bandwidth charts to line charts with hover tooltips |
| `1e6264a` | Jan 7 01:01 | Fix hourly table to show newest first (most recent at top) |
| `eb02e14` | Jan 7 01:04 | Use Blue/Orange/Purple palette for all charts |
| `0ea86cb` | Jan 7 01:07 | Revert separator label to simple 'Yesterday' |
| `2a251cc` | Jan 7 01:15 | Fix hourly data merging same hours from different days |
| `9972668` | Jan 7 01:16 | Remove chart click handler, keep hover-only tooltips |
| `dca5357` | Jan 7 01:19 | Fix separator hover: exclude from general table hover rule |
| `bb487d3` | Jan 7 01:27 | Move VPS Bypass toggle below explanation, above Advanced Settings |

</details>

### Notes
49 commits in one session. The eight-hour gap between 14:48 and 23:05 suggests either a long break or a session split. The sort arrow evolution is worth studying — five visual approaches tried, with CSS triangles winning because they guarantee identical sizing between up and down states, something Unicode characters can't promise across fonts.

---

## Day 3 — The VPS Bypass Saga
**Jan 5–6, 2026 | 41 commits | `1e049c9`..`61da31f`**

### Summary
The day that tested patience. Thirteen commits trying to make VPS bypass work — cycling through stopping OpenVPN, ifdown, UCI disable, killing the tracker, using OMR's own bypass mechanism, and finally reverting to service-stopping with proper flags. After midnight, a complete Diagnostics tab redesign and a full client list with inline name editing.

### The Story
The VPS Bypass toggle started simple. JamMonitor monitors an OpenMPTCProuter setup where traffic routes through a VPS. Sometimes you want to bypass the VPS and go direct. First commit: add a toggle. Second commit: add switching feedback so the user knows something is happening. Easy so far.

Then reality hit. Stopping OpenVPN and Shadowsocks seemed like the obvious approach, but omr-tracker kept restarting them. So kill the tracker first. But that felt hacky. UCI disable would be cleaner — set a disabled flag so services don't restart. But wait, OpenMPTCProuter has its own bypass mechanism built in. Switch to that. But the OMR bypass uses IP types, and `lan_ip` worked differently than `ips`. Fix that. But actually, the OMR bypass didn't do what was needed. Revert to service-stopping. But the service names were wrong. Fix those, and disable the hotplug scripts too. But omr-schedule was restarting everything. Add UCI disabled flags to prevent that.

Thirteen commits. Ten different approaches. The VPS bypass toggle went from three lines of code to a careful orchestration of service stops, UCI flags, and hotplug disables. Each approach worked partially, revealed a new restart vector, and required a new countermeasure. It's the classic "fighting the system" pattern — OpenMPTCProuter really wants its VPN running, and every layer of the system has its own mechanism for ensuring that.

After midnight (technically Jan 6), the UI broke. The exec() API calls that worked during development didn't work in production. A quick fix swapped them to api() calls. Then a complete Diagnostics tab redesign landed — clear visual distinction between sections, reduced data collection frequency, date range picker, storage status display.

The client list emerged next: Tailscale devices alongside LAN clients, device categorization borrowed from Peplink's taxonomy, DHCP reservation tags, inline name editing. The editing UI was its own saga in miniature — click handler fixes, button visibility timing, hover styles, CSS specificity battles — but it all landed by 3:24 AM.

### Battles
- **VPS Bypass approaches** (13 commits): stop services → ifdown → UCI disable → kill tracker → OMR bypass → fix IP type → revert to stopping → fix names → disable hotplug → UCI flags → save/restore states → error handling → async response
- **Broken UI** (`f6d62ea`): exec() vs api() calls — worked in dev, broke in production
- **Client name editing**: click handlers, button visibility, hover styles, CSS specificity
- **Bypass verification**: needed to respond before network reload completed

### What Got Done
- VPS Bypass toggle (after 13 iterations)
- Diagnostics tab complete redesign
- Data collection at 1/min with date range picker
- Storage status display with size estimates
- Tailscale device integration in client list
- Device type categorization (Peplink-style)
- DHCP reservation management
- Inline client name editing with Save/Apply workflow
- Syslog retention increased to 100MB

<details>
<summary>Commits (41)</summary>

| Hash | Time | Message |
|------|------|---------|
| `1e049c9` | Jan 5 08:55 | Add VPS Bypass Toggle feature |
| `3d65d41` | Jan 5 09:34 | Add switching feedback to VPS Bypass toggle |
| `fb2ee81` | Jan 5 22:21 | Implement true VPS bypass by stopping OpenVPN and Shadowsocks |
| `aca21c4` | Jan 5 22:28 | Add ifdown/ifup omrvpn to bypass toggle |
| `c13c9b5` | Jan 5 22:32 | Disable services (not just stop) to prevent omr-tracker restart |
| `9a162a8` | Jan 5 22:48 | Kill omr-tracker before stopping VPN services |
| `10b5035` | Jan 5 22:55 | Use UCI disable for cleaner VPS bypass toggle |
| `d1700a7` | Jan 5 23:01 | Use OMR's bypass mechanism instead of disabling services |
| `d167a3c` | Jan 5 23:06 | Simplify VPS bypass to ONLY use OMR-Bypass feature |
| `8d4d12b` | Jan 5 23:13 | Fix VPS bypass to use lan_ip type instead of ips |
| `2c18b00` | Jan 5 23:22 | Revert to service-stopping approach for VPS bypass |
| `01d4e8b` | Jan 5 23:30 | Fix VPS bypass: correct service names and disable hotplug |
| `20bf344` | Jan 5 23:37 | Fix VPS bypass: set UCI disabled flags to prevent omr-schedule restart |
| `f6d62ea` | Jan 6 00:22 | Fix broken UI: replace exec() with api() calls |
| `79412ab` | Jan 6 00:46 | Redesign Diagnostics tab with clear visual distinction |
| `eadf6c4` | Jan 6 00:51 | Reduce data collection to 1/minute and add date range picker |
| `96c226e` | Jan 6 00:56 | Simplify historical data UI and add storage status |
| `b62126d` | Jan 6 01:01 | Add Tailscale devices to client list and enhance diagnostics info |
| `4fce34b` | Jan 6 01:21 | Fix diagnostics estimates to update when clicking time range buttons |
| `127e677` | Jan 6 01:27 | Increase syslog retention from 50MB to 100MB |
| `5059a1b` | Jan 6 01:39 | Fix VPS bypass to save/restore original VPN service states |
| `d6fc0e7` | Jan 6 02:10 | Improve bypass toggle error handling |
| `15bfdd1` | Jan 6 02:13 | Fix bypass toggle to respond before network reload |
| `627abe0` | Jan 6 02:15 | Add proper verification to bypass enable/disable |
| `19bec59` | Jan 6 02:36 | Redesign client list with status icons, device types, and DHCP reservations |
| `5cd86ac` | Jan 6 02:47 | Add all Peplink device categories and button-style DHCP tag |
| `d8c1114` | Jan 6 02:58 | Remove status dots and rename Type column to Source |
| `3c2ac5e` | Jan 6 03:04 | Add Save and Apply / Reset workflow for client changes |
| `06ba589` | Jan 6 03:08 | Simplify client name hover - remove pencil icon |
| `3e6825c` | Jan 6 03:09 | Fix client name click handler and improve clickability |
| `033d52f` | Jan 6 03:11 | Remove edit capability from Tailscale devices |
| `97a84a0` | Jan 6 03:12 | Reduce IP Address column width in client list |
| `f6e5868` | Jan 6 03:14 | Simplify client-name hover to color only |
| `48c16f8` | Jan 6 03:14 | Reduce Source column width to 70px |
| `cfe8230` | Jan 6 03:15 | Add underline to LAN client name hover |
| `8ce8c76` | Jan 6 03:16 | Fix client name hover to fill entire cell |
| `de86e91` | Jan 6 03:17 | Increase CSS specificity for client name hover |
| `d99d484` | Jan 6 03:20 | Implement inline editing for client names |
| `45483f4` | Jan 6 03:22 | Fix inline edit: buttons only on click, modern styling |
| `b465845` | Jan 6 03:23 | Fix Save/Cancel to dismiss form until mouse leaves |
| `61da31f` | Jan 6 03:24 | Force hide buttons with !important until editing mode |

</details>

### Notes
The twelve-hour gap between 09:34 and 22:21 tells its own story — the morning's simple toggle attempt probably revealed the complexity during manual testing, leading to a focused evening assault on the problem. The VPS bypass saga is the richest narrative in the entire project: each commit represents a hypothesis about how OpenMPTCProuter manages its services, tested and often disproven.

---

## Day 2 — The Midnight Pivot
**Jan 4, 2026 | 5 commits | `e5b2cf7`..`6dd00dd`**

### Summary
A late-night attempt to store historical metrics on the VPS, abandoned within 40 minutes, replaced by a local USB storage approach that turned out to be better in every way.

### The Story
At 2:02 AM, Mario added a VPS historical metrics collection feature. The idea made sense on paper — the router already tunnels through a VPS, so why not store performance history there? Centralized, always-on, accessible from anywhere.

Forty minutes later, it was reverted. The commit message is just "Revert" — no explanation needed. VPS storage meant dependency on VPS connectivity, which is exactly the thing JamMonitor is supposed to monitor. If the VPS goes down, you lose both your connection and your history of the connection going down. The irony wasn't lost.

By 3:54 AM, the pivot was complete. A local metrics collector for USB storage replaced the VPS approach. Plug a USB drive into the BPI-R4, and JamMonitor writes metrics locally. No network dependency. The data survives VPS outages, ISP failures, and everything else short of physically removing the USB drive.

A diagnostics download feature followed immediately, and then the final commit expanded the bundle to include everything — MPTCP state, VPN status, routes, syslog, full system state. Five commits, two hours, one clean architectural pivot.

### Battles
- **VPS vs local storage**: the VPS approach was architecturally wrong for a network monitoring tool — you can't depend on the network to monitor the network

### What Got Done
- Local USB metrics collector (replacing reverted VPS approach)
- Historical metrics download in Diagnostics tab
- Comprehensive history bundle (MPTCP, VPN, routes, syslog, system state)

<details>
<summary>Commits (5)</summary>

| Hash | Time | Message |
|------|------|---------|
| `e5b2cf7` | Jan 4 02:02 | Add VPS historical metrics collection feature |
| `6d8c107` | Jan 4 02:42 | Revert "Add VPS historical metrics collection feature" |
| `248dd3c` | Jan 4 03:54 | Add local metrics collector for USB storage |
| `6583bff` | Jan 4 03:58 | Add historical metrics download to Diagnostics tab |
| `6dd00dd` | Jan 4 04:07 | Expand historical bundle to include everything (MPTCP, VPN, routes, syslog, system state) |

</details>

### Notes
The cleanest narrative arc in the project: try → fail → pivot → succeed. The revert-to-replacement gap (40 min to 72 min) suggests Mario was thinking through the alternative before writing it. The USB approach also has the advantage of being physically portable — pull the drive and you have your network history.

---

## Day 1 — The Big Bang
**Jan 3, 2026 | 55 commits | `5542a57`..`31c5286`**

### Summary
JamMonitor's birthday. Forty-eight commits batch-imported from local development, followed by seven real-time evening commits. The initial feature set was already massive: WAN policy management with drag-and-drop, WiFi client monitoring, OMR Status iframe integration, and Advanced Settings. The WAN Policy column alignment consumed at least ten iterations, the WiFi tab went through an mDNS add/revert/restore cycle, and the OMR iframe crop escalated from a simple navbar hide to "make it much taller."

### The Story
The first 48 commits all share the same timestamp: January 3rd, 17:13:34. This is the batch import — days or weeks of local development pushed to GitHub in one shot. The timestamps are a lie, but the commit order tells the truth. Reading them in sequence reveals exactly how JamMonitor grew.

It started with the initial commit and a comprehensive README. Then the feature work: an Advanced Settings panel for failover and MPTCP tuning, followed by WAN Policy — the heart of JamMonitor. The WAN Policy tab lets you see and reorder your WAN interfaces, and getting the columns to look right became an obsession. Ten commits adjusted column spacing, alignment, positioning, widths, and padding. The columns went from "spread across full row width" to left-aligned to padded to pushed right to pushed further right to widened Name column to expanded Name column. Each commit was a micro-adjustment, the kind of pixel-level iteration that separates "works" from "looks right."

The WiFi tab had its own drama. It started with basic client monitoring, then mDNS hostname lookup was added for Apple devices. Then the whole WiFi tab was reverted "to simpler version." Then it was restored "without mDNS." Then it got revamped again with data transferred and WiFi generation info. The mDNS feature was apparently too unreliable or slow, but the rest of the WiFi revamp was worth keeping.

Drag-and-drop for WAN policy ordering needed race condition and duplicate fixes. WAN detection went through multiple iterations to handle non-standard interface names (wwan, wan5test). The OMR Status iframe — which embeds OpenMPTCProuter's own status page — started by cropping the navbar, then the submenu, then needed 150px of crop, then 175px, then just "make it much taller to avoid scrolling."

The evening brought five real-time commits: styling the Reset button to match OpenWrt's red delete buttons (then lightening the red), fixing interface name overflow, and adding tooltips. The gap between the batch import (17:13) and the first real-time commit (18:56) suggests about 100 minutes of testing the deployed version before finding things to fix.

### Battles
- **WAN Policy column alignment** (10+ commits): spacing, widths, padding, left-align vs spread — the eternal column layout struggle
- **WiFi mDNS** (3 commits): added → reverted → restored without mDNS — the feature that wasn't ready
- **OMR iframe crop** (4 commits): navbar → submenu → 150px → 175px → "much taller" — each crop revealed more unwanted chrome
- **WAN detection** (3 commits): hardcoded names → patterns + multipath → flexible naming

### What Got Done
- Initial JamMonitor framework (controller, view, JavaScript)
- WAN Policy tab with drag-and-drop reordering
- WiFi APs tab with client monitoring, data transfer, WiFi generation
- OMR Status iframe integration
- Advanced Settings panel (failover, MPTCP)
- WAN interface selector with filters
- LAN exclusion safety checks
- Real-time polling for WAN status
- Loading spinners for WiFi tab
- Collapsible Remote APs section
- WAN IPv4 connectivity status
- Responsive layout for small screens
- Reset button styling
- Interface name tooltips

<details>
<summary>Commits (55)</summary>

| Hash | Time | Message |
|------|------|---------|
| `5542a57` | Jan 3 17:13 | Initial commit: JamMonitor for OpenMPTCProuter |
| `106e898` | Jan 3 17:13 | Add comprehensive README with documentation and screenshot placeholders |
| `f5df764` | Jan 3 17:13 | Replace local image links with GitHub asset links |
| `f8fe5a3` | Jan 3 17:13 | Add Advanced Settings panel for Failover and MPTCP tuning |
| `c36f2d0` | Jan 3 17:13 | Increase WAN Policy column spacing for wider layout |
| `9e477aa` | Jan 3 17:13 | Spread WAN Policy columns across full row width |
| `86f9ef3` | Jan 3 17:13 | Adjust WAN Policy column positioning |
| `a39c9ee` | Jan 3 17:13 | Center status column, push IP closer to right edge |
| `9b62c29` | Jan 3 17:13 | Left-align all WAN Policy columns for consistent alignment |
| `bae67f4` | Jan 3 17:13 | Adjust column positions with left padding (always left-aligned) |
| `710a279` | Jan 3 17:13 | Push both columns 25% to the right |
| `268af7c` | Jan 3 17:13 | Big push right - nearly double the left padding |
| `e0b67dc` | Jan 3 17:13 | Widen Name column to push other columns right |
| `fab8097` | Jan 3 17:13 | Expand Name column and push Status/IP columns right |
| `499278b` | Jan 3 17:13 | Fix drag and drop race conditions and duplicates |
| `f0971bf` | Jan 3 17:13 | Move Status and IP columns slightly left |
| `bf4fb90` | Jan 3 17:13 | Move Name column content closer to left edge |
| `7776ad7` | Jan 3 17:13 | Add missing MPTCP scheduler options |
| `713e194` | Jan 3 17:13 | Fix WAN detection to include wwan and other WAN interfaces |
| `fae2e0d` | Jan 3 17:13 | Add continuous polling for WAN Policy tab |
| `852073e` | Jan 3 17:13 | Exclude guest interface from WAN Policy |
| `ecdbda9` | Jan 3 17:13 | WiFi APs tab improvements + dynamic WAN detection |
| `deecb3f` | Jan 3 17:13 | Fix WAN detection: use name patterns + active multipath |
| `accdaec` | Jan 3 17:13 | Add null check for wifi-clients-tbody element |
| `3d7fc87` | Jan 3 17:13 | Add device hostname to WiFi clients, remove SSID column |
| `967c007` | Jan 3 17:13 | Real-time WiFi utilization with delta tracking |
| `1caaeef` | Jan 3 17:13 | Change bandwidth display from MB/s to Mbps |
| `5cf35ad` | Jan 3 17:13 | Add mDNS hostname lookup for Apple devices |
| `560f3b4` | Jan 3 17:13 | Revert WiFi tab to simpler version, keep Mbps fix |
| `604047f` | Jan 3 17:13 | Restore WiFi revamp + Mbps fix (without mDNS) |
| `36181f5` | Jan 3 17:13 | WiFi clients: show data transferred + WiFi generation |
| `53eabc6` | Jan 3 17:13 | Fix bytes display to show KB/MB/GB suffix |
| `74f900d` | Jan 3 17:13 | Add loading spinners to WiFi tab |
| `2f4276f` | Jan 3 17:13 | Improve responsive layout for small screen quadrants |
| `e15dc44` | Jan 3 17:13 | Add collapsible Remote APs section to WiFi tab |
| `d46b721` | Jan 3 17:13 | Fix WAN IPv4 status to reflect actual internet connectivity |
| `24dab91` | Jan 3 17:13 | Fix WAN status flickering during routine polls |
| `13ce560` | Jan 3 17:13 | Crop LuCI navbar from OMR Status iframe |
| `e91d42a` | Jan 3 17:13 | Crop LuCI submenu from OMR Status iframe |
| `9e9c4d8` | Jan 3 17:13 | Increase OMR iframe crop to 150px |
| `911a9ff` | Jan 3 17:13 | Increase OMR iframe crop to 175px and expand height |
| `91b46f0` | Jan 3 17:13 | Make OMR iframe much taller to avoid scrolling |
| `952155e` | Jan 3 17:13 | Support flexible WAN interface naming (wan5test, etc.) |
| `9d8004c` | Jan 3 17:13 | Add WAN Interface Selector to Advanced Settings |
| `585fc70` | Jan 3 17:13 | Fix WAN Interface Selector to show all interfaces |
| `49bd888` | Jan 3 17:13 | Consolidate Advanced Settings buttons |
| `dfbc2ab` | Jan 3 17:13 | Make WAN filters suggestive + UI improvements |
| `baf6658` | Jan 3 17:13 | Add LAN exclusion filter and safety checks for interface removal |
| `45374bd` | Jan 3 18:56 | Style Reset button to match OpenWrt/OMR delete buttons |
| `4fefaca` | Jan 3 18:58 | Lighten Reset button red color |
| `2d21dc8` | Jan 3 19:17 | Fix long interface names overflowing in WAN selector |
| `f4621be` | Jan 3 19:19 | Add tooltip to show full interface name on hover |
| `31c5286` | Jan 3 19:21 | Add instant CSS tooltip for interface names |

</details>

### Notes
The 48 batch-imported commits represent the "dark matter" of JamMonitor's development — work done locally before the repository existed. The commit messages are well-written enough to reconstruct the development arc, which suggests they were written during development, not retroactively. Day 1 established the core architecture that every subsequent day built upon: the three-file structure (Lua controller, HTM template, JS logic), the tab-based interface, and the polling-based data refresh pattern.

---

*Total: 222 commits across 9 days (Jan 3–12, 2026)*
