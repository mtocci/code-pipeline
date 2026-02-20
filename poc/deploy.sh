#!/usr/bin/env bash
#
# deploy.sh — Invoke the Router Lambda and watch pipeline execution live
#
# Usage:
#   ./deploy.sh                          # Run both apps
#   ./deploy.sh drug-research-portal     # Run one specific app
#   ./deploy.sh devops-app               # Run the other
#
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "ERROR: AWS_PROFILE is not set. Export it or add it to .env"
  exit 1
fi
STACK_NAME="${STACK_NAME:-pipeline-router}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Get Router Lambda name from stack outputs
ROUTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RouterLambdaName'].OutputValue" \
  --output text 2>/dev/null)

if [ -z "$ROUTER_NAME" ] || [ "$ROUTER_NAME" = "None" ]; then
  echo "ERROR: Could not find Router Lambda in stack '$STACK_NAME'."
  echo "Run ./setup.sh first."
  exit 1
fi

# -----------------------------------------------------------------
# invoke_router: trigger a pipeline, write response to stdout
# -----------------------------------------------------------------
invoke_router() {
  local app_name="$1"
  local revision="${2:-$(openssl rand -hex 4)}"
  local tmpfile
  tmpfile=$(mktemp)

  local payload
  payload=$(printf '{"app_name": "%s", "revision": "%s"}' "$app_name" "$revision")

  aws lambda invoke \
    --function-name "$ROUTER_NAME" \
    --payload "$payload" \
    --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    "$tmpfile" > /dev/null 2>&1

  cat "$tmpfile"
  rm -f "$tmpfile"
}

# -----------------------------------------------------------------
# watch_pipeline: print each stage once as it completes
# -----------------------------------------------------------------
watch_pipeline() {
  local pipeline_name="$1"
  local execution_id="$2"

  python3 << 'PYEOF'
import json, sys, time, subprocess, os

pipeline_name = os.environ["_PN"]
execution_id = os.environ["_EID"]
region = os.environ["_REGION"]

# Stages in order. Gated stages have two actions (Gate + Work) shown on one line.
STAGE_ORDER = ["Source", "Build", "UnitTest", "SAST", "SCA", "ChangeApproval", "Deploy", "IntegrationTest"]
GATED_STAGES = {"SAST", "SCA", "ChangeApproval"}

def get_execution_status():
    r = subprocess.run([
        "aws", "codepipeline", "get-pipeline-execution",
        "--pipeline-name", pipeline_name,
        "--pipeline-execution-id", execution_id,
        "--region", region, "--output", "json",
    ], capture_output=True, text=True)
    if r.returncode != 0:
        return "Unknown"
    return json.loads(r.stdout).get("pipelineExecution", {}).get("status", "Unknown")

def get_actions():
    r = subprocess.run([
        "aws", "codepipeline", "list-action-executions",
        "--pipeline-name", pipeline_name,
        "--filter", f"pipelineExecutionId={execution_id}",
        "--region", region, "--output", "json",
    ], capture_output=True, text=True)
    if r.returncode != 0:
        return {}
    actions = {}
    for a in json.loads(r.stdout).get("actionExecutionDetails", []):
        stage = a.get("stageName", "?")
        action_name = a.get("actionName", "?")
        entry = {
            "status": a.get("status", "Unknown"),
            "output_vars": a.get("output", {}).get("outputVariables", {}),
            "start": a.get("startTime", ""),
            "end": a.get("lastUpdateTime", ""),
        }
        # For gated stages, track Gate and Work actions separately
        if stage in GATED_STAGES:
            if stage not in actions:
                actions[stage] = {"gate": None, "work": None}
            if "Gate" in action_name:
                actions[stage]["gate"] = entry
            elif "Work" in action_name:
                actions[stage]["work"] = entry
        else:
            actions[stage] = entry
    return actions

def calc_dur(info):
    try:
        from datetime import datetime
        s = str(info["start"])[:19]
        e = str(info["end"])[:19]
        if s and e:
            return int((datetime.fromisoformat(e) - datetime.fromisoformat(s)).total_seconds())
    except:
        pass
    return None

def format_stage(stage, info):
    # Gated stages have {"gate": ..., "work": ...}
    if stage in GATED_STAGES:
        gate_info = info.get("gate")
        work_info = info.get("work")
        if not gate_info:
            return None
        gate_decision = gate_info["output_vars"].get("gate_decision", "?")

        if gate_decision == "skip":
            dur = calc_dur(gate_info)
            dur_str = f"  {dur}s" if dur else ""
            return f"  \u2298  {stage:20s} gate=skip (stage work not executed){dur_str}"

        if gate_decision == "proceed":
            if not work_info:
                return None  # work action hasn't completed yet
            work_status = work_info["status"]
            if work_status == "Succeeded":
                out = work_info["output_vars"]
                tool = out.get("tool", "")
                result = out.get("result", "")
                dur = calc_dur(work_info)
                dur_str = f"  {dur}s" if dur else ""
                detail = f"[{tool}] {result}" if tool else "executed"
                return f"  \u2713  {stage:20s} gate=proceed \u2192 {detail}{dur_str}"
            elif work_status == "Failed":
                return f"  X  {stage:20s} gate=proceed \u2192 FAILED"
        return None

    # Non-gated stages (single action)
    status = info["status"]
    out = info["output_vars"]
    tool = out.get("tool", "")
    result = out.get("result", "")
    dur = calc_dur(info)
    dur_str = f"  {dur}s" if dur else ""

    if status == "Succeeded":
        if stage == "Source":
            return f"  \u2713  {stage:20s} succeeded{dur_str}"
        detail = f"[{tool}] {result}" if tool else "succeeded"
        return f"  \u2713  {stage:20s} {detail}{dur_str}"
    elif status == "Failed":
        return f"  X  {stage:20s} FAILED{dur_str}"
    return None

# Track which stages we've already printed
printed = set()
start_time = time.time()

for _ in range(120):  # 120 x 3s = 6 min max
    actions = get_actions()

    # Print any newly completed stages, in order
    for stage in STAGE_ORDER:
        if stage in printed:
            continue
        info = actions.get(stage)
        if info is None:
            continue

        # For gated stages, wait until the stage is fully resolved
        if stage in GATED_STAGES:
            gate_info = info.get("gate")
            if not gate_info or gate_info["status"] not in ("Succeeded", "Failed"):
                continue
            gate_decision = gate_info["output_vars"].get("gate_decision", "?")
            # If skipped, we can print immediately (no work action runs)
            if gate_decision == "skip":
                line = format_stage(stage, info)
                if line:
                    print(line, flush=True)
                printed.add(stage)
                continue
            # If proceed, wait for work action to complete
            work_info = info.get("work")
            if not work_info or work_info["status"] not in ("Succeeded", "Failed"):
                continue
            line = format_stage(stage, info)
            if line:
                print(line, flush=True)
            printed.add(stage)
        else:
            if info["status"] in ("Succeeded", "Failed"):
                line = format_stage(stage, info)
                if line:
                    print(line, flush=True)
                printed.add(stage)

    # Check if pipeline is done
    exec_status = get_execution_status()
    if exec_status in ("Succeeded", "Failed", "Stopped", "Cancelled"):
        # One final pass to catch any remaining stages
        actions = get_actions()
        for stage in STAGE_ORDER:
            if stage in printed:
                continue
            line = format_stage(stage, actions.get(stage, {}))
            if line:
                print(line, flush=True)
            printed.add(stage)
        break

    time.sleep(3)

elapsed = int(time.time() - start_time)
print()

succeeded = 0
skipped = 0
failed = 0
for s in STAGE_ORDER:
    info = actions.get(s, {})
    if s in GATED_STAGES:
        gate = (info.get("gate") or {})
        work = (info.get("work") or {})
        if gate.get("output_vars", {}).get("gate_decision") == "skip":
            skipped += 1
            succeeded += 1
        elif work.get("status") == "Succeeded":
            succeeded += 1
        elif work.get("status") == "Failed" or gate.get("status") == "Failed":
            failed += 1
    else:
        if info.get("status") == "Succeeded":
            succeeded += 1
        elif info.get("status") == "Failed":
            failed += 1

status_icon = "\u2713" if failed == 0 else "X"
print(f"  {status_icon}  {succeeded} succeeded ({skipped} skipped) / {failed} failed — {elapsed}s total")
PYEOF
}

# -----------------------------------------------------------------
# run_app: invoke router + watch pipeline
# -----------------------------------------------------------------
run_app() {
  local app_name="$1"
  local revision="${2:-$(openssl rand -hex 4)}"

  echo ""
  echo "  $app_name"
  echo "  $(printf '%0.s─' $(seq 1 ${#app_name}))"

  local raw_file
  raw_file=$(mktemp)
  invoke_router "$app_name" "$revision" > "$raw_file"

  # Parse response
  local pipeline_name pipeline_version execution_id
  eval "$(python3 -c "
import json, sys
with open('$raw_file') as f:
    raw = f.read()
try:
    resp = json.loads(raw)
    body = json.loads(resp['body']) if isinstance(resp.get('body'), str) else resp
except:
    print('echo \"ERROR: Failed to parse Lambda response\"; exit 1')
    sys.exit(0)
print(f'pipeline_name=\"{body.get(\"pipeline_name\",\"\")}\"')
print(f'pipeline_version=\"{body.get(\"pipeline_version\",\"\")}\"')
print(f'execution_id=\"{body.get(\"execution_id\",\"\")}\"')
")"

  rm -f "$raw_file"

  echo "  Routed to: $pipeline_name ($pipeline_version)"
  echo ""

  export _PN="$pipeline_name" _EID="$execution_id" _REGION="$REGION"
  watch_pipeline "$pipeline_name" "$execution_id"
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------

echo ""
echo "========================================================================"
echo "  Pipeline Router PoC — Live Execution"
echo "========================================================================"

if [ $# -eq 0 ]; then
  run_app "drug-research-portal" "abc123de"
  run_app "devops-app" "def456ab"
else
  run_app "$1" "${2:-$(openssl rand -hex 4)}"
fi

echo ""
echo "========================================================================"
echo "  Done. Toggle 'pipeline-version' in LaunchDarkly and run again."
echo "========================================================================"
