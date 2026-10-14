const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;

/** Bound browser/server Supabase requests so auth restoration and sign-in fail clearly. */
export const fetchWithTimeout: typeof fetch = async (input, init = {}) => {
  const controller = new AbortController();
  const upstreamSignal = init.signal;
  const abortFromUpstream = () => controller.abort();
  upstreamSignal?.addEventListener("abort", abortFromUpstream, { once: true });
  const timeout = setTimeout(() => controller.abort(), DEFAULT_REQUEST_TIMEOUT_MS);

  try {
    if (upstreamSignal?.aborted) controller.abort();
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
    upstreamSignal?.removeEventListener("abort", abortFromUpstream);
  }
};
