#!/usr/bin/env node
/**
 * Telemetry Bridge: NATS MESH-TELEMETRY KV + mesh.telemetry.* → VictoriaMetrics
 *
 * Subscribes to mesh.telemetry.* for real-time agent telemetry,
 * polls MESH-TELEMETRY KV periodically as fallback,
 * and pushes Prometheus-format metrics to VictoriaMetrics.
 */
import { connect, nkeyAuthenticator, StringCodec } from 'nats';

const NATS_URL = process.env.NATS_URL || 'nats://nats:4222';
const NATS_SEED = process.env.NATS_SEED || '';
const VM_URL = process.env.VM_URL || 'http://victoriametrics:8428';
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '30000');

const sc = StringCodec();

// Track latest telemetry per agent
const agentData = new Map();

function telemetryToPrometheus(data) {
  const labels = `agent="${data.agent}",version="${data.version || 'unknown'}",model="${data.model || 'unknown'}"`;
  const ts = (data.ts || Math.floor(Date.now() / 1000)) * 1000; // ms for VM
  const lines = [];

  // Session metrics
  if (data.sessions) {
    lines.push(`mesh_agent_sessions_total{${labels}} ${data.sessions.total ?? 0} ${ts}`);
    lines.push(`mesh_agent_sessions_active{${labels}} ${data.sessions.active ?? 0} ${ts}`);
  }
  if (data.sessionCount !== undefined) {
    lines.push(`mesh_agent_sessions_total{${labels}} ${data.sessionCount} ${ts}`);
  }
  if (data.activeCount !== undefined) {
    lines.push(`mesh_agent_sessions_active{${labels}} ${data.activeCount} ${ts}`);
  }

  // Uptime
  if (data.uptime !== undefined) {
    lines.push(`mesh_agent_uptime_seconds{${labels}} ${data.uptime} ${ts}`);
  }

  // Sub-agents
  if (data.subAgents) {
    lines.push(`mesh_agent_subagents_running{${labels}} ${data.subAgents.running ?? 0} ${ts}`);
    lines.push(`mesh_agent_subagents_completed{${labels}} ${data.subAgents.completed ?? 0} ${ts}`);
  }

  // Messages (nested: data.messages.sent/received/errors)
  if (data.messages) {
    if (data.messages.sent !== undefined) lines.push(`mesh_agent_messages_sent_total{${labels}} ${data.messages.sent} ${ts}`);
    if (data.messages.received !== undefined) lines.push(`mesh_agent_messages_received_total{${labels}} ${data.messages.received} ${ts}`);
    if (data.messages.errors !== undefined) lines.push(`mesh_agent_errors_total{${labels}} ${data.messages.errors} ${ts}`);
  }

  // Tokens (nested: data.tokens.totalInput/totalOutput/last24hInput/last24hOutput)
  if (data.tokens) {
    if (data.tokens.totalInput !== undefined) lines.push(`mesh_agent_tokens_input_total{${labels}} ${data.tokens.totalInput} ${ts}`);
    if (data.tokens.totalOutput !== undefined) lines.push(`mesh_agent_tokens_output_total{${labels}} ${data.tokens.totalOutput} ${ts}`);
    if (data.tokens.last24hInput !== undefined) lines.push(`mesh_agent_tokens_24h_input{${labels}} ${data.tokens.last24hInput} ${ts}`);
    if (data.tokens.last24hOutput !== undefined) lines.push(`mesh_agent_tokens_24h_output{${labels}} ${data.tokens.last24hOutput} ${ts}`);
  }

  // System metrics (nested: data.system.cpuPercent/memoryMB/memoryPercent)
  if (data.system) {
    if (data.system.cpuPercent !== undefined) lines.push(`mesh_agent_cpu_percent{${labels}} ${data.system.cpuPercent} ${ts}`);
    if (data.system.memoryMB !== undefined) lines.push(`mesh_agent_memory_mb{${labels}} ${data.system.memoryMB} ${ts}`);
    if (data.system.memoryPercent !== undefined) lines.push(`mesh_agent_memory_percent{${labels}} ${data.system.memoryPercent} ${ts}`);
  }

  // Always emit an "up" gauge
  lines.push(`mesh_agent_up{${labels}} 1 ${ts}`);

  return lines.join('\n') + '\n';
}

async function pushToVM(prometheusData) {
  try {
    const resp = await fetch(`${VM_URL}/api/v1/import/prometheus`, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: prometheusData,
    });
    if (!resp.ok) {
      console.error(`[bridge] VM push failed: ${resp.status} ${await resp.text()}`);
    }
  } catch (err) {
    console.error(`[bridge] VM push error: ${err.message}`);
  }
}

async function main() {
  const seed = NATS_SEED.trim();
  if (!seed) {
    console.error('[bridge] NATS_SEED required');
    process.exit(1);
  }

  const nc = await connect({
    servers: NATS_URL,
    authenticator: nkeyAuthenticator(new TextEncoder().encode(seed)),
    reconnect: true,
    maxReconnectAttempts: -1,
  });
  console.log(`[bridge] Connected to ${NATS_URL}`);

  // Subscribe to real-time telemetry
  const sub = nc.subscribe('mesh.telemetry.*');
  (async () => {
    for await (const msg of sub) {
      try {
        const data = JSON.parse(sc.decode(msg.data));
        const agent = data.agent || msg.subject.split('.').pop();
        agentData.set(agent, data);
        const prom = telemetryToPrometheus(data);
        await pushToVM(prom);
        console.log(`[bridge] Pushed telemetry for ${agent} (realtime)`);
      } catch (err) {
        console.error(`[bridge] Sub error: ${err.message}`);
      }
    }
  })();

  // Poll KV as fallback
  const js = nc.jetstream();
  let kv;
  try {
    kv = await js.views.kv('MESH-TELEMETRY');
    console.log('[bridge] KV bucket MESH-TELEMETRY ready');
  } catch (err) {
    console.warn(`[bridge] KV not available: ${err.message}`);
  }

  const pollKV = async () => {
    if (!kv) return;
    try {
      const keys = [];
      const keyIter = await kv.keys();
      for await (const key of keyIter) {
        keys.push(key);
      }
      for (const key of keys) {
        try {
          const entry = await kv.get(key);
          if (!entry?.value) continue;
          const data = JSON.parse(sc.decode(entry.value));
          // Only push if we haven't seen a more recent realtime update
          const existing = agentData.get(key);
          if (!existing || (data.ts && data.ts >= (existing.ts || 0))) {
            const prom = telemetryToPrometheus(data);
            await pushToVM(prom);
          }
        } catch (err) {
          console.error(`[bridge] KV get ${key}: ${err.message}`);
        }
      }
    } catch (err) {
      console.error(`[bridge] KV poll error: ${err.message}`);
    }
  };

  // Initial KV poll after 5s, then every POLL_INTERVAL_MS
  setTimeout(pollKV, 5000);
  setInterval(pollKV, POLL_INTERVAL_MS);

  // Shutdown
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, async () => {
      console.log(`[bridge] ${sig}, draining...`);
      await nc.drain();
      process.exit(0);
    });
  }
}

main().catch(err => {
  console.error(`[bridge] Fatal: ${err}`);
  process.exit(1);
});
