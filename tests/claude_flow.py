"""Runs the whole minutes pipeline on the Claude engine against a local stand-in API (no key, no cost), to prove nothing in the flow still needs Ollama.
Run: python3 tests/claude_flow.py   (needs the mock meeting folder it creates; takes about a minute for the transcription)"""
import http.server, json, os, subprocess, sys, tempfile, threading
from pathlib import Path

PIPE = Path(__file__).resolve().parent.parent / "pipeline" / "mom"
calls = []

def dummy(schema):
    t = schema.get("type")
    if t == "object": return {k: dummy(v) for k, v in schema.get("properties", {}).items()}
    if t == "array": return [dummy(schema.get("items", {}))]
    if t == "boolean": return False
    return "Rapat membahas anggaran kampanye."

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(h):
        body = json.loads(h.rfile.read(int(h.headers["content-length"])))
        fmt = body.get("output_config", {}).get("format")
        text = json.dumps(dummy(fmt["schema"]), ensure_ascii=False) if fmt else "Jawaban singkat."
        calls.append(fmt is not None)
        h.send_response(200); h.send_header("content-type", "application/json"); h.end_headers()
        h.wfile.write(json.dumps({"content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}).encode())
    def log_message(*a): pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
d = Path(tempfile.mkdtemp()) / "2026-10-21_1030_flow"; d.mkdir(parents=True)
(d / "transcript.md").write_text("# Transcript\n\n[00:00:05] Me: Selamat pagi, kita bahas anggaran kampanye hari ini.\n[00:00:20] Others: Anggarannya 450 juta, Pak.\n[00:00:40] Me: Oke, tolong dikirim sebelum Jumat.\n" * 3)
env = {**os.environ, "MINUTE_CLAUDE_BASE": f"http://127.0.0.1:{srv.server_port}", "MINUTE_ANTHROPIC_KEY": "sk-test", "MINUTE_LLM_PROVIDER": "anthropic"}
r = subprocess.run([str(PIPE), "--draft", str(d)], env=env, capture_output=True, text=True, timeout=300)
print(r.stdout[-300:], r.stderr[-300:])
ok = r.returncode == 0 and (d / "MoM.json").exists() and len(calls) >= 2
print(f"{len(calls)} API calls, MoM.json {'written' if (d / 'MoM.json').exists() else 'MISSING'}: {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
