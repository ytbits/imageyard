import WebSocket from 'ws';

export type JsonObject = Record<string, unknown>;
export type RpcId = string | number;
export type Notification = { method: string; params?: JsonObject };
export type ServerRequest = Notification & { id: RpcId };
export type Turn = {
  id: string;
  status: 'inProgress' | 'completed' | 'interrupted' | 'failed';
  items: JsonObject[];
  error?: unknown;
};

export interface ClientOptions {
  url: string;
  token: string;
  /** Certificate identity, when Kubernetes service DNS differs from the SAN. */
  tlsServerName?: string;
  /** Private test CA or intentionally configured private CA; verification stays on. */
  ca?: string | Buffer;
  requestTimeoutMs?: number;
  experimentalApi?: boolean;
  onNotification?: (notification: Notification) => void;
  /** Await the user's answer. Never approve requests merely to keep a task moving. */
  onServerRequest?: (request: ServerRequest, signal: AbortSignal) => Promise<unknown>;
}

export class RpcError extends Error {
  code: number;
  data: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.data = data;
  }
}

/** A timeout/disconnect can occur after the server has accepted a mutation. */
export class OutcomeUnknownError extends Error {
  constructor() {
    super('Connection lost or deadline exceeded; reconcile server state before retrying.');
    this.name = 'OutcomeUnknownError';
  }
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

/** One initialized connection to one Devbox. Reconnect by constructing a new client. */
export class AppServerClient {
  #socket: WebSocket;
  #options: ClientOptions;
  #nextId = 1;
  #ready = false;
  #closed = false;
  #pending = new Map<RpcId, Pending>();
  #serverRequests = new Map<RpcId, AbortController>();
  #completed = new Map<string, Turn>();
  #turnWaiters = new Map<string, Set<Pending>>();

  private constructor(options: ClientOptions) {
    const url = new URL(options.url);
    if (url.protocol !== 'wss:' || url.username || url.password || url.search || url.hash) {
      throw new Error('Use a WSS URL without credentials, query, or fragment.');
    }
    if (!/^[\x21-\x7e]+$/.test(options.token)) throw new Error('Invalid bearer token.');
    const timeout = options.requestTimeoutMs ?? 30_000;
    if (!Number.isSafeInteger(timeout) || timeout < 1) throw new Error('Invalid timeout.');
    this.#options = { ...options, requestTimeoutMs: timeout };
    const socketOptions: WebSocket.ClientOptions & { servername?: string } = {
      headers: { Authorization: `Bearer ${options.token}` },
      servername: options.tlsServerName,
      ca: options.ca,
      rejectUnauthorized: true,
      followRedirects: false,
      handshakeTimeout: timeout,
      maxPayload: 16 * 1024 * 1024,
      perMessageDeflate: false,
    };
    this.#socket = new WebSocket(url, socketOptions);
    this.#socket.on('message', (data, binary) => {
      try {
        if (binary) throw new Error('Unexpected binary message.');
        this.#receive(JSON.parse(data.toString()));
      } catch {
        this.#fail();
      }
    });
    this.#socket.on('error', () => this.#fail());
    this.#socket.on('close', () => this.#fail());
  }

  static async connect(options: ClientOptions): Promise<AppServerClient> {
    const client = new AppServerClient(options);
    try {
      await new Promise<void>((resolve, reject) => {
        const opened = () => { cleanup(); resolve(); };
        const failed = () => { cleanup(); reject(new Error('App Server connection failed.')); };
        const cleanup = () => {
          client.#socket.off('open', opened);
          client.#socket.off('error', failed);
          client.#socket.off('close', failed);
        };
        client.#socket.once('open', opened);
        client.#socket.once('error', failed);
        client.#socket.once('close', failed);
      });
      await client.#request('initialize', {
        clientInfo: { name: 'imageyard_service_example', version: '0.1.0' },
        capabilities: { experimentalApi: options.experimentalApi ?? false },
      });
      client.#send({ method: 'initialized' });
      client.#ready = true;
      return client;
    } catch (error) {
      client.close();
      throw error;
    }
  }

  request<T = JsonObject>(method: string, params: JsonObject = {}): Promise<T> {
    if (!this.#ready || method === 'initialize') {
      return Promise.reject(new Error('Use connect() to initialize exactly once.'));
    }
    return this.#request(method, params) as Promise<T>;
  }

  startThread(params: JsonObject = {}) {
    return this.request<{ thread: { id: string } }>('thread/start', params);
  }

  resumeThread(threadId: string, params: JsonObject = {}) {
    return this.request<{ thread: { id: string; turns: Turn[] } }>(
      'thread/resume', { ...params, threadId },
    );
  }

  async startTurn(threadId: string, text: string, params: JsonObject = {}): Promise<Turn> {
    const { turn } = await this.request<{ turn: Turn }>('turn/start', {
      ...params, threadId, input: [{ type: 'text', text }],
    });
    return turn;
  }

  steerTurn(threadId: string, expectedTurnId: string, text: string) {
    return this.request('turn/steer', {
      threadId, expectedTurnId, input: [{ type: 'text', text }],
    });
  }

  interruptTurn(threadId: string, turnId: string) {
    return this.request('turn/interrupt', { threadId, turnId });
  }

  /** Register soon after startTurn. Completion can arrive before its RPC reply. */
  waitForTurn(threadId: string, turnId: string, timeoutMs = 30 * 60_000): Promise<Turn> {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
      return Promise.reject(new Error('Invalid turn deadline.'));
    }
    const key = JSON.stringify([threadId, turnId]);
    const complete = this.#completed.get(key);
    if (complete) return Promise.resolve(complete);
    if (this.#closed) return Promise.reject(new OutcomeUnknownError());
    return new Promise((resolve, reject) => {
      const waiters = this.#turnWaiters.get(key) ?? new Set<Pending>();
      const waiter: Pending = {
        resolve: (value) => resolve(value as Turn), reject,
        timer: setTimeout(() => {
          waiters.delete(waiter);
          if (waiters.size === 0) this.#turnWaiters.delete(key);
          reject(new OutcomeUnknownError());
        }, timeoutMs),
      };
      waiters.add(waiter);
      this.#turnWaiters.set(key, waiters);
    });
  }

  /** Disconnecting does not cancel active work; use interruptTurn explicitly. */
  close(): void { this.#fail(); }

  #request(method: string, params: JsonObject): Promise<unknown> {
    if (this.#closed) return Promise.reject(new OutcomeUnknownError());
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new OutcomeUnknownError());
      }, this.#options.requestTimeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      try { this.#send({ id, method, params }); } catch { this.#fail(); }
    });
  }

  #send(message: unknown): void {
    if (this.#socket.readyState !== WebSocket.OPEN) throw new OutcomeUnknownError();
    this.#socket.send(JSON.stringify(message), (error) => { if (error) this.#fail(); });
  }

  #receive(message: JsonObject): void {
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      throw new Error('Invalid RPC message.');
    }
    const hasId = Object.hasOwn(message, 'id');
    if (hasId && typeof message.id !== 'number' && typeof message.id !== 'string') {
      throw new Error('Invalid RPC id.');
    }
    if (typeof message.method === 'string') {
      if (hasId) { void this.#answer(message as ServerRequest); return; }
      this.#notification(message as Notification);
      return;
    }
    if (!hasId || Object.hasOwn(message, 'result') === Object.hasOwn(message, 'error')) {
      throw new Error('Invalid RPC response.');
    }
    const pending = this.#pending.get(message.id as RpcId);
    if (!pending) return; // A late reply after a timeout is never automatically replayed.
    clearTimeout(pending.timer);
    this.#pending.delete(message.id as RpcId);
    if (message.error) {
      const error = message.error as { code: number; message: string; data?: unknown };
      pending.reject(new RpcError(error.code, error.message, error.data));
    } else pending.resolve(message.result);
  }

  #notification(notification: Notification): void {
    const params = notification.params ?? {};
    if (notification.method === 'serverRequest/resolved') {
      const controller = this.#serverRequests.get(params.requestId as RpcId);
      controller?.abort();
      this.#serverRequests.delete(params.requestId as RpcId);
    }
    if (notification.method === 'turn/completed') {
      const turn = params.turn as Turn;
      if (typeof params.threadId !== 'string' || typeof turn?.id !== 'string' ||
          !['completed', 'interrupted', 'failed'].includes(turn.status)) {
        throw new Error('Invalid turn completion.');
      }
      const key = JSON.stringify([params.threadId, turn.id]);
      this.#completed.set(key, turn);
      if (this.#completed.size > 128) this.#completed.delete(this.#completed.keys().next().value!);
      for (const waiter of this.#turnWaiters.get(key) ?? []) {
        clearTimeout(waiter.timer);
        waiter.resolve(turn);
      }
      this.#turnWaiters.delete(key);
    }
    this.#options.onNotification?.(notification);
  }

  async #answer(request: ServerRequest): Promise<void> {
    const controller = new AbortController();
    if (this.#serverRequests.has(request.id)) { this.#fail(); return; }
    this.#serverRequests.set(request.id, controller);
    try {
      if (!this.#options.onServerRequest) throw new RpcError(-32601, 'No request handler installed.');
      const result = await this.#options.onServerRequest(request, controller.signal);
      if (result === undefined) throw new RpcError(-32601, 'Unsupported server request.');
      if (!controller.signal.aborted) this.#send({ id: request.id, result });
    } catch (error) {
      if (!controller.signal.aborted) {
        try {
          this.#send({ id: request.id, error: {
            code: error instanceof RpcError ? error.code : -32603,
            message: 'Client could not answer this request.',
          } });
        } catch { this.#fail(); }
      }
    } finally {
      if (this.#serverRequests.get(request.id) === controller) this.#serverRequests.delete(request.id);
    }
  }

  #fail(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#ready = false;
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new OutcomeUnknownError());
    }
    this.#pending.clear();
    for (const waiters of this.#turnWaiters.values()) {
      for (const waiter of waiters) {
        clearTimeout(waiter.timer);
        waiter.reject(new OutcomeUnknownError());
      }
    }
    this.#turnWaiters.clear();
    for (const controller of this.#serverRequests.values()) controller.abort();
    this.#serverRequests.clear();
    this.#socket.terminate();
  }
}
