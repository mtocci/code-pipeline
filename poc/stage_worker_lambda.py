"""
Stage Worker Lambda

Executes the actual work for a pipeline stage. Used in two modes:

  1. As RunOrder 2 in gated stages (SAST, SCA, ChangeApproval):
     Reads gate_decision from UserParameters (passed from the Gate Lambda
     via CodePipeline variable interpolation). If "skip", no-ops instantly.
     If "proceed", executes the stage work.

  2. As the sole action in non-gated stages (Build, UnitTest, Deploy,
     IntegrationTest): Always executes the stage work.

In production, this Lambda would call real tools:
  - SAST: Semgrep API or CodeBuild with Semgrep
  - SCA: Snyk API
  - ChangeApproval: ServiceNow API
  - Build: CodeBuild (with continuation tokens for async)
  - Deploy: CodeDeploy API
  - Tests: CodeBuild or third-party test runners

For the PoC, it logs placeholder output representing what each tool
would produce.

UserParameters (JSON):
  {
    "stage_name": "sast",
    "app_name": "drug-research-portal",
    "pipeline_version": "v1",
    "gate_decision": "proceed"       // only present in gated stages
  }
"""
import json
import os
import time
import boto3


# =============================================================================
# Placeholder stage work
# =============================================================================

STAGE_WORK = {
    "build": {
        "tool": "Build",
        "action": "Compiling application and packaging artifacts...",
        "result": "Build succeeded — artifacts packaged",
        "duration": 1,
    },
    "unit-test": {
        "tool": "UnitTest",
        "action": "Running unit test suite...",
        "result": "47 tests passed, 0 failed",
        "duration": 1,
    },
    "sast": {
        "tool": "Semgrep",
        "action": "Running Semgrep SAST scan on source code...",
        "result": "Scan complete: 0 critical findings, 2 informational",
        "duration": 2,
    },
    "sca": {
        "tool": "Snyk",
        "action": "Running dependency vulnerability scan (FDA compliance check)...",
        "result": "All dependencies clear — no known vulnerabilities (SBOM generated)",
        "duration": 2,
    },
    "change-approval": {
        "tool": "ServiceNow",
        "action": "Recording GxP change approval in ServiceNow audit trail...",
        "result": "Change record CR-2024-0042 created and auto-approved (21 CFR Part 11 compliant)",
        "duration": 1,
    },
    "deploy": {
        "tool": "Deploy",
        "action": "Deploying application to target environment...",
        "result": "Deployment complete — health checks passing",
        "duration": 1,
    },
    "integration-test": {
        "tool": "IntegrationTest",
        "action": "Running integration tests against deployment...",
        "result": "12 integration tests passed, 0 failed",
        "duration": 1,
    },
}


def do_stage_work(stage_name, app_name):
    """Placeholder: logs what the real tool integration would produce."""
    work = STAGE_WORK.get(stage_name, {
        "tool": "generic",
        "action": f"Running {stage_name}...",
        "result": f"{stage_name} completed successfully",
        "duration": 1,
    })

    print(f"  [{work['tool']}] {work['action']}")
    time.sleep(work["duration"])
    print(f"  [{work['tool']}] {work['result']}")

    return {
        "tool": work["tool"],
        "result": work["result"],
    }


# =============================================================================
# Client initialization
# =============================================================================

REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
codepipeline = boto3.client("codepipeline", region_name=REGION)


# =============================================================================
# Lambda Handler
# =============================================================================

def handler(event, lambda_context):
    """
    Receives a CodePipeline job event for a Lambda Invoke action.

    If gate_decision is "skip", no-ops immediately.
    Otherwise, executes placeholder stage work.
    """
    job = event["CodePipeline.job"]
    job_id = job["id"]
    user_params = json.loads(
        job["data"]["actionConfiguration"]["configuration"]["UserParameters"]
    )

    stage_name = user_params["stage_name"]
    app_name = user_params.get("app_name", "?")
    pipeline_version = user_params.get("pipeline_version", "?")
    gate_decision = user_params.get("gate_decision", "proceed")

    if gate_decision == "skip":
        print(f"WORKER: {stage_name} skipped by gate (app={app_name} pipeline={pipeline_version})")
        codepipeline.put_job_success_result(
            jobId=job_id,
            outputVariables={
                "gate_result": "skipped",
                "stage_name": stage_name,
                "pipeline_version": pipeline_version,
            },
        )
        return

    print(f"WORKER: {stage_name} executing (app={app_name} pipeline={pipeline_version})")
    output = do_stage_work(stage_name, app_name)

    codepipeline.put_job_success_result(
        jobId=job_id,
        outputVariables={
            "gate_result": "executed",
            "stage_name": stage_name,
            "pipeline_version": pipeline_version,
            "tool": output["tool"],
            "result": output["result"],
        },
    )
