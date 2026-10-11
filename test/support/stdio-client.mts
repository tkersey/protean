// Optional subprocess client; never linked into or required by the executable.
import {spawn, type ChildProcessWithoutNullStreams} from 'node:child_process';

export type Json = null | boolean | number | string | Json[] | {[key: string]: Json};
export type Notification = {jsonrpc: '2.0'; method: string; params: Json};
export type Exit = {code: number | null; signal: NodeJS.Signals | null};
type Pending = {resolve: (value: Json) => void; reject: (error: Error) => void; timer: NodeJS.Timeout};

export class RpcError extends Error {
  readonly code: number;
  readonly data: Json;
  constructor(error: {code: number; message: string; data?: Json}) {
    super(error.message);
    this.code = error.code;
    this.data = error.data ?? null;
  }
}

/** One reader/writer, bounded pending requests, exact string IDs and LF frames.
 * Callers retain client_operation_id and exact parameters for durable retries.
 * A transport failure is not evidence that a mutation was unadmitted.
 */
export class ProteanClient {
  readonly child: ChildProcessWithoutNullStreams;
  readonly closed: Promise<Exit>;
  private pending = new Map<string, Pending>();
  private serial = 0n;
  private input = Buffer.alloc(0);
  private writingBytes = 0;
  private ending = false;
  private failure: Error | null = null;
  private stopTimer: NodeJS.Timeout | undefined;
  private frameBytes = 1024 * 1024;
  private maxPending = 16;
  private queueBytes = 4 * 1024 * 1024;
  private decoder = new TextDecoder('utf-8', {fatal: true});
  private notification: (value: Notification) => void;

  constructor(binary: string, args: string[], options: {
    cwd?: string; env?: NodeJS.ProcessEnv; onNotification?: (value: Notification) => void;
  } = {}) {
    this.notification = options.onNotification ?? (() => {});
    this.child = spawn(binary, ['serve', '--transport', 'stdio', ...args], {
      cwd: options.cwd, env: options.env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    // Drain diagnostics without retaining an unbounded buffer or logging secrets.
    this.child.stderr.resume();
    this.child.on('error', error => this.fail(error));
    this.child.stdin.on('error', error => this.fail(error));
    this.child.stdout.on('error', error => this.fail(error));
    this.child.stdout.on('data', (bytes: Buffer) => {
      try { this.receive(bytes); } catch (error) { this.fail(error instanceof Error ? error : new Error('invalid response')); }
    });
    this.closed = new Promise(resolve => this.child.once('close', (code, signal) => {
      clearTimeout(this.stopTimer);
      this.ending = true;
      this.rejectAll(this.failure ?? new Error(this.input.length ? 'truncated server frame' : 'server closed before reply; inspect durable operation'));
      resolve({code, signal});
    }));
  }

  async initialize(): Promise<Json> {
    const value = await this.call('initialize', {protocol_versions: ['agent-host/1.0'], client_info: {name: 'native-example-client', version: '1'}});
    if (!object(value) || value.protocol_version !== 'agent-host/1.0' || !object(value.limits)) {
      this.fail(new Error('unsupported server negotiation'));
      throw this.failure;
    }
    for (const [key, cap] of [['frame_bytes', this.frameBytes], ['in_flight_calls', this.maxPending], ['outbound_bytes', this.queueBytes]] as const) {
      const limit = value.limits[key];
      if (typeof limit !== 'number' || !Number.isSafeInteger(limit) || limit <= 0 || limit > cap) {
        this.fail(new Error('unsupported server limits'));
        throw this.failure;
      }
    }
    this.frameBytes = value.limits.frame_bytes as number;
    this.maxPending = value.limits.in_flight_calls as number;
    this.queueBytes = value.limits.outbound_bytes as number;
    return value;
  }

  call(method: string, params: {[key: string]: Json} = {}, timeoutMs = 30_000): Promise<Json> {
    if (this.ending || this.failure) return Promise.reject(this.failure ?? new Error('client closing'));
    if (this.pending.size >= this.maxPending) return Promise.reject(new Error('client request capacity reached'));
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) return Promise.reject(new Error('invalid timeout'));
    const id = `rpc-${++this.serial}`;
    let frame: Buffer;
    try { frame = Buffer.from(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n'); }
    catch (error) { return Promise.reject(error); }
    if (frame.length > this.frameBytes || this.writingBytes + frame.length > this.queueBytes)
      return Promise.reject(new Error('client frame/queue capacity reached'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail(new Error('RPC timeout; inspect or replay the same durable operation')), timeoutMs);
      this.pending.set(id, {resolve, reject, timer});
      this.writingBytes += frame.length;
      this.child.stdin.write(frame, error => {
        this.writingBytes -= frame.length;
        if (error) this.fail(error);
      });
    });
  }

  /** EOF requests bounded parking. It does not claim semantic cancellation. */
  async close(): Promise<Exit> {
    if (!this.ending) {
      this.ending = true;
      this.child.stdin.end();
      this.armStop();
    }
    return this.closed;
  }

  private receive(bytes: Buffer): void {
    while (bytes.length) {
      const newline = bytes.indexOf(10);
      const length = newline < 0 ? bytes.length : newline;
      if (this.input.length + length >= this.frameBytes) throw new Error('oversized server frame');
      this.input = Buffer.concat([this.input, bytes.subarray(0, length)]);
      if (newline < 0) return;
      const text = this.decoder.decode(this.input);
      this.input = Buffer.alloc(0);
      bytes = bytes.subarray(newline + 1);
      const value: Json = JSON.parse(text);
      if (!object(value) || value.jsonrpc !== '2.0') throw new Error('invalid response envelope');
      if ('method' in value) {
        if ('id' in value || typeof value.method !== 'string' || !('params' in value)) throw new Error('invalid server notification');
        this.notification(value as Notification);
        continue;
      }
      if (typeof value.id !== 'string' || ('result' in value) === ('error' in value)) throw new Error('invalid correlated response');
      const pending = this.pending.get(value.id);
      if (!pending) throw new Error('unknown or repeated RPC response');
      this.pending.delete(value.id);
      clearTimeout(pending.timer);
      if ('error' in value) {
        if (!object(value.error) || typeof value.error.code !== 'number' || typeof value.error.message !== 'string') {
          pending.reject(new Error('malformed RPC error'));
          throw new Error('malformed RPC error');
        }
        pending.reject(new RpcError(value.error as {code: number; message: string; data?: Json}));
      } else pending.resolve(value.result);
    }
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  private armStop(): void {
    this.stopTimer ??= setTimeout(() => this.child.kill('SIGKILL'), 6000);
  }
  private fail(error: Error): void {
    if (this.failure) return;
    this.failure = error;
    this.rejectAll(error);
    this.ending = true;
    this.child.stdin.destroy();
    this.child.stdout.destroy();
    this.armStop();
  }
}

function object(value: Json): value is {[key: string]: Json} {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
