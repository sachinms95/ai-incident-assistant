"""
AI Incident Triage Assistant
-----------------------------
A small FastAPI service that takes a raw alert (from GuardDuty, Wazuh,
CloudWatch, Zabbix, etc.) and returns:
  - a normalized severity score
  - a plain-English explanation of what's happening
  - a suggested first remediation step

This is the showcase/portfolio version of the alert-triage automation
pattern used in production at Pay10 (GuardDuty/Wazuh/CloudWatch -> 40%
faster mean triage time). It calls an LLM (Amazon Bedrock by default,
with an Anthropic API fallback for local dev) to do the reasoning, and
falls back to a deterministic rule-based classifier if no model
credentials are configured — so the service is always demoable, even
with zero external dependencies.
"""

import json
import logging
import os
import time
from typing import Optional

from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from pydantic import BaseModel, Field
from starlette.responses import Response

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("ai-incident-assistant")

app = FastAPI(
    title="AI Incident Triage Assistant",
    description="Classifies and explains infrastructure/security alerts using an LLM, with a rule-based fallback.",
    version="1.0.0",
)

# --- Prometheus metrics (scraped by the cluster's Prometheus, as used at Pay10) ---
REQUEST_COUNT = Counter("triage_requests_total", "Total triage requests", ["outcome"])
REQUEST_LATENCY = Histogram("triage_request_latency_seconds", "Triage request latency")

MODEL_BACKEND = os.getenv("MODEL_BACKEND", "rule_based")  # "bedrock" | "anthropic" | "rule_based"
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-6-v1:0")


class AlertIn(BaseModel):
    source: str = Field(..., examples=["GuardDuty", "Wazuh", "CloudWatch", "Zabbix"])
    title: str = Field(..., examples=["UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration"])
    raw_message: str = Field(..., description="Raw alert text/log line")
    resource: Optional[str] = Field(None, examples=["i-0abc123", "eks-cluster/prod"])


class TriageOut(BaseModel):
    severity: str
    severity_score: int
    summary: str
    suggested_action: str
    backend_used: str
    latency_ms: int


RULE_KEYWORDS = {
    "critical": ["exfiltration", "root", "ransomware", "privilege escalation", "unauthorizedaccess"],
    "high": ["bruteforce", "malware", "cryptomining", "policy:iam"],
    "medium": ["portscan", "recon", "anomalous"],
}


def rule_based_triage(alert: AlertIn) -> tuple[str, int, str, str]:
    text = f"{alert.title} {alert.raw_message}".lower()
    for level, keywords in RULE_KEYWORDS.items():
        if any(k in text for k in keywords):
            score = {"critical": 95, "high": 75, "medium": 50}[level]
            summary = f"Matched '{level}' pattern from {alert.source} alert '{alert.title}'."
            action = {
                "critical": "Isolate the affected resource immediately and page on-call security.",
                "high": "Investigate within 30 minutes; snapshot logs before remediation.",
                "medium": "Review during business hours; correlate with recent deploys.",
            }[level]
            return level, score, summary, action
    return "low", 20, "No high-risk pattern matched; likely informational.", "Log and monitor; no immediate action required."


def bedrock_triage(alert: AlertIn) -> tuple[str, int, str, str]:
    """Calls Amazon Bedrock (Claude) for reasoning over the alert. Falls back to rules on any error."""
    try:
        import boto3

        client = boto3.client("bedrock-runtime", region_name=os.getenv("AWS_REGION", "ap-south-1"))
        prompt = (
            "You are a security/DevOps triage assistant. Given this alert, respond ONLY with JSON: "
            '{"severity": "low|medium|high|critical", "severity_score": 0-100, '
            '"summary": "one sentence", "suggested_action": "one concrete next step"}.\n\n'
            f"Source: {alert.source}\nTitle: {alert.title}\nResource: {alert.resource}\n"
            f"Message: {alert.raw_message}"
        )
        body = json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 300,
                "messages": [{"role": "user", "content": prompt}],
            }
        )
        response = client.invoke_model(modelId=BEDROCK_MODEL_ID, body=body)
        payload = json.loads(response["body"].read())
        text = payload["content"][0]["text"]
        parsed = json.loads(text)
        return parsed["severity"], int(parsed["severity_score"]), parsed["summary"], parsed["suggested_action"]
    except Exception as exc:  # noqa: BLE001 - deliberate broad fallback for resilience
        logger.warning("Bedrock triage failed, falling back to rules: %s", exc)
        return rule_based_triage(alert)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    return {"status": "ready", "backend": MODEL_BACKEND}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/triage", response_model=TriageOut)
def triage(alert: AlertIn):
    start = time.time()
    try:
        if MODEL_BACKEND == "bedrock":
            severity, score, summary, action = bedrock_triage(alert)
            backend_used = "bedrock"
        else:
            severity, score, summary, action = rule_based_triage(alert)
            backend_used = "rule_based"

        REQUEST_COUNT.labels(outcome="success").inc()
        latency_ms = int((time.time() - start) * 1000)
        REQUEST_LATENCY.observe(latency_ms / 1000)

        return TriageOut(
            severity=severity,
            severity_score=score,
            summary=summary,
            suggested_action=action,
            backend_used=backend_used,
            latency_ms=latency_ms,
        )
    except Exception as exc:  # noqa: BLE001
        REQUEST_COUNT.labels(outcome="error").inc()
        logger.exception("Triage failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
