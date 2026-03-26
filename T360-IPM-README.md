# T360 IPM Monitor — Setup Guide

## Files
- `T360-IPM-Monitor.ps1`       — main monitoring script
- `T360-IPM-TaskScheduler.xml` — Task Scheduler config (8am, 1pm, 6pm CST)

---

## Step 1 — Copy script to your WorkSpace

Place the script here:
```
D:\Users\N.ChowdaryDoppalap\Scripts\T360-IPM-Monitor.ps1
```

Logs will be saved automatically to:
```
D:\Users\N.ChowdaryDoppalap\Logs\T360-IPM\
```

---

## Step 2 — Test run manually first

Open PowerShell and run:
```powershell
powershell -ExecutionPolicy Bypass -File "D:\Users\N.ChowdaryDoppalap\Scripts\T360-IPM-Monitor.ps1"
```

You should see all 9 checks run with colored output and a summary at the end.

---

## Step 3 — Check Datadog for the event

1. Go to https://app.us3.datadoghq.com/event/explorer
2. Search for: `T360 IPM`
3. You should see the summary event appear within seconds of the script finishing

---

## Step 4 — Schedule via Task Scheduler

Run this once as Administrator in PowerShell:
```powershell
schtasks /create /xml "D:\Users\N.ChowdaryDoppalap\Scripts\T360-IPM-TaskScheduler.xml" /tn "T360-IPM-Monitor"
```

Verify it was created:
```powershell
schtasks /query /tn "T360-IPM-Monitor" /fo LIST
```

---

## Step 5 — Build Datadog dashboard

Once events are flowing, create a dashboard in Datadog:
1. Go to Dashboards → New Dashboard → name it `T360 IPM Checkpoint`
2. Add an **Event Stream** widget → filter by `app:t360-ipm-monitor`
3. Add an **Event Timeline** widget → same filter
4. Tag filters available: `shift:8am`, `shift:1pm`, `shift:6pm`, `item:1` through `item:13`

---

## What gets checked

| Item | Check | Method | Alert condition |
|------|-------|--------|----------------|
| 1 | Pod availability | kubectl | Any pod not Running |
| 2 | FTP server | TCP :21 | Connection fails |
| 3 | SMTP server | TCP :25 | Connection fails |
| 7 | Node disk pressure | kubectl | DiskPressure = True |
| 8 | Node CPU/Memory | kubectl top | CPU or MEM > 80% |
| 9 | VM availability | kubectl | Any node not Ready |
| 11 | File share size | Azure CLI | Usage > 80% of 5TB |
| 12 | Node disk space | kubectl | Used > 75% |
| 13 | ITP ephemeral ports | ITP script | Available <= 4000 |

Items 4, 5, 6 (database) and 10 (MSMQ) are handled manually by DBA team.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| kubectl not found | Ensure kubectl is in PATH |
| Azure CLI not logged in | Run `az login` first |
| Datadog event not appearing | Check API key in $Config block |
| ITP script fails | Verify path: `D:\Users\N.ChowdaryDoppalap\Scripts\Ephemeral Port Script.ps1` |
| Task Scheduler not firing | Check Task Scheduler → T360-IPM-Monitor → History tab |
