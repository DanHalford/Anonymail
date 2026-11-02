import { HttpRequest, HttpResponseInit, InvocationContext } from '@azure/functions';

export class HttpError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}

export function json(status: number, body: unknown): HttpResponseInit {
  return { status, jsonBody: body, headers: { 'Cache-Control': 'no-store' } };
}

type Handler = (req: HttpRequest, ctx: InvocationContext) => Promise<HttpResponseInit>;

/** Wraps a handler: maps HttpError to JSON, hides internal errors, logs only failures (bounded log volume). */
export function handle(fn: Handler): Handler {
  return async (req, ctx) => {
    try {
      return await fn(req, ctx);
    } catch (err) {
      if (err instanceof HttpError) {
        if (err.status >= 500) ctx.warn(`${err.code}: ${err.message}`);
        return json(err.status, { error: err.code, message: err.message });
      }
      ctx.error('Unhandled error', err);
      return json(500, { error: 'internal_error', message: 'Unexpected error. Try again later.' });
    }
  };
}

export async function readJson<T>(req: HttpRequest): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, 'invalid_json', 'Request body must be JSON.');
  }
}
