#!/usr/bin/env node
// Kingdom Envoy Bridge — Slack Socket Mode WebSocket <-> File-based inbox/outbox
//
// Inbound:  Slack events -> state/envoy/socket-inbox/*.json
// Outbound: state/envoy/outbox/*.json -> Slack Web API -> state/envoy/outbox-results/*.json

'use strict';

const { SocketModeClient } = require('@slack/socket-mode');
const { WebClient } = require('@slack/web-api');
const fs = require('fs');
const path = require('path');

// --- Configuration ---

const BASE_DIR = process.env.KINGDOM_BASE_DIR || '/opt/kingdom';
const APP_TOKEN = process.env.SLACK_APP_TOKEN;
const BOT_TOKEN = process.env.SLACK_BOT_TOKEN;

if (!APP_TOKEN) {
  console.error('[ERROR] [envoy-bridge] SLACK_APP_TOKEN not set');
  process.exit(1);
}
if (!BOT_TOKEN) {
  console.error('[ERROR] [envoy-bridge] SLACK_BOT_TOKEN not set');
  process.exit(1);
}

const INBOX_DIR = path.join(BASE_DIR, 'state/envoy/socket-inbox');
const OUTBOX_DIR = path.join(BASE_DIR, 'state/envoy/outbox');
const RESULTS_DIR = path.join(BASE_DIR, 'state/envoy/outbox-results');
const HEALTH_FILE = path.join(BASE_DIR, 'state/envoy/bridge-health');

// Ensure directories exist
[INBOX_DIR, OUTBOX_DIR, RESULTS_DIR].forEach(dir => {
  fs.mkdirSync(dir, { recursive: true });
});

// --- Clients ---

const socketClient = new SocketModeClient({ appToken: APP_TOKEN });
const webClient = new WebClient(BOT_TOKEN);

// --- Utility ---

function atomicWrite(dir, filename, data) {
  const tmpPath = path.join(dir, `.tmp-${filename}`);
  const finalPath = path.join(dir, filename);
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2));
  fs.renameSync(tmpPath, finalPath);
}

function sanitizeTs(ts) {
  return ts.replace(/\./g, '-');
}

function log(category, msg) {
  const ts = new Date().toISOString().replace('T', ' ').substring(0, 19);
  const logLine = `[${ts}] [${category}] [envoy-bridge] ${msg}\n`;
  try {
    fs.appendFileSync(path.join(BASE_DIR, 'logs/system.log'), logLine);
  } catch (_) {
    // Ignore log write failures
  }
  console.error(logLine.trim());
}

// --- Health heartbeat ---

let healthInterval = setInterval(() => {
  try {
    const fd = fs.openSync(HEALTH_FILE, 'w');
    fs.futimesSync(fd, new Date(), new Date());
    fs.closeSync(fd);
  } catch (_) {
    // Ignore
  }
}, 10000);

// Touch immediately on start
try { fs.writeFileSync(HEALTH_FILE, ''); } catch (_) {}

// --- Inbound: Slack events -> socket-inbox ---

// Get bot user ID for self-message filtering
let botUserId = null;
(async () => {
  try {
    const authResult = await webClient.auth.test();
    botUserId = authResult.user_id;
    log('SYSTEM', `Bot user ID: ${botUserId}`);
  } catch (e) {
    log('ERROR', `Failed to get bot user ID: ${e.message}`);
  }
})();

socketClient.on('message', async ({ event, ack }) => {
  await ack();

  // Filter out bot's own messages
  if (event.bot_id || (botUserId && event.user === botUserId)) return;
  // Filter out message subtypes (edits, deletes, etc.)
  if (event.subtype) return;

  let type;
  if (event.channel_type === 'im' && (!event.thread_ts || event.thread_ts === event.ts)) {
    // DM top-level message
    type = 'message';
  } else if (event.thread_ts && event.thread_ts !== event.ts) {
    // Thread reply (DM or channel)
    type = 'thread_reply';
  } else {
    // Other channel messages (not DM, not threaded) - ignore
    return;
  }

  const inboxEvent = {
    type,
    channel: event.channel,
    user_id: event.user,
    text: event.text || '',
    ts: event.ts,
    thread_ts: event.thread_ts || null,
    event_ts: event.event_ts || event.ts
  };

  const filename = `${sanitizeTs(inboxEvent.event_ts)}-${type}.json`;
  atomicWrite(INBOX_DIR, filename, inboxEvent);
  log('EVENT', `Inbox: ${type} from ${event.user} in ${event.channel}`);
});

socketClient.on('app_mention', async ({ event, ack }) => {
  await ack();

  // Filter out bot's own messages
  if (event.bot_id || (botUserId && event.user === botUserId)) return;

  const inboxEvent = {
    type: 'app_mention',
    channel: event.channel,
    user_id: event.user,
    text: event.text || '',
    ts: event.ts,
    thread_ts: event.thread_ts || null,
    event_ts: event.event_ts || event.ts
  };

  const filename = `${sanitizeTs(inboxEvent.event_ts)}-app_mention.json`;
  atomicWrite(INBOX_DIR, filename, inboxEvent);
  log('EVENT', `Inbox: app_mention from ${event.user} in ${event.channel}`);
});

// --- Outbound: outbox -> Slack Web API -> outbox-results ---

async function processOutbox() {
  if (processOutbox.running) return;
  processOutbox.running = true;

  let files;
  try {
    files = fs.readdirSync(OUTBOX_DIR).filter(f => f.endsWith('.json') && !f.startsWith('.'));
  } catch (_) {
    processOutbox.running = false;
    return;
  }

  for (const file of files) {
    const filePath = path.join(OUTBOX_DIR, file);
    let msg;
    try {
      msg = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (e) {
      log('ERROR', `Outbox parse error: ${file} — ${e.message}`);
      continue;
    }

    const result = { msg_id: msg.msg_id, ok: false, ts: null, channel: msg.channel, error: null };

    try {
      switch (msg.action) {
        case 'send_message': {
          const resp = await webClient.chat.postMessage({
            channel: msg.channel,
            text: msg.text
          });
          result.ok = resp.ok;
          result.ts = resp.ts;
          result.channel = resp.channel;
          break;
        }
        case 'send_reply': {
          const resp = await webClient.chat.postMessage({
            channel: msg.channel,
            text: msg.text,
            thread_ts: msg.thread_ts
          });
          result.ok = resp.ok;
          result.ts = resp.ts;
          result.channel = resp.channel;
          break;
        }
        case 'add_reaction': {
          await webClient.reactions.add({
            channel: msg.channel,
            timestamp: msg.message_ts,
            name: msg.emoji
          });
          result.ok = true;
          break;
        }
        case 'remove_reaction': {
          try {
            await webClient.reactions.remove({
              channel: msg.channel,
              timestamp: msg.message_ts,
              name: msg.emoji
            });
          } catch (_) {
            // Ignore - reaction may not exist
          }
          result.ok = true;
          break;
        }
        default:
          result.error = `Unknown action: ${msg.action}`;
          log('WARN', `Outbox unknown action: ${msg.action}`);
      }
    } catch (e) {
      result.error = e.message;
      log('ERROR', `Outbox API error: ${msg.action} — ${e.message}`);
    }

    // Write result
    atomicWrite(RESULTS_DIR, `${msg.msg_id}.json`, result);

    // Remove processed outbox file
    try { fs.unlinkSync(filePath); } catch (_) {}
  }

  processOutbox.running = false;
}

processOutbox.running = false;

let outboxInterval = setInterval(processOutbox, 500);

// --- Connection lifecycle ---

socketClient.on('connected', () => {
  log('SYSTEM', 'Socket Mode connected');
});

socketClient.on('disconnected', () => {
  log('WARN', 'Socket Mode disconnected (will auto-reconnect)');
});

// --- Graceful shutdown ---

function shutdown() {
  log('SYSTEM', 'Shutting down bridge...');
  clearInterval(healthInterval);
  clearInterval(outboxInterval);
  socketClient.disconnect().catch(() => {});
  setTimeout(() => process.exit(0), 1000);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// --- Start ---

(async () => {
  try {
    await socketClient.start();
    log('SYSTEM', 'Bridge started successfully');
  } catch (e) {
    log('ERROR', `Bridge start failed: ${e.message}`);
    process.exit(1);
  }
})();
