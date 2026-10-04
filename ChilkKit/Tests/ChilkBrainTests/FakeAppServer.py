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
        # No execution environment: no shell, no apply_patch/file edits, only Chilk's own functions + web.
        assert m["params"].get("environments") == [], "thread must start without environment access"
        if m["params"].get("dynamicTools"):
            assert m["params"]["dynamicTools"][0]["type"] == "function"
            assert m["params"]["dynamicTools"][0]["name"] == "chilk_status"
        send({"id": mid, "result": {"thread": {"id": "t1"}}})
    elif meth == "turn/start":
        tid = m["params"]["threadId"]
        text = m["params"]["input"][0]["text"]
        send({"id": mid, "result": {"turn": {"id": "u1"}}})
        if text.startswith("tool"):
            params = {"threadId": tid, "turnId": "u1", "callId": "call1", "tool": "chilk_status", "arguments": {}}
            if text == "tool wrong-turn": params["turnId"] = "old-turn"
            if text == "tool other-thread": params["threadId"] = "unknown-thread"
            if text == "tool unknown": params["tool"] = "delete_secret"
            if text == "tool namespace": params["namespace"] = "unregistered"
            send({"id": 901, "method": "item/tool/call", "params": params})
            reply = json.loads(sys.stdin.readline())
            if reply.get("method") == "turn/interrupt":
                send({"id": reply["id"], "result": {}})
                send({"method": "turn/completed", "params": {"threadId": tid, "turn": {"id": "u1", "status": "interrupted"}}})
                reply = json.loads(sys.stdin.readline())
                continue
            result = reply["result"]
            if text == "tool twice":
                send({"id": 902, "method": "item/tool/call", "params": params})
                again = json.loads(sys.stdin.readline())["result"]
                assert again == result
            send({"method": "item/agentMessage/delta", "params": {
                "threadId": tid, "turnId": "u1", "itemId": "i1", "delta": result["contentItems"][0]["text"]}})
            send({"method": "turn/completed", "params": {"threadId": tid, "turn": {"id": "u1", "status": "completed"}}})
            continue
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
