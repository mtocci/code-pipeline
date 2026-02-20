"""
Gate Lambda

Evaluates the LD "pipeline-required-stages" flag to decide whether a
gated stage (SAST, SCA, ChangeApproval) should proceed or be skipped.

Used as RunOrder 1 in gated stages. Outputs gate_decision ("proceed"
or "skip") via outputVariables. The StageWorker Lambda at RunOrder 2
reads this decision and either executes the stage work or no-ops.

UserParameters (JSON, set per-action in the pipeline definition):
  {
    "stage_name": "sast",
    "app_name": "#{variables.APP_NAME}",
    "pipeline_version": "#{variables.PIPELINE_VERSION}"
  }

Environment variables:
  LD_SECRET_NAME — Secrets Manager secret holding the LD SDK key (required)
"""
import json
import os
import boto3
import ldclient
from ldclient import Context
from ldclient.config import Config as LDConfig


# =============================================================================
# Client initialization — runs once at Lambda cold start
# =============================================================================

ALL_STAGES = [
    "source", "build", "unit-test", "sast", "sca",
    "change-approval", "deploy", "integration-test",
]

LD_SECRET_NAME = os.environ["LD_SECRET_NAME"]
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

codepipeline = boto3.client("codepipeline", region_name=REGION)

# Initialize LD client from Secrets Manager
print(f"[INIT] Retrieving LD SDK key from Secrets Manager ({LD_SECRET_NAME})")
secrets = boto3.client("secretsmanager", region_name=REGION)
secret = secrets.get_secret_value(SecretId=LD_SECRET_NAME)
sdk_key = json.loads(secret["SecretString"])["sdk_key"]
ldclient.set_config(LDConfig(sdk_key))
ld_client = ldclient.get()

if not ld_client.is_initialized():
    raise RuntimeError("LaunchDarkly client failed to initialize")
print("[INIT] LaunchDarkly client initialized")


# =============================================================================
# Lambda Handler
# =============================================================================

def handler(event, lambda_context):
    """
    Receives a CodePipeline job event for a Lambda Invoke action.

    Evaluates the pipeline-required-stages flag and outputs:
      gate_decision: "proceed" or "skip"
    """
    job = event["CodePipeline.job"]
    job_id = job["id"]
    user_params = json.loads(
        job["data"]["actionConfiguration"]["configuration"]["UserParameters"]
    )

    stage_name = user_params["stage_name"]
    app_name = user_params["app_name"]
    pipeline_version = user_params.get("pipeline_version", "?")

    print(f"GATE: stage={stage_name} app={app_name} pipeline={pipeline_version}")

    # Build LD context
    ld_context = (
        Context.builder(app_name)
        .kind("application")
        .build()
    )

    # Force SDK to sync latest flag state (handles Lambda freeze/thaw)
    ld_client.all_flags_state(ld_context)

    # Evaluate which stages are required for this app
    required_stages = ld_client.variation(
        "pipeline-required-stages", ld_context, ALL_STAGES
    )
    print(f"  Required stages: {required_stages}")

    if stage_name not in required_stages:
        print(f"GATE: {stage_name} → SKIP for {app_name}")
        codepipeline.put_job_success_result(
            jobId=job_id,
            outputVariables={
                "gate_decision": "skip",
                "stage_name": stage_name,
                "pipeline_version": pipeline_version,
            },
        )
        return

    print(f"GATE: {stage_name} → PROCEED for {app_name}")
    codepipeline.put_job_success_result(
        jobId=job_id,
        outputVariables={
            "gate_decision": "proceed",
            "stage_name": stage_name,
            "pipeline_version": pipeline_version,
        },
    )
