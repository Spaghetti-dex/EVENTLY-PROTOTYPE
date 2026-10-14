import { Hono } from "npm:hono";
import { cors } from "npm:hono/cors";
import { logger } from "npm:hono/logger";
import { createClient } from "npm:@supabase/supabase-js@2";
import * as kv from "./kv_store.tsx";
const app = new Hono();

// Enable logger
app.use('*', logger(console.log));

// Enable CORS for all routes and methods
app.use(
  "/*",
  cors({
    origin: "*",
    allowHeaders: ["Content-Type", "Authorization"],
    allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    exposeHeaders: ["Content-Length"],
    maxAge: 600,
  }),
);

// Health check endpoint
app.get("/make-server-98c085dc/health", (c) => {
  return c.json({ status: "ok" });
});

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const sentimentToken = Deno.env.get("HF_INFERENCE_TOKEN") ?? "";
const inferenceModel = "cardiffnlp/twitter-xlm-roberta-base-sentiment";

async function authorizeAdmin(request: Request) {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || !supabaseUrl || !anonKey || !serviceRoleKey) return null;
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return null;
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: profile, error } = await serviceClient.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (error || !profile || !["owner", "admin"].includes(profile.role)) return null;
  return { profile: { id: user.id, role: profile.role as string }, serviceClient };
}

app.post("/make-server-98c085dc/staff/provision", async (c) => {
  const authorized = await authorizeAdmin(c.req.raw);
  if (!authorized) return c.json({ error: "Administrative access required" }, 403);
  const { data: staffRoleReady, error: roleReadinessError } = await authorized.serviceClient.rpc("evently_staff_role_ready");
  if (roleReadinessError || staffRoleReady !== true) {
    return c.json({ error: "Staff role setup is not applied or verified in Supabase" }, 503);
  }
  const { data: staffPermissionsReady, error: staffPermissionsError } = await authorized.serviceClient.rpc("evently_staff_permissions_ready");
  if (staffPermissionsError || staffPermissionsReady !== true) {
    return c.json({ error: "Staff permissions and recommendation migrations are not applied or verified in Supabase" }, 503);
  }
  const body = await c.req.json().catch(() => null) as { email?: string; full_name?: string } | null;
  const email = body?.email?.trim().toLowerCase();
  const fullName = body?.full_name?.trim();
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || !fullName) {
    return c.json({ error: "A valid email address and staff name are required" }, 400);
  }
  const originHeader = c.req.header("Origin");
  if (!originHeader) return c.json({ error: "Staff invitation requires the application origin" }, 400);
  let origin: string;
  try {
    const parsedOrigin = new URL(originHeader);
    if (parsedOrigin.origin !== originHeader || !["https:", "http:"].includes(parsedOrigin.protocol)
      || (parsedOrigin.protocol === "http:" && !["localhost", "127.0.0.1"].includes(parsedOrigin.hostname))) {
      return c.json({ error: "Invalid application origin" }, 400);
    }
    const allowedOrigins = (Deno.env.get("EVENTLY_APP_ORIGINS") ?? "")
      .split(",").map((item) => item.trim()).filter(Boolean);
    if (allowedOrigins.length && !allowedOrigins.includes(parsedOrigin.origin)) {
      return c.json({ error: "Application origin is not allowlisted" }, 403);
    }
    origin = parsedOrigin.origin;
  } catch {
    return c.json({ error: "Invalid application origin" }, 400);
  }
  const { data, error } = await authorized.serviceClient.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${origin}/auth/callback?next=%2Fstaff%2Fdashboard`, data: { full_name: fullName },
  });
  if (error || !data.user) return c.json({ error: error?.message || "Staff invitation failed" }, 400);
  const { error: metadataError } = await authorized.serviceClient.auth.admin.updateUserById(data.user.id, {
    app_metadata: { ...data.user.app_metadata, role: "staff" },
  });
  if (metadataError) return c.json({ error: metadataError.message }, 500);
  const { error: profileError } = await authorized.serviceClient.from("profiles").upsert({
    id: data.user.id, email, full_name: fullName, role: "staff",
  }, { onConflict: "id" });
  if (profileError) return c.json({ error: profileError.message }, 500);
  await authorized.serviceClient.from("admin_activity_logs").insert({
    admin_id: authorized.profile.id, action: "staff_invited", entity_type: "profile",
    entity_id: data.user.id, description: `Staff invitation sent to ${email}`,
  });
  return c.json({ id: data.user.id, email, invited: true });
});

app.post("/make-server-98c085dc/reviews/analyze", async (c) => {
  if (!sentimentToken || !supabaseUrl || !anonKey || !serviceRoleKey) return c.json({ error: "Sentiment analysis is not configured" }, 503);
  const authorization = c.req.header("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return c.json({ error: "Authentication required" }, 401);
  const body = await c.req.json().catch(() => null) as { review_id?: string } | null;
  if (!body?.review_id) return c.json({ error: "Review ID is required" }, 400);
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: reviewFeaturesReady, error: readinessError } = await serviceClient.rpc("evently_review_features_ready");
  if (readinessError || reviewFeaturesReady !== true) return c.json({ error: "Review analysis schema is not applied" }, 503);
  const { data: profile } = await serviceClient.from("profiles").select("role").eq("id", user.id).maybeSingle();
  const isAdmin = Boolean(profile && ["owner", "admin"].includes(profile.role));
  const { data: review, error: reviewError } = await serviceClient.from("reviews").select("id,customer_id,review_text").eq("id", body.review_id).maybeSingle();
  if (reviewError || !review?.review_text) return c.json({ error: reviewError?.message || "Review not found" }, 404);
  if (!isAdmin && review.customer_id !== user.id) return c.json({ error: "You may only analyze your own review" }, 403);
  if (review.review_text.length > 5000) return c.json({ error: "This review exceeds the sentiment service limit" }, 400);
  const { data: withinQuota, error: quotaError } = await serviceClient.rpc("evently_consume_review_analysis_quota", { p_user_id: user.id });
  if (quotaError) return c.json({ error: quotaError.message }, 500);
  if (!withinQuota) return c.json({ error: "Analysis rate limit reached. Try again in a minute." }, 429);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    let response = await fetch(`https://router.huggingface.co/hf-inference/models/${inferenceModel}`, {
      method: "POST", signal: controller.signal,
      headers: { Authorization: `Bearer ${sentimentToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ inputs: review.review_text, options: { wait_for_model: true } }),
    });
    if (response.status === 429 || response.status === 503) {
      await new Promise((resolve) => setTimeout(resolve, 900));
      response = await fetch(`https://router.huggingface.co/hf-inference/models/${inferenceModel}`, {
        method: "POST", signal: controller.signal,
        headers: { Authorization: `Bearer ${sentimentToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ inputs: review.review_text, options: { wait_for_model: true } }),
      });
    }
    if (!response.ok) return c.json({ error: `Inference provider returned ${response.status}` }, 502);
    const result = await response.json();
    const scores = Array.isArray(result?.[0]) ? result[0] : Array.isArray(result) ? result : [];
    const best = scores.reduce((candidate: { label: string; score: number } | null, item: { label?: string; score?: number }) => {
      const label = String(item.label ?? "").toLowerCase();
      const mapped = label.includes("positive") || label === "label_2" ? "positive" : label.includes("negative") || label === "label_0" ? "negative" : label.includes("neutral") || label === "label_1" ? "neutral" : "";
      if (!mapped) return candidate;
      const score = Number(item.score);
      return !candidate || score > candidate.score ? { label: mapped, score } : candidate;
    }, null);
    if (!best || !Number.isFinite(best.score)) return c.json({ error: "The model did not return a usable sentiment result" }, 502);
    const { error: saveError } = await serviceClient.rpc("evently_record_review_sentiment", {
      p_review_id: review.id, p_sentiment: best.label, p_confidence: best.score,
      p_model_version: inferenceModel, p_analyzed_text: review.review_text,
    });
    if (saveError) return c.json({ error: saveError.message }, 500);
    return c.json({ sentiment: best.label, confidence: best.score, model: inferenceModel });
  } catch (error) {
    return c.json({ error: error instanceof Error ? error.message : "Sentiment analysis failed" }, 502);
  } finally {
    clearTimeout(timeout);
  }
});

Deno.serve(app.fetch);
