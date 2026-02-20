"""
Pipeline Router Lambda

Evaluates the "pipeline-version" LD flag to decide
which CodePipeline (v1 or v2) to start for a given application.

Then calls codepipeline.start_pipeline_execution() with APP_NAME and
PIPELINE_VERSION variables so all downstream stages know which app
and pipeline version they're working on.

Environment variables:
  LD_SECRET_NAME    — Secrets Manager secret name for LD SDK key (required)
  PIPELINE_V1_NAME  — Name of the stable pipeline
  PIPELINE_V2_NAME  — Name of the patched pipeline
"""
import json
import os
import uuid
import boto3
import ldclient
from ldclient import Context
from ldclient.config import Config as LDConfig


# =============================================================================
# Client initialization — runs once at Lambda cold start
# =============================================================================

LD_SECRET_NAME = os.environ["LD_SECRET_NAME"]
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
PIPELINE_V1 = os.environ.get("PIPELINE_V1_NAME", "shared-pipeline-v1")
PIPELINE_V2 = os.environ.get("PIPELINE_V2_NAME", "shared-pipeline-v2")

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

PIPELINE_MAP = {
    "v1": PIPELINE_V1,
    "v2": PIPELINE_V2,
}


# =============================================================================
# Lambda Handler
# =============================================================================

def handler(event, lambda_context):
    """
    Input event:
    {
        "app_name": "drug-research-portal",
        "revision": "abc123"
    }

    Evaluates the pipeline-version flag, then starts the selected
    CodePipeline with APP_NAME and PIPELINE_VERSION passed as variables.
    """
    app_name = event.get("app_name", "unknown")
    revision = event.get("revision", "HEAD")

    print(f"\n{'#'*60}")
    print(f"#  PIPELINE ROUTER")
    print(f"#  App:      {app_name}")
    print(f"#  Revision: {revision}")
    print(f"{'#'*60}")

    # Build LD context
    ld_context = (
        Context.builder(app_name)
        .kind("application")
        .build()
    )

    # Force SDK to sync latest flag state (handles Lambda freeze/thaw)
    ld_client.all_flags_state(ld_context)

    # --- USE CASE 1: Which pipeline version? ---
    print(f"\n  Evaluating LD flag: pipeline-version")
    pipeline_version = ld_client.variation("pipeline-version", ld_context, "v1")

    pipeline_name = PIPELINE_MAP.get(pipeline_version, PIPELINE_MAP["v1"])
    print(f"  Result: {pipeline_version} -> {pipeline_name}")

    # --- Start the selected CodePipeline ---
    print(f"\n  Starting pipeline: {pipeline_name}")
    response = codepipeline.start_pipeline_execution(
        name=pipeline_name,
        variables=[
            {"name": "APP_NAME", "value": app_name},
            {"name": "PIPELINE_VERSION", "value": pipeline_version},
        ],
        clientRequestToken=f"{app_name}-{uuid.uuid4().hex[:12]}",
    )

    execution_id = response["pipelineExecutionId"]
    print(f"  Execution ID: {execution_id}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "app": app_name,
            "pipeline_version": pipeline_version,
            "pipeline_name": pipeline_name,
            "execution_id": execution_id,
        }),
    }
