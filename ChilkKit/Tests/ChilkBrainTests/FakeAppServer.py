"""Scripted stand-in for `codex app-server` (newline-delimited JSON-RPC over stdio) for ChilkBrainTests."""
import json
import sys


def send(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    m = json.loads(line)
    meth, mid = m.get("method"), m.get("id")
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"userAgent": "fake"}})
    elif meth == "initialized":
        pass
    elif meth == "account/read":
        send({"id": mid, "result": {"account": {"type": "chatgpt", "email": "me@example.com", "planType": "pro"},
                                   "requiresOpenaiAuth": True}})
    elif meth == "account/login/start":
        send({"id": mid, "result": {"type": "chatgpt", "authUrl": "https://auth.example/start", "loginId": "L1"}})
        send({"method": "account/login/completed", "params": {"success": True, "loginId": "L1"}})
    elif meth == "thread/start":
        assert m["params"]["sandbox"] == "read-only"
        send({"id": mid, "result": {"thread": {"id": "t1"}}})
    elif meth == "turn/start":
        tid = m["params"]["threadId"]
        text = m["params"]["input"][0]["text"]
        send({"id": mid, "result": {"turn": {"id": "u1"}}})
        if text == "fail":
            send({"method": "error", "params": {"threadId": tid, "turnId": "u1", "willRetry": False,
                                                "error": {"message": "boom"}}})
            continue
        d = lambda s, item="i1": send({"method": "item/agentMessage/delta",
                                       "params": {"threadId": tid, "turnId": "u1", "itemId": item, "delta": s}})
        d("Привет, ")
        send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"threadId": tid}})
        decision = json.loads(sys.stdin.readline()).get("result", {}).get("decision")
        d("я Чилк!")
        d(f"[{decision}]", item="i2")
        send({"method": "turn/completed", "params": {"threadId": tid, "turn": {"id": "u1", "status": "completed"}}})
    elif meth == "die":
        sys.exit(0)
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": "no such method"}})
