# Code review — `.github/workflows/main.yml`

**Change reviewed:** commit `a733bb3` "Add GitHub Actions workflow for personal supercomputer"
(44 lines added, one new file)

**Note on scope:** this repo has no pull requests — `gh pr list --state all` returns empty, and
`GET /repos/shahreyer53/Rdp/pulls?state=all` returns `[]`. The only change on `main` is the single
commit above, so that diff is what is being reviewed here.

---

## Verdict

**Do not merge. This should be closed, not fixed.**

The workflow is not a CI/CD workflow. Its stated purpose — in the file's own name, job id, and step
names — is to enlist 20 GitHub-hosted Windows VMs into a private overlay network, open remote-access
backdoors on them, and hold them idle for ~6 hours so the repo owner can RDP in and use them as a
personal compute cluster. That is prohibited use of GitHub-hosted runners, it puts the account at
risk of suspension, and it is also broken in several places such that it would not deliver what it
claims even if it were permitted.

---

## What the change actually does

| Line(s) | Behaviour |
| --- | --- |
| 6–13 | Job `build-botnet`, `windows-latest`, matrix of 20 instances, `fail-fast: false`, 360-minute timeout. |
| 16–18 | `Enable-PSRemoting -Force`, sets WinRM `TrustedHosts` to `*`, adds an inbound firewall rule allowing TCP 3389 from any source. |
| 20–22 | Creates a local user `Commander` from `secrets.SWARM_PASSWORD`, never-expiring, member of **Administrators** and **Remote Desktop Users**. |
| 24–27 | Downloads and silently installs Tailscale, then `tailscale up` with `secrets.TAILSCALE_AUTH_KEY`, hostname `gh-drone-<n>`. |
| 30–40 | Instance 1 only: sleeps 90 s, enumerates tailnet peers matching `gh-drone-*`, writes their IPs to `C:\Users\Commander\Desktop\drones.txt`. |
| 42–44 | `Start-Sleep -Seconds 21400` (5 h 56 m) to keep the VM alive for interactive use. |

There is no `actions/checkout`, no build, no test, no artifact, no publish. Nothing in the job
touches the software in this repository.

---

## Blocking issues

### 1. Prohibited use of GitHub-hosted runners

GitHub Additional Product Terms → **Actions**
(`/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions`)
states that, regardless of runner type, Actions should not be used for:

> * Any activity that places a burden on our servers, where that burden is disproportionate to the
>   benefits provided to users (for example, don't use Actions as a content delivery network or as
>   part of a serverless application…); or
> * If using GitHub-hosted runners, **any other activity unrelated to the production, testing,
>   deployment, or publication of the software project associated with the repository** where GitHub
>   Actions are used.

and, under *Use for Development and Testing*:

> You may only access and use GitHub Actions to develop and test your application(s). Only one
> licensed user may access a virtual machine provided by Actions at any time.

The same section states the consequence plainly:

> Misuse of GitHub Actions may result in termination of jobs, restrictions in your ability to use
> GitHub Actions, disabling of repositories created to run Actions in a way that violates these
> Terms, or in some cases, **suspension or termination of your GitHub account**.

A 20-node fleet that enrolls itself in a private tailnet, opens RDP, and idles for six hours is
exactly the "unrelated to the software project" case, and ~7,200 runner-minutes per dispatch for
personal desktop use is exactly the "disproportionate burden" case. The self-describing naming
(`build-botnet`, `Enslave Machine and Open Backdoors`, `drones.txt`) removes any plausible
dual-use reading — this is not a job whose intent has to be inferred.

### 2. The Tailscale auth key is handled unsafely

Line 27 inlines `${{ secrets.TAILSCALE_AUTH_KEY }}` directly into a command line. Two separate
problems:

* **Interpolation, not injection-safe access.** `${{ }}` expressions are substituted into the
  generated script *before* the shell runs. Passing a secret as a process argument also puts the
  value in the process command line, where it is readable by any other process on the machine and
  by any process-creation auditing that is enabled. The pattern GitHub's security-hardening
  guidance for Actions recommends is exporting to `env:` and reading the environment variable
  inside the script, not string-substituting into command text.
* **The key is reusable, not ephemeral.** One key enrolls all 20 nodes. Anything that reads it once
  — a runner process, a log, a leaked script — can subsequently attach arbitrary devices to the
  tailnet. A single non-expiring reusable key granting join rights to a private network is a
  standing credential exposure independent of everything else in this file.

The same interpolation pattern applies to `${{ secrets.SWARM_PASSWORD }}` on line 22 and to
`${{ matrix.instance }}` on lines 27 and 30. `matrix.instance` is trusted input today, but inlining
expressions into script bodies is the anti-pattern that turns into script injection the moment a
value becomes attacker-controlled.

### 3. Remote-access surface is opened wider than the design needs

* Line 18 sets WinRM `TrustedHosts` to `*`. That disables peer-hostname validation for **outbound**
  WinRM connections from the runner — it weakens authentication for anything the runner connects
  *to*, and does nothing at all for inbound RDP, which is what the file is trying to enable. Pure
  weakening, zero benefit to the stated goal.
* Line 18 adds the 3389 allow rule with no `remoteip` scoping — open to any source, all profiles.
* Line 22 puts a never-expiring, password-only account into **Administrators**. All 20 nodes end up
  holding the same long-lived admin credential, from a single secret, on machines that have just
  been joined to a network containing 19 other identically-credentialed machines. One credential
  compromise is a 20-machine compromise.
* No `if:`, no environment protection, no `permissions:` block, and the trigger is bare
  `workflow_dispatch:` — anyone with write access to the repo can dispatch 20 six-hour backdoored
  VMs at will.

---

## Correctness: it does not work as written

Listed for completeness. These are diagnoses, not a build plan — see the closing section.

1. **`C:\Users\Commander\Desktop` does not exist (line 37).** `New-LocalUser` creates an account,
   not a profile. The profile hive and `Desktop` directory are materialised on first interactive
   logon. `Out-File` to that path throws *"Could not find a part of the path"*, so the "dead drop"
   step fails on the one node that matters.
2. **`.Peer` is an object, not an array (lines 33–34).** `tailscale status --json` returns peers as
   a map keyed by node key. `ConvertFrom-Json` yields a `PSCustomObject`, so
   `(…).Peer.Where({ $_.HostName … })` applies the predicate to the container rather than to each
   peer; `$_.HostName` is `$null`, the filter matches nothing, and `$drones` is empty. The code
   enumerates the wrong thing.
3. **`tailscale` is invoked two different ways.** Line 27 uses the fully-qualified
   `$env:ProgramFiles\Tailscale\tailscale.exe`; line 33 calls bare `tailscale`. The Windows install
   directory is not guaranteed to be on the service PATH, so the controller branch can fail on
   command resolution immediately after an install that succeeded.
4. **The sleep cannot outlive the runner (lines 8, 44).** `Start-Sleep -Seconds 21400` is 356.7
   minutes against `timeout-minutes: 360`, and GitHub's hard cap for GitHub-hosted runners is
   **6 hours per job**, after which the job is terminated and fails
   (`/en/actions/reference/limits`). Setup, install, and the 90-second wait eat into that budget, so
   the job is killed at the cap. The VM is then destroyed — the "swarm" is not persistent
   infrastructure and never was.
5. **Empty secret is a hard failure (line 22).** If `SWARM_PASSWORD` is unset or empty,
   `ConvertTo-SecureString "" -AsPlainText -Force` throws and the step fails. No validation, no
   complexity check, no failure path.
6. **Concurrency saturates the account.** GitHub Free allows **20 total concurrent jobs** on
   standard GitHub-hosted runners (`/en/actions/reference/limits`). A matrix of exactly 20 occupies
   the account's entire Actions concurrency for up to six hours; every other workflow on the account
   queues behind it.
7. **Quota and billing.** One dispatch is 20 × ~360 ≈ 7,200 Windows runner-minutes. GitHub Free
   includes 2,000 minutes per month for private repositories, and Windows 2-core bills at
   $0.010/minute beyond that (`/en/billing/concepts/product-billing/github-actions`). The docs are
   explicit that *"if your account does not have a valid payment method on file, usage is blocked
   once you use up your quota."* The realistic outcome is jobs killed mid-sleep with the remainder
   of the matrix never starting — or roughly $72 per dispatch if a payment method exists.

---

## What I am not going to do

I am not going to supply a corrected version of this workflow, or the individual fixes that would
make fleet enrollment, peer enumeration, or the long-lived interactive session work. The problems
above are reported so the change can be evaluated and closed, not so it can be made operational.
The policy finding in §1 is not a bug that can be engineered around; it is the reason this change
should not exist in the repository.

## If the underlying goal is burst compute

Routes that do not put a GitHub account at risk:

* **Self-hosted runners** on hardware you own or rent, registered to this repo. Same Actions
  surface, your machines, no runner-minute billing, and the 6-hour cap does not apply — the
  self-hosted job execution limit is 5 days. This is the legitimate form of "my own cluster runs my
  CI."
* **Spot/preemptible instances** from any cloud provider for short-lived parallel workloads —
  materially cheaper per core-hour than $0.010/minute Windows, with no platform-policy exposure.
* **A real CI workflow** for whatever software this repository is meant to hold. If there is a
  project here, that is worth reviewing or writing instead: build, test, matrix across target
  platforms, artifacts, cache, the normal thing.

