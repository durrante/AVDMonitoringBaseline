# Blog draft — AVD Monitoring Baseline

> Header levels marked in [brackets]. Two screenshots of a real fired
> alert are included via 📸 markers below, source files in
> `Pictures\ShareX\Screenshots\08-07-2026\Blog Post\`, suggested renamed
> filenames given inline. Everything else is code blocks. Delete this note
> and the publishing notes at the bottom before going live.

---

[H1] AVD Monitoring Baseline: Community Edition

Microsoft ships an official monitoring baseline for Azure Virtual Desktop as part of [Azure Monitor Baseline Alerts](https://github.com/Azure/azure-monitor-baseline-alerts) (AMBA). Host pool capacity, CPU, memory, disk, FSLogix, storage, service health, all pre-built as one deployable pattern. Good idea in theory. In practice I kept running into alerts that were too noisy, alerts that stayed silent when they shouldn't have, and one that had never fired at all. Development upstream has gone quiet too, issues sitting open with no response, so instead of working around the same problems on every deployment I've started maintaining it myself: [AVDMonitoringBaseline](https://github.com/durrante/AVDMonitoringBaseline). Most of what's in it is bug fixes, but there are a few genuine enhancements in there too. Here's what's changed.

Credit where it's due though. The alert catalogue, the runbooks, the whole deployment pattern, that's still Microsoft's work and it's a genuinely useful design. This fork exists to keep it maintained, not to take credit for building it. A couple of the fixes actually started life as an unmerged community pull request from [@fbloemhof](https://github.com/Azure/azure-monitor-baseline-alerts/pull/839) that upstream never got around to merging, so I've folded it into this fork instead of letting it go stale.

> **📝 Note**
> Not a rewrite. Same alerts, same deployment method (custom deployment blade), same MIT licence, just with the bugs fixed and kept up to date. Not affiliated with or endorsed by Microsoft.

[H2] What's changed

**Memory alerts were false-positiving on startup.** AVD autoscales host pools, so hosts power on and off through the day, and the old metric alert misread a freshly-started VM's zero reading as "memory critically low". Basically firing on a host that was still booting. Rather than pull the performance counter via Azure VM metrics, it's now a KQL query against the performance counter directly, which only evaluates hosts that have actually been up and reporting for a while. Hopefully that's the last we see of those.

**Health check failures were quietly being ignored.** The Health Check Failure alert works by mapping a numeric health check ID to a description (CPU, memory, disk, AVD agent, that kind of thing). Problem is the mapping only covered IDs 0 to 10, so any newer check outside that range fell through to "unrecognised" and never generated a description the alert would fire on. Two of the missing ones were the AAD Joined health check (is the host actually Entra-joined) and the TURN Relay health check (used for connectivity), both exactly the kind of failure you'd want to know about, and both silently excluded from alerting.

**FSLogix "profile locked" alerts now say who and what.** Previously you just got told a profile disk was attached elsewhere. Now the alert includes the username and the actual VHD(X) path, so you're not digging through event logs on the session host to work out who's affected.

**High CPU alerts were noisy.** The 85% CPU alert was evaluating every 5 minutes over a 15-minute window, so a short spike (a logon storm, an app launching) would trip a Sev2. It's now every 30 minutes over a 1-hour window, so it's sustained load that gets flagged, not a blip. The 95% Sev1 alert is untouched, so genuine CPU exhaustion still alerts quickly.

**Multi-tenant / MSP support.** If you manage more than one customer's AVD estate, host pool names are often identical across tenants and every alert email comes from the same Microsoft sender, so it's hard to tell at a glance whose alert you're looking at. There's now an optional customer name parameter that stamps "Customer: X" into every alert description.

**Alerts now show you the number, not just "below threshold."** Several alerts were computing a real value in the query (available memory in MB, disk free percentage, file share percentage remaining) but never included it in the fired alert. You'd get told something was low without being told how low. All three now show the actual figure.

**And a typo**, small but included since it was in the same pass: `AVD-ServiceHealth-Serivice Issue` → `Service Issue`.

[H2] The one that worried me: capacity alerts that never fired

Host Pool Capacity alerts are meant to warn at 50%, 85% and 95% load. On a deployment I run, load had been sitting well past those thresholds for weeks. Almost every alert had gone silent. No error, no failed deployment, nothing to say anything was wrong.

It wasn't completely silent, though, and that's what made it hard to catch. Every so often the load landed on an exact whole number and the alert fired perfectly normally, which was enough to make the rule look like it worked. It was only the decimal readings, which is most of them, that vanished without a trace.

📸 avd-hostpool-capacity-alert-fired-dimensions.png
Caption: One of the rare hits: load landed on an exact 69% that day, so the query happened to parse it fine and the alert fired as expected.
Alt: Azure Monitor fired alert for AVD-HostPool-Capacity 50 Percent showing informational severity and dimensions including HostPoolPercentLoad of 69, UserSessionsActive 238 and UserSessionsTotal 276

That's the failure mode that makes this kind of bug worse than a noisy alert: you get just enough evidence that it's working to stop looking closely, and the safety net still has a hole in it.

[H2] Under the hood, for anyone who wants the detail

The runbook that feeds the capacity alerts reports load as a decimal, e.g. `68.5`. The query parsed it like this:

```kusto
| extend HostPoolPercentLoad = toint(split(ResultDescription, '|')[9])
| where HostPoolPercentLoad >= 50
```

📸 avd-hostpool-capacity-alert-old-query-details.png
Caption: The additional details pane on that same fired alert, showing the exact query running underneath: toint() on HostPoolPercentLoad, and HPResourceId reading index [13], both from before the fix.
Alt: Azure Monitor alert additional details pane showing the KQL search query using toint on HostPoolPercentLoad at split index 9, and HPResourceId at split index 13

`toint()` only parses whole-number strings. Feed it `"68.5"` and it doesn't error, it just returns `null`. Every `where` clause comparing that `null` against a threshold evaluates to false, silently, no matter what the actual load is. The fix is a one-word swap to `toreal()`, which parses the decimal correctly:

```kusto
| extend HostPoolPercentLoad = toreal(split(ResultDescription, '|')[9])
| where HostPoolPercentLoad >= 50
```

> **💡 Tip**
> `toint()` returning `null` instead of erroring is the sharp edge here. It fails the way a comparison fails, not the way a syntax error fails, so nothing surfaces it. Worth a second look anywhere a KQL alert threshold hasn't fired in a while, even when the deployment looks completely healthy.

While I was in that query, the same three alerts also had `HPResourceId` reading the wrong field of the pipe-delimited runbook output. Index 13, of an array that only has 13 fields (0 to 12), so the resource link was always empty even once the alert fired. Corrected to index `[12]`.

The health check mapping fix was similar in shape: a `MapToDesc` function with an explicit list of known indices and no default case beyond "unrecognised", so anything added upstream after the function was written just fell out of scope. Added `idx == 11` (TURN Relay) and `idx == 19` (AAD Joined) to the map.

And the missing-value alerts came down to how Log Alerts V2 dimensions work: only columns explicitly listed in the alert rule's `dimensions` array make it into the fired alert, email or portal details. The query can compute whatever it likes internally, but if the column isn't listed it just gets discarded, not hidden somewhere retrievable. Added `AvailableMB`, `CounterValue` and `PercentAvailable` to the relevant alerts' dimension lists.

Full write-up of all of it, release by release, is in the [change log](https://github.com/durrante/AVDMonitoringBaseline/blob/main/patterns/avd/CHANGES.md).

[H2] Getting it

It's free, open source (MIT), and deploys the same way as the original: grab the ARM template and UI definition and use the custom deployment blade.

> LAYOUT NOTE (delete): paste the snippet below into a WordPress "Custom
> HTML" block, exactly as-is. Same shields.io badge trick as the Script
> Runner post, version number and licence pull live from GitHub, so
> nothing needs updating by hand on the next release.
>
> <div style="text-align:center; margin:1.5em 0;">
>   <a href="https://github.com/durrante/AVDMonitoringBaseline/releases">
>     <img src="https://img.shields.io/github/v/release/durrante/AVDMonitoringBaseline?style=for-the-badge&label=Latest%20Release&color=4A2B8F" alt="View the latest AVD Monitoring Baseline release on GitHub" style="height:42px; margin:0 6px;">
>   </a>
>   <a href="https://github.com/durrante/AVDMonitoringBaseline/blob/main/LICENSE">
>     <img src="https://img.shields.io/github/license/durrante/AVDMonitoringBaseline?style=for-the-badge&color=0693E3" alt="AVD Monitoring Baseline MIT licence" style="height:42px; margin:0 6px;">
>   </a>
> </div>

If you're already running the official baseline, the change log is the fastest way to see what's different before you redeploy.

[H2] Wrapping up

That's AVD Monitoring Baseline, Community Edition: the same alert pattern Microsoft built for AVD, kept running, with the bugs actually fixed and a few small gaps closed along the way. Correct as of v2.4.0, and it'll keep moving as more turns up.

Found something else that doesn't add up, or hit an upstream issue this fork doesn't cover yet? Open an issue on the repo, that's what it's there for. Happy monitoring.

---

> PUBLISHING NOTES (delete before publishing):
>
> Structure: H1 → H2 what's changed (plain-language rundown, least to most
> technical within it) → H2 capacity-alert anecdote (the hook) → H2 under
> the hood (the technical deep dive: toint/toreal, resourceId index,
> health check map, dimensions) → H2 getting it.
>
> Deliberately leans less technical at the top, more technical as it goes.
> A reader who stops after "What's changed" still gets the full picture;
> "Under the hood" is for anyone who wants the how.
>
> Two info bubbles (Note, Tip), kept sparse.
>
> Two images, both from the same fired capacity alert (top half / bottom
> half of the same details page), source files in
> `Pictures\ShareX\Screenshots\08-07-2026\Blog Post\`:
> `Alert_'AVD-HostPool-Capacity_50_Percent_(-prod-des-a1c_08-07-2026-11-33.png`
> and `...a1d_08-07-2026-11-33.png`. Rename to
> `avd-hostpool-capacity-alert-fired-dimensions.png` and
> `avd-hostpool-capacity-alert-old-query-details.png` respectively before
> uploading, matching the 📸 markers above. Redaction already looks handled
> in both (customer name, host pool name, subscription/resource group/
> workspace, resource ID) but give them one more look before publishing.
>
> Correct as of v2.4.0, worth stating near the top or bottom since the
> fork iterates.
>
> SEO suggestions:
> - Slug: avd-monitoring-baseline-community-edition
> - Meta description (155 chars): "What's actually been fixed in this fork
>   of Microsoft's AVD monitoring baseline: memory false positives, missed
>   health checks, and capacity alerts that silently failed to fire."
> - Focus keyphrases: avd monitoring baseline, azure monitor baseline
>   alerts avd, host pool capacity alert not firing, avd health check
>   failure alert
