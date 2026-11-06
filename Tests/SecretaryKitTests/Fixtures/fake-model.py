#!/usr/bin/env python3
import json
import sys

request = json.load(sys.stdin)
if request.get("task") == "classify_intent":
    output = {
        "classification": "explicit",
        "confidence": 0.97,
        "intent_type": "send",
        "routed_text": "send the report to Alice"
    }
elif request.get("task") == "extract_facts":
    output = {
        "facts": [
            {
                "kind": "error",
                "subject": "Terminal",
                "predicate": "错误模式",
                "object": "npm ERR! code ERESOLVE",
                "statement": "Terminal 出现 npm ERR! code ERESOLVE 依赖解析错误",
                "confidence": 0.91,
                "keywords": ["npm", "eresolve"]
            }
        ]
    }
else:
    output = {}
json.dump(output, sys.stdout)
