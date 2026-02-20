# LaunchDarkly-Controlled Pipeline Router

A PoC demonstrating two LaunchDarkly use cases applied to AWS CodePipeline:

1. **Pipeline Version Routing** — route apps to pipeline v1 or v2 via LD flag targeting
2. **Regulated Stage Gating** — skip or run SAST/SCA/ChangeApproval per app via segment targeting

## Architecture

```
deploy.sh → Router Lambda → evaluates pipeline-version flag (LD)
                           → starts CodePipeline v1 or v2 with APP_NAME + PIPELINE_VERSION variables

Inside CodePipeline (v1 or v2):
  Source          (S3 — always runs)
  Build           (StageWorker Lambda — always executes)
  UnitTest        (StageWorker Lambda — always executes)
  SAST            (Gate Lambda → StageWorker Lambda — gate decides, worker executes or skips)
  SCA             (Gate Lambda → StageWorker Lambda — gate decides, worker executes or skips)
  ChangeApproval  (Gate Lambda → StageWorker Lambda — gate decides, worker executes or skips)
  Deploy          (StageWorker Lambda — always executes)
  IntegrationTest (StageWorker Lambda — always executes)
```

**Two-action gating pattern**: Gated stages (SAST, SCA, ChangeApproval) have two Lambda Invoke actions within the same stage:
1. **RunOrder 1 — Gate Lambda**: evaluates the LD `pipeline-required-stages` flag, outputs `gate_decision` ("proceed" or "skip") via `outputVariables`
2. **RunOrder 2 — StageWorker Lambda**: reads `gate_decision` from the gate action's namespace, then either executes stage work or no-ops

Non-gated stages (Build, UnitTest, Deploy, IntegrationTest) have a single StageWorker Lambda action that always executes.

In production, the StageWorker Lambda would call real tools (Semgrep, Snyk, ServiceNow, CodeBuild, etc.) or use continuation tokens for async work. In this PoC, it logs placeholder output.

## Prerequisites

- AWS CLI configured with SSO or credentials (`aws sts get-caller-identity` should work)
- Python 3.12+ and `pip` (for building the Lambda layer)
- An AWS account in us-east-1 (or set `AWS_DEFAULT_REGION`)
- A LaunchDarkly server-side SDK key

## Quick Start

```bash
cd poc

# 1. Build and publish the LD SDK Lambda Layer
./build_layer.sh
# Note the Layer ARN in the output

# 2. Deploy the stack with your LD key and layer
./setup.sh --ld-key sdk-your-key-here --layer-arn arn:aws:lambda:us-east-1:123456789:layer:launchdarkly-server-sdk:1

# 3. Trigger both apps
./deploy.sh

# Or trigger a single app
./deploy.sh drug-research-portal
./deploy.sh devops-app
```

The terminal shows live stage-by-stage output as each stage completes. `drug-research-portal` (regulated) runs all 8 stages. `devops-app` (unregulated) runs 5 — the three gated stages (SAST, SCA, ChangeApproval) skip instantly.

### LaunchDarkly Setup

Create the following in your LD project:

**Context kind:** `application`

**Segments:**
- `regulated-apps` — add keys: `drug-research-portal`, `clinical-trials-api`, `pharmacy-api`
- `unregulated-apps` — add keys: `devops-app`, `sandbox-app`, `internal-tooling-api`

**Flags:**
- `pipeline-version` — string, variations `"v1"` / `"v2"`, default `"v1"`. Use targeting rules or individual targeting to control which apps get v2.
- `pipeline-required-stages` — JSON array. Target `regulated-apps` with all 8 stages, `unregulated-apps` with 5 (omitting `sast`, `sca`, `change-approval`). Default: all 8 stages.

### Environment Setup

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
# Edit .env with your AWS_PROFILE, LD keys, etc.
source .env && export AWS_PROFILE
```

All scripts require `AWS_PROFILE` to be set.

## Scripts

| Script | Purpose |
|--------|---------|
| `poc/setup.sh` | Deploy the CloudFormation stack and upload a placeholder source artifact |
| `poc/deploy.sh` | Invoke the Router Lambda to trigger pipeline runs |
| `poc/build_layer.sh` | Build and publish the LD SDK Lambda Layer |
| `poc/teardown.sh` | Delete the stack and clean up all resources |

## Files

| File | Purpose |
|------|---------|
| `pipeline-router-stack.yaml` | CloudFormation template — the entire stack |
| `poc/router_lambda.py` | Router Lambda source (also inlined in CFN) |
| `poc/gate_lambda.py` | Gate Lambda source — evaluates LD flag, outputs gate decision |
| `poc/stage_worker_lambda.py` | StageWorker Lambda source — executes stage work or no-ops based on gate decision |

## Switching Pipeline Versions

Pipeline version (v1 vs v2) is controlled in the **LaunchDarkly dashboard**:

1. Go to your LD project → Flags → `pipeline-version`
2. Change the default variation or add targeting rules per app
3. Run `./poc/deploy.sh` to trigger pipelines and see the effect

Each stage logs the pipeline version in its output, so you can verify which version is running.

## Teardown

```bash
./poc/teardown.sh
```

This empties the S3 artifact bucket, deletes the CloudFormation stack, and removes the LD secret from Secrets Manager.
