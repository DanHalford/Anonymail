/**
 * Polls only while the page is visible and something is pending, with exponential backoff
 * and a hard stop. Hidden tabs and idle pages make zero API calls.
 */
export class StatusPoller {
  private timer: number | undefined;
  private delay = 0;
  private startedAt = 0;

  constructor(
    private readonly tick: () => Promise<boolean>, // returns true while work is still pending
    private readonly opts = { initialMs: 3_000, maxMs: 30_000, giveUpMs: 10 * 60_000 },
  ) {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.startedAt) this.schedule(0);
      else this.clear();
    });
  }

  start(): void {
    this.startedAt = Date.now();
    this.delay = this.opts.initialMs;
    this.schedule(this.delay);
  }

  stop(): void {
    this.startedAt = 0;
    this.clear();
  }

  private clear() {
    if (this.timer !== undefined) window.clearTimeout(this.timer);
    this.timer = undefined;
  }

  private schedule(ms: number) {
    this.clear();
    if (document.visibilityState !== 'visible') return;
    this.timer = window.setTimeout(async () => {
      if (Date.now() - this.startedAt > this.opts.giveUpMs) return this.stop();
      let pending = false;
      try {
        pending = await this.tick();
      } catch {
        pending = true;
      }
      if (!pending) return this.stop();
      this.delay = Math.min(this.delay * 2, this.opts.maxMs);
      this.schedule(this.delay);
    }, ms);
  }
}
